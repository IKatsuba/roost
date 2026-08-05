import Foundation
import Testing

@testable import RoostCore

@Suite("worktree")
struct WorktreeTests {
    /// A project on disk: worktree names are read from a directory, not made up.
    private func makeProject(worktrees: [String] = []) throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-project-\(UUID().uuidString)", isDirectory: true)

        for name in worktrees {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent("\(Worktree.container)/\(name)"),
                withIntermediateDirectories: true
            )
        }
        if worktrees.isEmpty {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }

        return project
    }

    // MARK: - Name

    @Test("a branch name is cleaned up until both git and the shell accept it")
    func sanitizesName() {
        #expect(Worktree.sanitize("fix-login") == "fix-login")
        #expect(Worktree.sanitize("Fix Login (2)") == "Fix-Login-2")
        #expect(Worktree.sanitize("  fix   login  ") == "fix-login")
        #expect(Worktree.sanitize("release/2.0") == "release-2.0")
    }

    @Test("a quote cannot escape out of a name")
    func quoteCannotEscape() throws {
        // The name travels into the pane's command inside single quotes: one
        // quote in the middle would turn the rest of the string into a separate
        // shell command.
        let name = try #require(Worktree.sanitize("a'; rm -rf /; echo '"))

        #expect(!name.contains("'"))
        #expect(!name.contains(";"))
        #expect(!name.contains(" "))
    }

    @Test("a name without a single usable character does not become a name")
    func rejectsEmptyName() {
        #expect(Worktree.sanitize("") == nil)
        #expect(Worktree.sanitize("///") == nil)
        #expect(Worktree.sanitize("   ") == nil)
    }

    // MARK: - Directory

    @Test("a project's worktrees are read from disk in alphabetical order")
    func listsWorktrees() throws {
        let project = try makeProject(worktrees: ["release", "fix-login"])
        defer { try? FileManager.default.removeItem(at: project) }

        #expect(Worktree.names(inside: project.path) == ["fix-login", "release"])
        #expect(
            Worktree.path(inside: "/Users/me/roost", name: "fix-login")
                == "/Users/me/roost/.claude/worktrees/fix-login"
        )
    }

    @Test("a project without worktrees gives an empty list rather than a crash")
    func emptyProject() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }

        #expect(Worktree.names(inside: project.path).isEmpty)
        #expect(Worktree.isRepository(project.path) == false)
    }

    // MARK: - Launch

    @Test("a pane in a branch starts with the worktree flag")
    func launchesWithFlag() throws {
        let launch = PaneLaunch(
            pane: PaneSpec(title: "fix-login", cwd: "/tmp", kind: .claude, worktree: "fix-login"),
            sessions: FileManager.default.temporaryDirectory
                .appendingPathComponent("roost-no-sessions-\(UUID().uuidString)")
        )

        let command = try #require(launch.arguments.last)
        #expect(command.contains("--worktree 'fix-login'"))

        // The pane stands in the project directory: Claude Code itself takes it
        // into the branch.
        #expect(launch.workingDirectory == "/tmp")
    }

    @Test("a branch's session is looked for in its own directory, not the project's")
    func transcriptLivesInWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-sessions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The pane starts in the project, but the agent keeps the transcript in
        // the branch already: asking about the project's directory would make
        // the session count as unstarted, and the pane would try to name a
        // taken id.
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let directory = root.appendingPathComponent(
            SessionCatalog.directoryNames(
                for: Worktree.path(inside: "/tmp/project", name: "fix-login")
            )[0],
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: directory.appendingPathComponent("\(id).jsonl"))

        let launch = PaneLaunch(
            pane: PaneSpec(
                title: "fix-login",
                cwd: "/tmp/project",
                kind: .claude,
                agentSessionID: id,
                worktree: "fix-login"
            ),
            sessions: root
        )

        #expect(launch.arguments.last?.contains("--resume '\(id)'") == true)
    }

    @Test("continuing a branch's session carries the same flag")
    func resumeKeepsFlag() throws {
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let launch = PaneLaunch(
            pane: PaneSpec(
                title: "fix-login",
                cwd: "/tmp",
                kind: .claude,
                agentSessionID: "f43586fa-cd99-40c1-af2f-3f52c85cc6f6",
                transcriptPath: transcript.path,
                worktree: "fix-login"
            )
        )

        // Without the flag `--resume` would look for the session in the project
        // directory, while it lives in the branch's one.
        let command = try #require(launch.arguments.last)
        #expect(command.contains("--worktree 'fix-login' --resume"))

        // And in the fallback clean session too: it opens in the same branch.
        #expect(command.hasSuffix("exec claude --worktree 'fix-login'; }"))
    }

    @Test("a shell pane knows nothing about branches")
    func shellIgnoresWorktree() {
        let launch = PaneLaunch(
            pane: PaneSpec(title: "shell", cwd: "/tmp", kind: .shell, worktree: "fix-login")
        )

        #expect(launch.arguments == ["-l", "-i"])
    }
}
