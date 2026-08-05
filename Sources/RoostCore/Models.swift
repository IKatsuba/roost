import Foundation

/// A project is simply the directory that tabs are grouped around.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var path: String

    public init(id: String = UUID().uuidString, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    public init(path: String, id: String = UUID().uuidString) {
        let normalized = path.count > 1 && path.hasSuffix("/")
            ? String(path.dropLast())
            : path
        let name = normalized.split(separator: "/").last.map(String.init)

        self.id = id
        self.path = normalized
        self.name = name ?? normalized
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// A name of one's own instead of the directory's.
    ///
    /// Directories are named alike all the time — `app`, `web`, `server` across
    /// different monorepos — and in the sidebar they are indistinguishable. An
    /// empty string does not count as a name: that is a cleared field, and the
    /// path takes its own back.
    public mutating func rename(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? Project(path: path).name : trimmed
    }

    /// The name with a number, if that one is already taken.
    ///
    /// One directory can be opened twice, and then the sidebar holds two
    /// identical words with an identical path hint — nothing tells them apart
    /// at all. A number gives a foothold until the human names them properly.
    public static func uniqueName(_ name: String, among taken: some Sequence<String>) -> String {
        let taken = Set(taken)
        guard taken.contains(name) else { return name }

        var index = 2
        while taken.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }
}

/// What runs in a pane.
///
/// The distinction is not cosmetic: a claude pane has a different launch
/// command and a different environment — the one Claude Code's hooks use to
/// report the agent's status back to the app.
public enum PaneKind: String, Codable, Hashable, Sendable {
    case shell
    case claude
}

/// What the agent in a pane is doing right now.
///
/// It comes from Claude Code's hooks, so shell panes are always `.none`.
public enum AgentStatus: String, Codable, Hashable, Sendable {
    /// Not an agent — a plain shell.
    case none

    /// The agent is alive and waiting for its next task.
    case idle

    /// Thinking, or running tools.
    case working

    /// Stuck on a question, waiting for a human.
    case waiting

    /// Finished, but nobody has seen the output. Fades into [idle] as soon as
    /// the pane becomes active: that way "done" neither piles up in an alarming
    /// colour nor gets lost in grey.
    case done

    /// The session is over.
    case exited

    /// Order of urgency — it sorts the overview and the palette.
    public var urgency: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .done: 2
        case .idle: 3
        case .none: 4
        case .exited: 5
        }
    }
}

/// The description of one pane — that is, of one live session.
///
/// Only the structure is saved: cwd, title and kind. Buffer contents and
/// running processes are not restored, the PTY comes up from scratch — but a
/// claude pane returns to its former session rather than to a blank slate.
public struct PaneSpec: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var cwd: String
    public var kind: PaneKind

    /// The Claude Code session living in this pane.
    ///
    /// Roost assigns the id, not the agent: claude accepts one through
    /// `--session-id`. Otherwise a pane would learn about its session from a
    /// hook alone, and a hook may never arrive — settings broken, the tab
    /// closed within the first seconds — leaving nothing to continue. The hook
    /// confirms this id; `/clear` inside the pane replaces it with its own.
    public var agentSessionID: String?

    /// The transcript of that same session — a shortcut to the "was there
    /// anything to continue" check. Not the only one: the file is also looked
    /// up by id, see [PaneLaunch].
    public var transcriptPath: String?

    /// The name of the git worktree the agent works in.
    ///
    /// The name is stored, not the path: the pane starts in the project
    /// directory, and Claude Code itself takes it into the worktree under
    /// `--worktree`. The name is needed after a restart too — see [Worktree].
    public var worktree: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        cwd: String,
        kind: PaneKind = .shell,
        agentSessionID: String? = nil,
        transcriptPath: String? = nil,
        worktree: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.kind = kind
        // An id of its own from the pane's birth, not from the agent's first
        // event: everything that loses a session fits between the launch and
        // the hook. Lowercase, the way Claude Code writes them: the id becomes
        // the transcript's file name, and mixed case would only get in the way
        // of finding it.
        self.agentSessionID = agentSessionID
            ?? (kind == .claude ? UUID().uuidString.lowercased() : nil)
        self.transcriptPath = transcriptPath
        self.worktree = worktree
    }
}
