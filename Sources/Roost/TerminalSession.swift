import AppKit
import RoostCore
import SwiftTerm

/// A pane's live session: the terminal view together with its process.
///
/// The session belongs to the model, not to the view. Thanks to that, switching
/// a project or a tab does not unmount the terminal and does not kill the
/// running processes — SwiftUI is handed an `NSView` that already exists.
@MainActor
@Observable
final class TerminalSession {
    let paneID: String
    let kind: PaneKind

    /// The title the process sets through OSC 0/2.
    private(set) var title: String

    /// Driven by Claude Code hooks; always `.none` for shell panes.
    private(set) var status: AgentStatus

    /// When the state became current — this is where "waiting 4:12" comes from.
    private(set) var statusChangedAt = Date()

    /// What the agent asked about. It arrives with the notification and lives
    /// as long as the agent waits: the attention queue shows it instead of the
    /// output.
    private(set) var question: String?

    /// The agent's last message from the transcript — what it said out loud
    /// before running into a question. Read on events rather than on every
    /// redraw: the cards are repainted by a one-second timer.
    private(set) var lastAgentMessage: String?

    /// The name Claude Code invented for the session out of the conversation.
    private(set) var agentTitle: String?

    /// What the pane is called on screen. A session's name says more than the
    /// window title: for every claude pane that title is the same — "Claude
    /// Code".
    var name: String { agentTitle ?? title }

    /// The live cwd from OSC 7 — new panes open there.
    private(set) var cwd: String

    /// The Claude Code session's UUID and the path to its transcript. Known
    /// from the very first hook, that is, practically from the launch.
    private(set) var agentSessionID: String?
    private(set) var transcriptPath: String?

    @ObservationIgnored let view: PaneTerminalView

    /// The model learns about the title and the cwd through closures: updating
    /// the snapshot is its job, not the session's.
    @ObservationIgnored var onChange: ((TerminalSession) -> Void)?

    private var started = false

    init(pane: PaneSpec, hooks: AgentHooksConfig?) {
        self.paneID = pane.id
        self.kind = pane.kind
        self.title = pane.title
        self.cwd = pane.cwd
        self.status = pane.kind == .claude ? .idle : .none
        // The session from the snapshot is taken right away: `absorb` rewrites
        // the pane wholesale and, until the first hook, would wipe the very id
        // this is all about.
        self.agentSessionID = pane.agentSessionID
        self.transcriptPath = pane.transcriptPath
        self.launch = PaneLaunch(pane: pane, hooks: hooks)

        view = PaneTerminalView(frame: .zero)
        view.configureTheme()
        view.processDelegate = self
    }

    @ObservationIgnored private let launch: PaneLaunch

    /// Starts the process. Repeated calls are ignored: a pane may be remounted
    /// when tabs are switched, while the process must stay a single one.
    func start() {
        guard !started else { return }
        started = true

        view.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment,
            currentDirectory: launch.workingDirectory
        )
    }

    /// Remembers which Claude Code session the pane belongs to. The id does not
    /// normally change, but `/clear` starts a new session in the same process —
    /// which is why we write it every time, not only the first.
    func adopt(sessionID: String?, transcriptPath: String?) {
        guard let sessionID else { return }

        let isNew = sessionID != agentSessionID
        agentSessionID = sessionID
        self.transcriptPath = transcriptPath

        // A continued session arrives with the same id that was in the
        // snapshot — "did the id change" cannot tell it from nothing at all.
        // So we read even when there is no message yet: otherwise a resumed
        // pane's card would stay silent until the agent's first move, though it
        // has something to say.
        if isNew || lastAgentMessage == nil { refreshLastMessage() }

        // Into the snapshot immediately: the app may not live until the next
        // save, and without the id the pane would come back to an empty dialog.
        if isNew { onChange?(self) }
    }

    /// The single point where the state changes: the countdown and the question
    /// text are updated along with it.
    func setStatus(_ status: AgentStatus, question: String? = nil) {
        guard kind == .claude else { return }

        let changed = status != self.status
        if changed {
            statusChangedAt = Date()
        }
        self.status = status
        // The question lives exactly as long as the agent waits for an answer.
        self.question = status == .waiting ? (question ?? self.question) : nil

        // A hook brings the occasion, not the words: "needs permission for
        // Bash" reads the same for everyone. What the agent said is in the
        // transcript.
        //
        // We re-read on a state change and on every wait: while the agent
        // waits, the question may change while the status does not.
        if changed || status == .waiting {
            refreshLastMessage()
        }
    }

    /// Reads the tail of the transcript. Driven by events rather than by
    /// drawing: the cards are repainted by a one-second timer.
    private func refreshLastMessage() {
        guard let path = transcriptPath else { return }

        let reading = Transcript.read(at: path)
        lastAgentMessage = reading.message

        // The session's name goes into the snapshot so that a restored tab is
        // called the same rather than "claude".
        if let title = reading.title, title != agentTitle {
            agentTitle = title
            onChange?(self)
        }
    }

    /// The last non-empty lines of the screen — the overview cards are built
    /// out of them.
    func recentLines(_ limit: Int) -> [String] {
        let terminal = view.getTerminal()
        var lines: [String] = []

        for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
            guard lines.count < limit else { break }
            guard let line = terminal.getLine(row: row) else { continue }

            let text = line.translateToString(trimRight: true)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.reversed()
    }

    func terminate() {
        view.processDelegate = nil
        // SwiftTerm closes the PTY itself when the view is released; LocalProcess
        // has no separate kill in its public API.
        view.terminate()
    }
}

/// SwiftTerm's protocol is declared without `@MainActor`, though it is called
/// from the main queue. `@preconcurrency` allows satisfying its requirements
/// with main-actor methods, adding a runtime check.
extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.title = trimmed
        onChange?(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }

        cwd = directory
        onChange?(self)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        setStatus(.exited)
    }
}

/// The pane's terminal.
///
/// A type of its own — so that a session can be found by its view: clicking a
/// pane makes it active, and the click is caught by an event monitor in
/// `AppDelegate`. Overriding `becomeFirstResponder` is not an option: in
/// SwiftTerm it is `public`, not `open`.
final class PaneTerminalView: LocalProcessTerminalView {
    /// SwiftTerm resolves a colour once, when it is set, and keeps its own copy
    /// — so a dynamic `NSColor` would freeze in whichever appearance was
    /// current at launch. Switching the system to light left the pane black
    /// inside a white window; this is what puts the two back together.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()

        effectiveAppearance.performAsCurrentDrawingAppearance {
            configureTheme()
        }
    }
}

private extension LocalProcessTerminalView {
    /// The terminal is lighter than the chrome around it — the same trick as in
    /// the panes.
    func configureTheme() {
        font = Typography.terminal
        nativeBackgroundColor = Palette.terminalBackground
        nativeForegroundColor = Palette.terminalForeground
    }
}
