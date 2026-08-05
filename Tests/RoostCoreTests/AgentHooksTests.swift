import Foundation
import Testing

@testable import RoostCore

@Suite("Claude Code events turned into pane status")
struct StatusForEventTests {
    @Test("the agent is at work")
    func working() {
        #expect(statusForEvent("UserPromptSubmit") == .working)
        #expect(statusForEvent("PreToolUse") == .working)
        #expect(statusForEvent("PostToolUse") == .working)
    }

    @Test("a permission request means waiting for a human")
    func waiting() {
        #expect(statusForEvent("PermissionRequest") == .waiting)
        #expect(statusForEvent("Notification", notification: "permission_prompt") == .waiting)
        #expect(statusForEvent("Notification", notification: "agent_needs_input") == .waiting)
    }

    @Test("the end of a turn is \"done\", not rest")
    func done() {
        // The difference is one of meaning: the output is written, but nobody
        // has read it yet.
        #expect(statusForEvent("Stop") == .done)
        #expect(statusForEvent("Notification", notification: "agent_completed") == .done)
        #expect(statusForEvent("SessionStart") == .idle)
        #expect(statusForEvent("SessionEnd") == .exited)
    }

    @Test("urgency puts the states in the order that is needed")
    func urgency() {
        let sorted = [AgentStatus.idle, .waiting, .exited, .working, .done]
            .sorted { $0.urgency < $1.urgency }

        #expect(sorted == [.waiting, .working, .done, .idle, .exited])
    }

    @Test("notifications that are not about being busy leave the status alone")
    func ignored() {
        // nil matters here: any value instead of it would override the agent's
        // real status with an unrelated event.
        #expect(statusForEvent("Notification", notification: "auth_success") == nil)
        #expect(statusForEvent("Notification") == nil)
        #expect(statusForEvent("PreCompact") == nil)
        #expect(statusForEvent("") == nil)
    }
}

@Suite("hook receiver")
struct AgentHooksTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-hooks-\(UUID().uuidString)")
    }

    @Test("an event from the loopback reaches the stream")
    func receivesEvent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hooks = try await AgentHooks.start(directory: directory)
        defer { hooks.stop() }

        var events = hooks.events.makeAsyncIterator()

        var components = try #require(URLComponents(string: hooks.config.hookURL))
        components.queryItems = [
            URLQueryItem(name: "pane", value: "pane-42"),
            URLQueryItem(name: "event", value: "Notification"),
            URLQueryItem(name: "notification", value: "permission_prompt"),
            URLQueryItem(name: "message", value: "Run rm -rf build?"),
            URLQueryItem(name: "session", value: "3f2b1c40-0000-4000-8000-000000000001"),
            URLQueryItem(name: "transcript", value: "/tmp/session.jsonl"),
        ]
        _ = try await URLSession.shared.data(from: try #require(components.url))

        let event = await events.next()

        #expect(event?.paneID == "pane-42")
        #expect(event?.status == .waiting)
        // The attention queue needs the text of the question: it gets answered
        // without opening the pane itself.
        #expect(event?.message == "Run rm -rf build?")

        // The Claude Code session is recognised from the very first event: its
        // id opens both the transcript and the continuation through `--resume`.
        #expect(event?.sessionID == "3f2b1c40-0000-4000-8000-000000000001")
        #expect(event?.transcriptPath == "/tmp/session.jsonl")
    }

    @Test("form spaces do not reach the card as pluses")
    func decodesFormEncoding() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hooks = try await AgentHooks.start(directory: directory)
        defer { hooks.stop() }

        var events = hooks.events.makeAsyncIterator()

        // Exactly the string that leaves curl: `--data-urlencode` encodes a
        // form, not a URL.
        let url = try #require(URL(string: hooks.config.hookURL
            + "?pane=p&event=Notification&notification=permission_prompt"
            + "&message=Claude+needs+your+permission+for+C%2B%2B"))
        _ = try await URLSession.shared.data(from: url)

        let event = await events.next()
        #expect(event?.message == "Claude needs your permission for C++")
    }

    @Test("an event without a status never reaches the stream")
    func ignoresUnknownEvent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hooks = try await AgentHooks.start(directory: directory)
        defer { hooks.stop() }

        var events = hooks.events.makeAsyncIterator()

        func send(event: String) async throws {
            var components = try #require(URLComponents(string: hooks.config.hookURL))
            components.queryItems = [
                URLQueryItem(name: "pane", value: "pane-42"),
                URLQueryItem(name: "event", value: event),
            ]
            _ = try await URLSession.shared.data(from: try #require(components.url))
        }

        // PreCompact has no status and must be swallowed silently — otherwise
        // it is exactly what would come out of the stream first.
        try await send(event: "PreCompact")
        try await send(event: "Stop")

        #expect(await events.next()?.status == .done)
    }

    @Test("the hook files land next to the snapshot")
    func writesHookFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hooks = try await AgentHooks.start(directory: directory)
        defer { hooks.stop() }

        let settings = try #require(
            JSONSerialization.jsonObject(
                with: try Data(contentsOf: URL(fileURLWithPath: hooks.config.settingsPath))
            ) as? [String: Any]
        )
        let registered = try #require(settings["hooks"] as? [String: Any])

        #expect(registered["Stop"] != nil)
        #expect(registered["PermissionRequest"] != nil)

        let script = directory.appendingPathComponent("hooks/notify.sh")
        let text = try String(contentsOf: script, encoding: .utf8)

        #expect(text.contains("ROOST_HOOK_URL"))
        #expect(text.contains("ROOST_PANE_ID"))
    }
}

@Suite("pane launch")
struct PaneLaunchTests {
    /// A session catalog that does not exist: this is what the disk looks like
    /// for a pane whose session has never been started. A test must not ask the
    /// home directory — the answer would depend on what the human did
    /// yesterday.
    private var emptyRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-no-sessions-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("a shell comes up login-interactive")
    func shellPane() {
        let launch = PaneLaunch(pane: PaneSpec(title: "shell", cwd: "/tmp"))

        #expect(launch.arguments == ["-l", "-i"])
        #expect(launch.workingDirectory == "/tmp")
    }

    @Test("claude goes inside a login-interactive shell together with its settings")
    func claudePane() throws {
        let config = AgentHooksConfig(
            hookURL: "http://127.0.0.1:1234/hook",
            settingsPath: "/tmp/with a space/claude-settings.json"
        )
        let launch = PaneLaunch(
            pane: PaneSpec(id: "pane-1", title: "claude", cwd: "/tmp", kind: .claude),
            hooks: config,
            sessions: emptyRoot
        )

        let command = try #require(launch.arguments.last)

        // -i is mandatory: PATH is edited in .zshrc, which a non-interactive
        // login shell does not read.
        #expect(launch.arguments.dropLast() == ["-l", "-i", "-c"])
        #expect(command.hasPrefix("exec claude "))
        // A path with a space has to travel in quotes, or the shell would cut
        // it in half.
        #expect(command.contains("'/tmp/with a space/claude-settings.json'"))

        #expect(launch.environment.contains("ROOST_PANE_ID=pane-1"))
        #expect(launch.environment.contains("ROOST_HOOK_URL=http://127.0.0.1:1234/hook"))

        // A session that outlives the PTY becomes a background agent, and
        // `--resume` does not attach to such a session at all — the pane would
        // greet the human with a red line instead of an agent.
        #expect(
            launch.environment.contains { $0.hasPrefix("CLAUDE_CODE_FORCE_SESSION_PERSISTENCE") }
                == false
        )
    }

    @Test("the pane calls itself a terminal Claude Code grants Shift+Enter to")
    func announcesKittyCapableTerminal() {
        let launch = PaneLaunch(pane: PaneSpec(title: "claude", cwd: "/tmp", kind: .claude))

        // Claude Code turns the extended keyboard protocol on by an allow-list
        // of names rather than by the terminal's capabilities. Without our name
        // on it, Shift+Enter arrives as a plain Enter — and sends the message
        // instead of breaking the line.
        #expect(launch.environment.contains("TERM_PROGRAM=ghostty"))
    }

    @Test("a cwd that does not exist does not stand in the way of launching")
    func missingCwd() {
        let launch = PaneLaunch(pane: PaneSpec(title: "shell", cwd: "/no/such/directory"))

        #expect(launch.workingDirectory == ProcessInfo.processInfo.environment["HOME"])
    }

    @Test("a claude pane names its session itself, before it even starts")
    func assignsSessionID() throws {
        // Waiting for an id from a hook means risking the session: a closed tab
        // and a broken hook setup both fit between the launch and the first
        // event.
        let pane = PaneSpec(title: "claude", cwd: "/tmp", kind: .claude)
        let id = try #require(pane.agentSessionID)

        #expect(UUID(uuidString: id) != nil)
        #expect(id == id.lowercased())

        // Only the agent has sessions, and inventing one for a console would be
        // pointless.
        #expect(PaneSpec(title: "shell", cwd: "/tmp").agentSessionID == nil)
    }

    @Test("a new claude pane starts from a blank slate under its own name")
    func freshSession() throws {
        let pane = PaneSpec(title: "claude", cwd: "/tmp", kind: .claude)
        let launch = PaneLaunch(pane: pane, sessions: emptyRoot)

        let command = try #require(launch.arguments.last)
        #expect(command.contains("--session-id '\(try #require(pane.agentSessionID))'"))
        #expect(command.contains("--resume") == false)
    }

    @Test("a started session is continued even if the hook said nothing about it")
    func resumesTranscriptFoundOnDisk() throws {
        // The transcript's path is brought by a hook, and the hook may never
        // arrive. Trusting an empty field, the pane would name an id that is
        // already taken — and claude would not start at all: "Session ID … is
        // already in use".
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-sessions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "f43586fa-cd99-40c1-af2f-3f52c85cc6f6"
        let directory = root.appendingPathComponent(
            SessionCatalog.directoryNames(for: "/tmp")[0],
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: directory.appendingPathComponent("\(id).jsonl"))

        let launch = PaneLaunch(
            pane: PaneSpec(title: "claude", cwd: "/tmp", kind: .claude, agentSessionID: id),
            sessions: root
        )

        let command = try #require(launch.arguments.last)
        #expect(command.contains("--resume '\(id)'"))
        #expect(command.contains("--session-id") == false)
    }

    @Test("a pane from a snapshot returns to its session")
    func resumesKnownSession() throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let launch = PaneLaunch(
            pane: PaneSpec(
                title: "claude",
                cwd: "/tmp",
                kind: .claude,
                agentSessionID: "f43586fa-cd99-40c1-af2f-3f52c85cc6f6",
                transcriptPath: transcript.path
            )
        )

        let command = try #require(launch.arguments.last)
        #expect(command.contains("--resume 'f43586fa-cd99-40c1-af2f-3f52c85cc6f6'"))

        // Continuing may not work out — then the pane opens a clean session
        // rather than staying dead with an error message.
        #expect(command.contains("|| { [ $SECONDS -lt 5 ] && exec claude"))
    }

    @Test("a vanished transcript cancels the continuation")
    func skipsMissingTranscript() throws {
        // Without this check claude would break off with an error, and instead
        // of an agent the human would get a dead pane.
        let launch = PaneLaunch(
            pane: PaneSpec(
                title: "claude",
                cwd: "/tmp",
                kind: .claude,
                agentSessionID: "f43586fa-cd99-40c1-af2f-3f52c85cc6f6",
                transcriptPath: "/tmp/no-such-transcript.jsonl"
            ),
            sessions: emptyRoot
        )

        let command = try #require(launch.arguments.last)
        #expect(command.contains("--resume") == false)

        // The id stays the same: with no transcript it is free, and the pane
        // keeps its name instead of making up a new one.
        #expect(command.contains("--session-id 'f43586fa-cd99-40c1-af2f-3f52c85cc6f6'"))
    }

    @Test("a forged id never reaches the command")
    func rejectsMalformedSessionID() throws {
        // The snapshot is ordinary json next to the home directory, and the id
        // travels into a shell string inside single quotes.
        let launch = PaneLaunch(
            pane: PaneSpec(
                title: "claude",
                cwd: "/tmp",
                kind: .claude,
                agentSessionID: "'; rm -rf /; echo '"
            ),
            sessions: emptyRoot
        )

        let command = try #require(launch.arguments.last)
        #expect(command == "exec claude")
    }

    @Test("a shell pane knows nothing about agent sessions")
    func shellIgnoresSession() {
        let launch = PaneLaunch(
            pane: PaneSpec(
                title: "shell",
                cwd: "/tmp",
                kind: .shell,
                agentSessionID: "f43586fa-cd99-40c1-af2f-3f52c85cc6f6"
            )
        )

        #expect(launch.arguments == ["-l", "-i"])
    }
}
