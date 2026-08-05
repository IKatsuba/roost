import AppKit
import RoostCore
import SwiftUI

/// The single source of truth: projects, tabs, panes and live sessions.
@MainActor
@Observable
final class WorkspaceModel {
    private(set) var projects: [Project] = []
    private(set) var tabs: [String: [TabSpec]] = [:]
    private(set) var activeProjectID: String?
    private(set) var activeTabIDs: [String: String] = [:]

    /// Live sessions, keyed by pane id. Created lazily: restoring a layout must
    /// not raise a dozen processes at once.
    private(set) var sessions: [String: TerminalSession] = [:]

    var isPaletteOpen = false

    /// What to show in the body of the window.
    enum Mode: Hashable {
        /// The active tab's split, with the attention queue at the side.
        case work

        /// Every session of every project as a grid, the urgent ones first.
        case deck
    }

    var mode: Mode = .work

    /// What the overview is narrowed by. nil — show everything.
    var filter: AgentStatus?

    /// One line of the feed: who switched to what.
    struct Activity: Identifiable, Sendable {
        let id = UUID()
        let paneID: String
        let project: String
        let title: String
        let status: AgentStatus
        let at: Date

        /// The debt was cleared by a human, not by the agent. In the feed that
        /// reads differently: "sorted it out myself" rather than "the agent
        /// went quiet".
        var byHand = false
    }

    /// The feed of state changes, newest on top. It lives in memory only: this
    /// is a look at the current day of work, not a log.
    private(set) var activity: [Activity] = []

    private static let activityLimit = 200

    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var hooks: AgentHooks?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hookTask: Task<Void, Never>?
    @ObservationIgnored private var restored = false

    init(store: WorkspaceStore = WorkspaceStore()) {
        self.store = store
    }

    // MARK: - Lifecycle

    /// The status receiver comes up before the layout is restored — otherwise
    /// the first claude panes would start without the hook's address and would
    /// be left without a status.
    func start() async {
        notifier.onOpen = { [weak self] paneID in self?.focusPane(paneID) }
        notifier.prepare()

        hooks = try? await AgentHooks.start(directory: store.directory)

        if let hooks {
            hookTask = Task { [weak self] in
                for await event in hooks.events {
                    self?.apply(event)
                }
            }
        }

        restore()
    }

    private func apply(_ event: HookEvent) {
        guard let session = sessions[event.paneID] else { return }

        let before = session.status
        session.adopt(sessionID: event.sessionID, transcriptPath: event.transcriptPath)
        session.setStatus(event.status, question: event.message)

        // Only state changes go into the feed. A working agent pokes the hook
        // on every tool, and "started, started, started" would say nothing.
        if session.status != before { record(session) }
    }

    /// Writes a line into the feed. The project and the title are copied as
    /// words: the pane will close, but the event about what it managed to do
    /// stays.
    private func record(_ session: TerminalSession, byHand: Bool = false) {
        guard let (projectID, _) = locate(session.paneID),
              let project = projects.first(where: { $0.id == projectID })
        else { return }

        activity.insert(
            Activity(
                paneID: session.paneID,
                project: project.name,
                title: session.name,
                status: session.status,
                at: Date(),
                byHand: byHand
            ),
            at: 0
        )

        if activity.count > Self.activityLimit {
            activity.removeLast(activity.count - Self.activityLimit)
        }

        // A debt cleared by hand is news for the feed but not for the human:
        // they are the one who did it.
        if !byHand {
            notifier.post(
                paneID: session.paneID,
                project: project.name,
                title: session.name,
                status: session.status,
                body: session.lastAgentMessage
            )
        }
        syncBadge()
    }

    /// The dock badge follows the queue: it changes not only through agent
    /// events but also when a pane is closed together with its question.
    private func syncBadge() {
        notifier.badge(waiting: statusCounts[.waiting] ?? 0)
    }

    private func restore() {
        let snapshot = store.load()

        projects = snapshot.projects
        tabs = snapshot.tabs
        activeTabIDs = snapshot.activeTabIDs
        activeProjectID = snapshot.activeProjectID

        // The active project may have been removed from the list between runs.
        if let id = activeProjectID, !projects.contains(where: { $0.id == id }) {
            activeProjectID = nil
        }
        activeProjectID = activeProjectID ?? projects.first?.id

        restored = true
        ensureSessionsForActiveTab()
    }

    // MARK: - Reading

    var activeProject: Project? {
        projects.first { $0.id == activeProjectID }
    }

    var activeTab: TabSpec? {
        guard let projectID = activeProjectID, let tabID = activeTabIDs[projectID] else {
            return nil
        }
        return tabs[projectID]?.first { $0.id == tabID }
    }

    var activePaneID: String? { activeTab?.activePaneID }

    func tabs(of projectID: String) -> [TabSpec] { tabs[projectID] ?? [] }

    func session(_ paneID: String) -> TerminalSession? { sessions[paneID] }

    /// Every pane of every project — for the palette and the status summary.
    var allPanes: [(project: Project, tab: TabSpec, pane: PaneSpec)] {
        projects.flatMap { project in
            tabs(of: project.id).flatMap { tab in
                tab.panes.map { (project, tab, $0) }
            }
        }
    }

    /// How many panes are in which state — the summary for the status bar.
    var statusCounts: [AgentStatus: Int] {
        sessions.values.reduce(into: [:]) { counts, session in
            guard session.status != .none else { return }
            counts[session.status, default: 0] += 1
        }
    }

    /// One session together with where it lives.
    ///
    /// `@MainActor` spelled out: nested types do not inherit isolation, while
    /// the properties reach into the session.
    @MainActor
    struct Located: Identifiable {
        let project: Project
        let tab: TabSpec
        let pane: PaneSpec
        let session: TerminalSession?

        // The identifier reaches for nothing isolated, so the protocol's
        // requirement is moved off the main actor.
        nonisolated var id: String { pane.id }
        var status: AgentStatus { session?.status ?? .none }
        var title: String { session?.name ?? pane.title }
        var age: TimeInterval {
            session.map { Date().timeIntervalSince($0.statusChangedAt) } ?? 0
        }
    }

    var located: [Located] {
        allPanes.map { Located(project: $0, tab: $1, pane: $2, session: sessions[$2.id]) }
    }

    /// Debts rather than a list of sessions: only those stuck on a question,
    /// and first the one that has been waiting longest.
    var waitingQueue: [Located] {
        located
            .filter { $0.status == .waiting }
            .sorted { $0.age > $1.age }
    }

    /// Everything for the overview: by urgency, and within it by who has been
    /// in that state the longest.
    var overview: [Located] {
        located
            .filter { filter == nil || $0.status == filter }
            .sorted {
                $0.status.urgency != $1.status.urgency
                    ? $0.status.urgency < $1.status.urgency
                    : $0.age > $1.age
            }
    }

    /// The palette needs the whole list regardless of the overview's filter.
    var allByUrgency: [Located] {
        located.sorted {
            $0.status.urgency != $1.status.urgency
                ? $0.status.urgency < $1.status.urgency
                : $0.age > $1.age
        }
    }

    /// The states of a project's sessions in tab order — the strip under its
    /// name.
    func statuses(of projectID: String) -> [AgentStatus] {
        tabs(of: projectID).flatMap { tab in
            tab.panes.map { sessions[$0.id]?.status ?? .none }
        }
    }

    // MARK: - Projects

    /// One directory can be opened more than once.
    ///
    /// Picking it again used to switch to the project already open: a second
    /// project on the same folder looked like a slip. But the directory is
    /// chosen in a dialog, and somebody who got as far as "Open" asked for a
    /// new project precisely; a silent switch reads to them as a refusal. A set
    /// of tabs for chasing a bug next to a set for a feature in the same repo
    /// is an everyday thing.
    func addProject(path: String) {
        var project = Project(path: path)
        project.rename(to: Project.uniqueName(project.name, among: projects.map(\.name)))
        projects.append(project)
        tabs[project.id] = []
        activeProjectID = project.id

        newTab()
    }

    func renameProject(_ projectID: String, to name: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }

        projects[index].rename(to: name)
        scheduleSave()
    }

    func removeProject(_ projectID: String) {
        for tab in tabs(of: projectID) {
            for pane in tab.panes { discardSession(pane.id) }
        }
        tabs[projectID] = nil
        activeTabIDs[projectID] = nil
        projects.removeAll { $0.id == projectID }

        if activeProjectID == projectID {
            activeProjectID = projects.first?.id
        }

        ensureSessionsForActiveTab()
        scheduleSave()
    }

    func selectProject(_ projectID: String) {
        guard activeProjectID != projectID else { return }
        activeProjectID = projectID
        ensureSessionsForActiveTab()
        scheduleSave()
    }

    func selectProject(index: Int) {
        guard projects.indices.contains(index) else { return }
        selectProject(projects[index].id)
    }

    /// The neighbouring project down the sidebar list, wrapping around — the
    /// same as tabs inside it.
    func cycleProject(by delta: Int) {
        guard projects.count > 1,
              let current = projects.firstIndex(where: { $0.id == activeProjectID })
        else { return }

        let next = (current + delta % projects.count + projects.count) % projects.count
        selectProject(projects[next].id)
    }

    // MARK: - Tabs

    /// `⌘T` raises an agent rather than a shell: the app is about Claude Code
    /// first of all, and that is what the frequent action should be.
    func newTab(kind: PaneKind = .claude, cwd: String? = nil) {
        guard let project = activeProject else { return }

        openTab(
            PaneSpec(
                title: kind == .claude ? "claude" : project.name,
                cwd: cwd ?? activeSessionCwd ?? project.path,
                kind: kind
            )
        )
    }

    private func openTab(_ pane: PaneSpec) {
        guard let project = activeProject else { return }

        let tab = TabSpec(pane: pane)
        tabs[project.id, default: []].append(tab)
        activeTabIDs[project.id] = tab.id

        ensureSessionsForActiveTab()
        scheduleSave()
    }

    /// The live cwd of the active pane: a new tab opens where the human is
    /// standing now, not where the project began.
    private var activeSessionCwd: String? {
        guard let id = activePaneID, let session = sessions[id] else { return nil }
        return session.cwd
    }

    func closeTab(_ tabID: String) {
        // We search across all projects, not only the active one: the palette
        // can close a tab the human has not walked over to yet.
        guard let projectID = projects.map(\.id).first(where: { id in
            tabs(of: id).contains { $0.id == tabID }
        }), var list = tabs[projectID],
            let index = list.firstIndex(where: { $0.id == tabID })
        else { return }

        for pane in list[index].panes { discardSession(pane.id) }
        list.remove(at: index)
        tabs[projectID] = list

        if activeTabIDs[projectID] == tabID {
            // We move to the neighbour on the left, the way browsers and Kero
            // do.
            activeTabIDs[projectID] = list.isEmpty
                ? nil
                : list[min(max(index - 1, 0), list.count - 1)].id
        }

        ensureSessionsForActiveTab()
        scheduleSave()
    }

    func selectTab(_ tabID: String) {
        guard let projectID = activeProjectID, activeTabIDs[projectID] != tabID else { return }
        activeTabIDs[projectID] = tabID
        ensureSessionsForActiveTab()
        scheduleSave()
    }

    func selectTab(index: Int) {
        guard let projectID = activeProjectID else { return }
        let list = tabs(of: projectID)
        guard list.indices.contains(index) else { return }
        selectTab(list[index].id)
    }

    func cycleTab(by delta: Int) {
        guard let projectID = activeProjectID else { return }
        let list = tabs(of: projectID)
        guard list.count > 1,
              let current = list.firstIndex(where: { $0.id == activeTabIDs[projectID] })
        else { return }

        let next = (current + delta % list.count + list.count) % list.count
        selectTab(list[next].id)
    }

    // MARK: - Panes

    /// Splits the active pane in two.
    ///
    /// What to raise is stated explicitly rather than inherited from the
    /// neighbour: next to an agent a console is needed more often than a second
    /// agent, and the other way round happens too. Only the cwd is inherited —
    /// a split stays work alongside, in the same directory.
    func splitActivePane(_ axis: SplitAxis, kind: PaneKind = .claude) {
        guard let projectID = activeProjectID, let tab = activeTab else { return }

        let source = tab.activePane

        // The title is taken from the neighbour only for a console next to a
        // console: a shell budded off an agent would otherwise be called
        // "claude".
        let title = switch kind {
        case .claude: "claude"
        case .shell: source.kind == .shell ? source.title : (activeProject?.name ?? "shell")
        }

        let pane = PaneSpec(
            title: title,
            cwd: sessions[source.id]?.cwd ?? source.cwd,
            kind: kind
        )

        update(tab: tab.id, in: projectID) { tab in
            tab.setLayout(
                tab.layout.replacing(
                    source.id,
                    with: .split(.init(axis: axis, first: .leaf(source), second: .leaf(pane)))
                ),
                activePaneID: pane.id
            )
        }

        ensureSessionsForActiveTab()
        scheduleSave()
    }

    /// Closes a pane. The last pane closes the whole tab — otherwise a tab
    /// without a single session would be left behind.
    func closePane(_ paneID: String) {
        guard let (projectID, tab) = locate(paneID) else { return }

        guard tab.paneCount > 1 else {
            closeTab(tab.id)
            return
        }

        discardSession(paneID)
        update(tab: tab.id, in: projectID) { tab in
            guard let layout = tab.layout.removing(paneID) else { return }
            tab.setLayout(layout)
        }

        focusActivePane()
        scheduleSave()
    }

    func closeActivePane() {
        guard let paneID = activePaneID else { return }
        closePane(paneID)
    }

    /// Makes a pane active, switching the project and the tab if need be.
    func focusPane(_ paneID: String) {
        guard let (projectID, tab) = locate(paneID) else { return }

        // Leaving the overview happens before the "already active" check:
        // otherwise clicking the card of a pane that is active anyway would do
        // exactly nothing, and the overview would stay on screen. The
        // comparison is a must, or every click in the terminal would trigger a
        // window redraw.
        if mode != .work { mode = .work }

        // The "already active" exit is mandatory: clicks in the terminal arrive
        // here too, and those happen on every mouse move with a button down.
        guard activeProjectID != projectID
            || activeTabIDs[projectID] != tab.id
            || tab.activePaneID != paneID
        else { return }

        activeProjectID = projectID
        activeTabIDs[projectID] = tab.id
        update(tab: tab.id, in: projectID) { $0.focus(paneID) }

        // We came to the pane — the banner about it in Notification Center is
        // no longer true.
        notifier.clear(paneID: paneID)

        ensureSessionsForActiveTab()
        focusActivePane()
        scheduleSave()
    }

    /// Makes active the pane the click landed in.
    ///
    /// We search by view rather than by a SwiftUI gesture: a gesture on top of
    /// an `NSView` would eat what is meant for the terminal itself.
    func focusPane(containing view: NSView) {
        var current: NSView? = view
        while let candidate = current {
            if let session = sessions.values.first(where: { $0.view === candidate }) {
                focusPane(session.paneID)
                return
            }
            current = candidate.superview
        }
    }

    func focus(_ direction: PaneDirection) {
        guard let tab = activeTab,
              let target = tab.layout.neighbour(of: tab.activePaneID, to: direction)
        else { return }
        focusPane(target)
    }

    func setRatio(_ splitID: String, to ratio: Double) {
        guard let projectID = activeProjectID, let tab = activeTab else { return }
        update(tab: tab.id, in: projectID) { tab in
            tab.setLayout(tab.layout.settingRatio(splitID, to: ratio))
        }
        scheduleSave()
    }

    /// Moving to the next agent that waits for a human. The order walks every
    /// project, so that a question in a background tab does not go unnoticed.
    func focusNextWaiting() {
        let waiting = allPanes
            .map(\.pane.id)
            .filter { sessions[$0]?.status == .waiting }
        guard !waiting.isEmpty else { return }

        let index = waiting.firstIndex(of: activePaneID ?? "") ?? -1
        focusPane(waiting[(index + 1) % waiting.count])
    }

    /// Returns focus to the active pane: after the palette, or after closing a
    /// neighbour, the next character would otherwise go nowhere.
    func focusActivePane() {
        guard let id = activePaneID, let session = sessions[id] else { return }
        DispatchQueue.main.async {
            session.view.window?.makeFirstResponder(session.view)
        }
    }

    // MARK: - Session catalog

    /// Claude Code sessions found on disk for the active project.
    ///
    /// Refreshed on demand rather than by watching the directory: the list is
    /// needed exactly at the moment the palette opens, and it costs reading
    /// dozens of transcripts.
    private(set) var knownSessions: [SessionCatalog.Record] = []

    /// The branches this project already has a worktree for.
    private(set) var knownWorktrees: [String] = []

    func refreshKnownSessions() {
        guard let path = activeProject?.path else {
            knownSessions = []
            knownWorktrees = []
            return
        }

        // The branch list is short and takes one directory read — the palette
        // needs it right away, not on the next frame.
        knownWorktrees = Worktree.names(inside: path)

        Task {
            // The reading leaves the main actor: by then the palette is already
            // on screen and has to answer typing.
            knownSessions = await Task.detached(priority: .userInitiated) {
                SessionCatalog.sessions(forProject: path)
            }.value
        }
    }

    /// Opens a tab continuing an existing Claude Code session.
    ///
    /// If the session is open somewhere already, that is where we go: two
    /// `--resume` on one id are two processes writing into one transcript.
    func resume(_ record: SessionCatalog.Record) {
        if let live = allPanes.first(where: { $0.pane.agentSessionID == record.id }) {
            focusPane(live.pane.id)
            return
        }

        guard let project = activeProject else { return }

        openTab(
            PaneSpec(
                title: record.label,
                // Strictly the project's path, not the active pane's cwd:
                // `--resume` looks for the session in the directory it was
                // started from and will not find it from a neighbouring one. A
                // session from a branch is taken into its directory by Claude
                // Code itself — by the worktree's name.
                cwd: project.path,
                kind: .claude,
                agentSessionID: record.id,
                transcriptPath: record.transcriptPath,
                worktree: record.worktree
            )
        )
    }

    /// Raises an agent in a separate branch.
    ///
    /// The worktree is created by Claude Code itself under `--worktree`, so the
    /// pane starts in the project directory rather than in the branch's: it
    /// moves there from the inside. The name stays in the snapshot — it is what
    /// brings the pane back to its branch after a restart.
    func newWorktreeTab(named name: String) {
        guard let project = activeProject, let name = Worktree.sanitize(name) else { return }

        openTab(
            PaneSpec(title: name, cwd: project.path, kind: .claude, worktree: name)
        )
    }

    // MARK: - Sessions

    /// Raises the sessions of every pane in the active tab: they are visible at
    /// the same time, so there is nothing to postpone. Laziness stayed at the
    /// tab level — an invisible tab still costs no process.
    private func ensureSessionsForActiveTab() {
        guard let tab = activeTab else { return }

        for pane in tab.panes where sessions[pane.id] == nil {
            let session = TerminalSession(pane: pane, hooks: hooks?.config)
            session.onChange = { [weak self] session in
                self?.absorb(session)
            }
            sessions[pane.id] = session
            session.start()
        }

        markSeen()
        focusActivePane()
    }

    /// Clears the debt without answering the agent at all.
    ///
    /// The same trick as with "done" when a tab is opened: a state is about the
    /// human's attention, not about the process. Sorted it out in another
    /// window, answered by hand, changed their mind — the debt is settled. The
    /// real state of affairs comes back with the agent's very next event.
    func markHandled(_ paneID: String) {
        guard let session = sessions[paneID], session.status == .waiting else { return }

        session.setStatus(.idle)
        // This goes into the feed on equal terms with hook events: otherwise
        // "waited — then vanished" would look like a failure in the history.
        record(session, byHand: true)
    }

    /// "Done" fades into rest as soon as the tab is opened: the whole point of
    /// that state is "the output is written, but nobody has read it".
    private func markSeen() {
        guard let tab = activeTab else { return }

        for pane in tab.panes where sessions[pane.id]?.status == .done {
            sessions[pane.id]?.setStatus(.idle)
        }
    }

    /// The title and the cwd from escape sequences go into the snapshot so that
    /// they survive a restart.
    private func absorb(_ session: TerminalSession) {
        guard let (projectID, tab) = locate(session.paneID) else { return }

        update(tab: tab.id, in: projectID) { tab in
            tab.setLayout(
                tab.layout.updating(session.paneID) { pane in
                    var copy = pane
                    copy.title = session.name
                    copy.cwd = session.cwd
                    copy.agentSessionID = session.agentSessionID
                    copy.transcriptPath = session.transcriptPath
                    return copy
                }
            )
        }
        scheduleSave()
    }

    private func discardSession(_ paneID: String) {
        sessions.removeValue(forKey: paneID)?.terminate()
        notifier.clear(paneID: paneID)
        syncBadge()
    }

    // MARK: - Housekeeping

    private func locate(_ paneID: String) -> (projectID: String, tab: TabSpec)? {
        for (projectID, list) in tabs {
            if let tab = list.first(where: { $0.layout.contains(paneID) }) {
                return (projectID, tab)
            }
        }
        return nil
    }

    private func update(tab tabID: String, in projectID: String, _ change: (inout TabSpec) -> Void) {
        guard var list = tabs[projectID],
              let index = list.firstIndex(where: { $0.id == tabID })
        else { return }

        change(&list[index])
        tabs[projectID] = list
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard restored else { return }
        try? store.save(
            WorkspaceSnapshot(
                projects: projects,
                tabs: tabs,
                activeProjectID: activeProjectID,
                activeTabIDs: activeTabIDs
            )
        )
    }
}
