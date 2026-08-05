import AppKit
import RoostCore
import SwiftUI

/// Search across the whole workspace plus a list of actions — for when the hand
/// does not remember the shortcut, and hunting for the right pane by eye takes
/// longer than typing its name.
struct CommandPalette: View {
    let model: WorkspaceModel

    /// The query and the selected row live outside: the window intercepts the
    /// arrows, and it must have something to move.
    @Bindable var state: PaletteState

    /// Closing is the window's business. The flag says whether to return focus
    /// to the pane: after a command the pane takes it itself, and it must not
    /// be taken back.
    let dismiss: (Bool) -> Void

    @FocusState private var focused: Bool

    private struct Command: Identifiable {
        let id = UUID()

        /// The group's header: the project's name for panes, "actions" for the
        /// rest.
        let group: String

        let label: String

        /// The right column: a shortcut or a path — what qualifies the row but
        /// is not searched.
        let hint: String?

        let status: AgentStatus
        let run: () -> Void
    }

    /// The order is deliberate: first "where to go", then "what to do".
    /// Navigation is the most frequent reason the palette is opened at all.
    private var commands: [Command] {
        // Came for a branch — show branches only.
        guard state.scope != .worktree else { return worktrees }

        // Came for a session — sessions only.
        guard state.scope == .everything else { return sessions }

        // Panes go by urgency: if you open the palette while somebody is
        // waiting, that somebody belongs on top.
        var commands = model.allByUrgency.map { item in
            Command(
                group: item.project.name,
                label: item.title,
                hint: item.tab.paneCount > 1 ? "split" : nil,
                status: item.status,
                run: { model.focusPane(item.pane.id) }
            )
        }

        commands += [
            Command(group: "actions", label: "new claude session", hint: "⌘T", status: .none) {
                model.newTab()
            },
            Command(group: "actions", label: "new shell", hint: "⌘⇧T", status: .none) {
                model.newTab(kind: .shell)
            },
            Command(group: "actions", label: "split right with claude", hint: "⌘D", status: .none) {
                model.splitActivePane(.row, kind: .claude)
            },
            Command(group: "actions", label: "split down with claude", hint: "⌘⇧D", status: .none) {
                model.splitActivePane(.column, kind: .claude)
            },
            Command(group: "actions", label: "split right with shell", hint: "⌘E", status: .none) {
                model.splitActivePane(.row, kind: .shell)
            },
            Command(group: "actions", label: "split down with shell", hint: "⌘⇧E", status: .none) {
                model.splitActivePane(.column, kind: .shell)
            },
            Command(group: "actions", label: "close pane", hint: "⌘W", status: .none) {
                model.closeActivePane()
            },
            Command(group: "actions", label: "jump to waiting agent", hint: "⌘⇧A", status: .none) {
                model.focusNextWaiting()
            },
            Command(group: "actions", label: "overview of all sessions", hint: nil, status: .none) {
                model.mode = .deck
            },
            Command(group: "actions", label: "new project", hint: "⌘N", status: .none) {
                openProject(model: model)
            },
        ]

        commands += worktrees

        commands += model.projects.map { project in
            Command(
                group: "projects",
                label: project.name,
                hint: project.path,
                status: .none
            ) { model.selectProject(project.id) }
        }

        // Past sessions go at the very tail. There are many of them and they
        // are called for rarely: let them push aside neither live panes nor
        // actions.
        return commands + sessions
    }

    /// The project's sessions as they lie on disk.
    private var sessions: [Command] {
        model.knownSessions.map { record in
            let age = relativeAge(Date().timeIntervalSince(record.modified))

            return Command(
                group: "sessions",
                label: record.label,
                // The branch matters more than the age: continuing a session
                // without knowing which tree it edited files in is a sure way
                // to be surprised.
                hint: record.worktree.map { "\($0) · \(age)" } ?? age,
                status: .none
            ) { model.resume(record) }
        }
    }

    /// The branches this project already has a worktree for.
    private var worktrees: [Command] {
        model.knownWorktrees.map { name in
            Command(group: "worktrees", label: name, hint: "claude in branch", status: .none) {
                model.newWorktreeTab(named: name)
            }
        }
    }

    /// Rows assembled from what was typed rather than found among ready ones.
    ///
    /// The filter must not see them: they are made of the query anyway, and a
    /// subsequence search would drop them at the first character missing from
    /// the label — a dash in a uuid or a space in a branch name.
    private var drafts: [Command] { [pasted, worktreeDraft].compactMap { $0 } }

    /// A typed name is a bid for a new branch.
    ///
    /// Shown in the general palette too: there is nowhere else to learn that
    /// worktrees exist, and a row at the bottom of the list bothers nobody. A
    /// branch that already exists is not offered again — it stands higher with
    /// a row of its own.
    private var worktreeDraft: Command? {
        guard state.scope != .sessions, let project = model.activeProject,
              Worktree.isRepository(project.path),
              let name = Worktree.sanitize(state.query),
              !model.knownWorktrees.contains(name)
        else { return nil }

        return Command(
            group: "worktrees",
            label: "new worktree \(name)",
            hint: "claude in branch worktree-\(name)",
            status: .none
        ) { model.newWorktreeTab(named: name) }
    }

    /// A pasted uuid is a command in itself.
    ///
    /// A session started on another device cannot be found in the list: that
    /// list holds only what lies on this machine. Its id, though, the human
    /// knows — and that is enough, if the transcript arrived after it.
    private var pasted: Command? {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        guard UUID(uuidString: query) != nil, let project = model.activeProject else {
            return nil
        }

        let label = "resume \(query.prefix(8))"

        // About what is not on disk it is fairer to say so at once: `--resume`
        // on a vanished transcript would silently open a clean session, and the
        // human would find out only by not finding their conversation in it.
        switch SessionCatalog.resolve(query, project: project.path) {
        case .here(let record):
            return Command(group: "sessions", label: label, hint: record.title, status: .none) {
                model.resume(record)
            }

        case .elsewhere(let path):
            return Command(
                group: "sessions",
                label: label,
                hint: "another project — reveal",
                status: .none
            ) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

        case .missing(let directory):
            return Command(
                group: "sessions",
                label: label,
                hint: "no transcript — open folder",
                status: .none
            ) { reveal(directory) }
        }
    }

    /// Opens the project's session directory — the very one an arriving
    /// transcript has to be put into. We create it if the project is new:
    /// showing a human a path that does not exist is showing them nothing.
    private func reveal(_ directory: String) {
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private var placeholder: String {
        switch state.scope {
        case .everything: "Session, project or command…"
        case .sessions: "Resume a session — search or paste an id…"
        case .worktree: "Name a branch — claude will work in its own worktree…"
        }
    }

    /// An empty list says not "nothing found" but "nothing to continue" or
    /// "type a name": the difference matters to a human.
    private var emptyLine: String {
        guard state.query.isEmpty else { return "nothing found" }

        return switch state.scope {
        case .sessions: "no sessions for this project yet"
        case .worktree: "no worktrees yet — type a branch name"
        case .everything: "nothing found"
        }
    }

    private var matches: [Command] {
        let needle = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return commands }

        // Rows assembled from the query come first: nobody types them in order
        // to go looking for them afterwards.
        return drafts + commands.filter {
            fuzzyMatch("\($0.group) \($0.label)".lowercased(), needle)
        }
    }

    var body: some View {
        let matches = matches
        let selected = matches.isEmpty ? 0 : min(state.selection, matches.count - 1)

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("›").font(Typography.item).foregroundStyle(Palette.accent)

                TextField(placeholder, text: $state.query)
                    .textFieldStyle(.plain)
                    .font(Typography.item)
                    .foregroundStyle(Palette.text)
                    .focused($focused)
                    .onChange(of: state.query) { state.selection = 0 }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 9)

            Hairline()

            if matches.isEmpty {
                Text(emptyLine)
                    .font(Typography.item)
                    .foregroundStyle(Palette.muted)
                    .padding(Metrics.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                            // The header is printed when the group changes:
                            // that shows which project a row comes from without
                            // repeating it on every one.
                            if index == 0 || matches[index - 1].group != command.group {
                                Text(command.group.uppercased())
                                    .font(Typography.label)
                                    .kerning(1)
                                    .foregroundStyle(Palette.faint)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 9)
                                    .padding(.bottom, 5)
                            }

                            row(command, isSelected: index == selected)
                                .onTapGesture { run(matches, at: index) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 520)
        .background(Palette.chrome)
        .overlay(Rectangle().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
        .onAppear {
            focused = true

            // The text field takes Return as well, so running a row lives where
            // the arrows do: in the window. The matches are counted at the
            // moment of the press, so that the closure does not hold on to a
            // stale list.
            state.submit = {
                let matches = self.matches
                run(matches, at: min(state.selection, max(matches.count - 1, 0)))
            }
        }
        // Only whoever counted the matches knows the bounds of the selection —
        // the window is left to move the index inside them.
        .onChange(of: matches.count, initial: true) { _, count in
            state.count = count
            state.selection = min(state.selection, max(count - 1, 0))
        }
    }

    private func row(_ command: Command, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isSelected ? Palette.accent : .clear)
                .frame(width: Metrics.marker)
                .padding(.trailing, 9)

            Group {
                if command.status != .none {
                    AgentMark(status: command.status)
                }
            }
            .frame(width: 10, alignment: .leading)

            Text(command.label)
                .font(Typography.item)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? Palette.text : Palette.muted)

            Spacer(minLength: 10)

            if let hint = command.hint {
                Text(hint)
                    .font(Typography.label)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(Palette.faint)
            }
        }
        .padding(.trailing, 12)
        .frame(height: Metrics.rowHeight)
        .background(isSelected ? Palette.lineSoft : .clear)
        .contentShape(Rectangle())
    }

    private func run(_ matches: [Command], at index: Int) {
        guard matches.indices.contains(index) else { return }
        // Closed before running: a command may move the focus, and the palette
        // on top of it would be exactly what gets in the way.
        dismiss(false)
        matches[index].run()
    }
}

/// The palette's state lives apart from the view: the window intercepts arrows
/// before the text field does, and it needs to move the selection where the
/// view reads it from.
@MainActor
@Observable
final class PaletteState {
    /// What the palette should show.
    ///
    /// A scope is not a filter on the query but a different reason to open the
    /// palette at all: `⌘K` is called when you do not know what you are looking
    /// for, `⌘O` when you know exactly. In the second case live panes and
    /// commands would only stand between you and the session you want.
    enum Scope: Hashable {
        case everything
        case sessions

        /// A branch name: here the input line does not search, it names.
        case worktree
    }

    let scope: Scope

    var query = ""
    var selection = 0

    /// The number of matches from the last draw — the selection will not walk
    /// out of the list.
    var count = 0

    /// Running the selected row: the window catches the press, but only the
    /// view knows what to run.
    @ObservationIgnored var submit: (() -> Void)?

    init(scope: Scope = .everything) {
        self.scope = scope
    }

    func move(_ delta: Int) {
        guard count > 0 else { return }
        selection = (selection + delta % count + count) % count
    }
}

/// Subsequence search: `stbr` finds `status_bar`.
///
/// Exactly what one expects of a palette — there is no need to type the full
/// name, and ranking would be overkill here: there are dozens of rows, not
/// thousands.
func fuzzyMatch(_ text: String, _ query: String) -> Bool {
    var index = text.startIndex

    for character in query {
        guard let found = text[index...].firstIndex(of: character) else { return false }
        index = text.index(after: found)
    }
    return true
}
