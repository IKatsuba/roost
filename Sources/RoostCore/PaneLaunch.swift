import Foundation

/// What a pane runs, and with which environment.
public struct PaneLaunch: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]

    /// In `KEY=VALUE` form — exactly how SwiftTerm expects them.
    public let environment: [String]

    public let workingDirectory: String?

    public static func defaultShell() -> String {
        // SHELL comes from the environment of the terminal that launched us,
        // and a bundled app starts from launchd, where the variable may not
        // exist at all.
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// `sessions` is Claude Code's transcript catalog. A parameter rather than
    /// a constant: it decides whether a session is started or continued, and a
    /// test must not have to ask the home directory.
    public init(
        pane: PaneSpec,
        hooks: AgentHooksConfig? = nil,
        sessions root: URL = SessionCatalog.defaultRoot
    ) {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"

        // Borrowing another terminal's name is not a pose — it is the only way
        // to get Shift+Enter.
        //
        // A plain terminal cannot tell Enter and Shift+Enter apart: both arrive
        // as a single `\r`. The extended (kitty) keyboard protocol can, and
        // SwiftTerm speaks it — but it is the application that turns the
        // protocol on, and Claude Code decides by an allow-list of names
        // (`ghostty`, `wezterm`, `alacritty`, …) without ever asking the
        // terminal what it can do. "Roost" is not on that list and never will
        // be, so we introduce ourselves as somebody who is; otherwise
        // Shift+Enter sends the message instead of breaking the line.
        //
        // From a terminal this is invisible: the variable is inherited and
        // usually already right. Under launchd there is none at all — same as
        // `PATH` — and it only shows up in a bundled `.app`.
        environment["TERM_PROGRAM"] = "ghostty"

        let directory = FileManager.default.fileExists(atPath: pane.cwd)
            ? pane.cwd
            : ProcessInfo.processInfo.environment["HOME"]

        switch pane.kind {
        case .shell:
            self.executable = Self.defaultShell()
            self.arguments = ["-l", "-i"]

        case .claude:
            if let hooks {
                environment["ROOST_PANE_ID"] = pane.id
                environment["ROOST_HOOK_URL"] = hooks.hookURL
            }

            // The session is deliberately not put into PTY-surviving mode
            // (CLAUDE_CODE_FORCE_SESSION_PERSISTENCE): a closed app would leave
            // it living as a background agent under the daemon, and `--resume`
            // does not attach to such a session at all — only `claude agents`
            // by hand. Let the pane close together with its session: `--resume`
            // brings the history back, and it is not going anywhere.
            let settings = hooks.map { " --settings '\($0.settingsPath)'" } ?? ""

            // Through a login-interactive shell rather than directly: claude
            // lives in ~/.local/bin, while a bundled app gets a bare
            // /usr/bin:/bin PATH from launchd. The -i flag is mandatory — PATH
            // is edited in .zshrc, which a non-interactive login shell skips.
            self.executable = Self.defaultShell()
            self.arguments = [
                "-l", "-i", "-c", Self.command(settings: settings, pane: pane, sessions: root),
            ]
        }

        self.environment = environment.map { "\($0.key)=\($0.value)" }.sorted()
        self.workingDirectory = directory
    }

    /// What the pane's shell will actually run.
    ///
    /// A pane names its own session, and one and the same session goes by two
    /// different flags: `--session-id` before it starts, `--resume` after. They
    /// must not be confused, and both refusals are fatal: claude greets a taken
    /// id with "already in use", and an empty `--resume` has nothing to
    /// continue. The fork is the transcript on disk, and only it — the snapshot
    /// field is no judge here.
    ///
    /// Continuation always has a safety net: `--resume` also fails for reasons
    /// nobody can foresee — somebody else may have grabbed the session, the
    /// format may have changed. A refusal shows up immediately, so a short life
    /// of the process is the tell: if it did not work out, open a clean session
    /// instead of leaving a dead pane with a red line where the agent should
    /// be. Anything that lived longer is an ordinary exit from claude, and
    /// there is no reason to meddle.
    static func command(settings: String, pane: PaneSpec, sessions root: URL) -> String {
        let claude = "claude\(settings)\(worktree(for: pane))"
        guard let session = sessionID(of: pane) else { return "exec \(claude)" }

        guard transcript(of: pane, sessions: root) != nil else {
            return "exec \(claude) --session-id '\(session)'"
        }

        // The safety net carries no session name: the id is taken by the very
        // transcript that brought us here, and a clean session cannot be called
        // by it. Whatever opens instead, Roost learns its name from the first
        // hook.
        return "\(claude) --resume '\(session)' || { [ $SECONDS -lt 5 ] && exec \(claude); }"
    }

    /// The worktree flag — on the first launch and on continuation alike.
    ///
    /// `claude -w name` creates the worktree once and enters it afterwards, so
    /// the flag belongs next to `--resume` as well: the session lives in the
    /// worktree directory, and without it there would be nothing to continue.
    /// The name is sanitised once more, right at the command: the snapshot is
    /// ordinary json next to the home directory, and a quote typed into it by
    /// hand would otherwise become a shell command of its own.
    static func worktree(for pane: PaneSpec) -> String {
        guard let name = pane.worktree.flatMap(Worktree.sanitize) else { return "" }
        return " --worktree '\(name)'"
    }

    /// The session id — a real uuid and nothing else.
    ///
    /// The check is not redundant: the id travels into the command inside
    /// single quotes, and the snapshot is ordinary json a quote can be typed
    /// into by hand. It is also the only format `--session-id` accepts anyway.
    static func sessionID(of pane: PaneSpec) -> String? {
        guard pane.kind == .claude, let id = pane.agentSessionID, UUID(uuidString: id) != nil
        else { return nil }

        return id
    }

    /// The pane's session transcript, if the session has already started.
    ///
    /// The path from the snapshot is a shortcut, not the only route: a hook
    /// brings it, and a hook may never arrive. A session that does exist on
    /// disk would then count as unstarted, and the pane would try to name it
    /// with a taken id — that is, would not open at all. So the second pass
    /// looks the file up by id.
    static func transcript(of pane: PaneSpec, sessions root: URL) -> String? {
        guard let id = sessionID(of: pane) else { return nil }

        if let path = pane.transcriptPath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        return SessionCatalog.transcript(of: id, cwd: sessionCwd(of: pane), root: root)
    }

    /// The directory Claude Code keeps the pane's session in.
    ///
    /// For a branch that is the worktree's own directory, not the project's:
    /// the pane stands in the project, but the agent moves into the worktree
    /// and keeps the transcript there.
    static func sessionCwd(of pane: PaneSpec) -> String {
        guard let name = pane.worktree.flatMap(Worktree.sanitize) else { return pane.cwd }
        return Worktree.path(inside: pane.cwd, name: name)
    }
}
