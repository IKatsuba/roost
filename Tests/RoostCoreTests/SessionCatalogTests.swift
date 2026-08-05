import Foundation
import Testing

@testable import RoostCore

@Suite("session catalog")
struct SessionCatalogTests {
    /// Claude Code's whole catalog, but in a temporary directory: the real one
    /// must not be touched, while the shape of the records is taken from it.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(
        session: String,
        in directory: String,
        under root: URL,
        lines: [String],
        modified: Date = Date()
    ) throws -> URL {
        let folder = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let file = folder.appendingPathComponent("\(session).jsonl")
        try Data(lines.joined(separator: "\n").appending("\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        return file
    }

    private func prompt(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func aiTitle(_ text: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(text)"}"#
    }

    // MARK: - Directory name

    @Test("a dot in the path gives two directory names: today's and the former one")
    func directoryNamesForDottedPath() {
        let names = SessionCatalog.directoryNames(for: "/Users/me/projects/katsuba.live")

        #expect(names == [
            "-Users-me-projects-katsuba-live",
            "-Users-me-projects-katsuba.live",
        ])
    }

    @Test("a path without dots is encoded in a single way")
    func directoryNamesForPlainPath() {
        #expect(
            SessionCatalog.directoryNames(for: "/Users/me/roost") == ["-Users-me-roost"]
        )
    }

    @Test("the project's directory is the one found on disk")
    func directoryPrefersExisting() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cwd = "/Users/me/projects/katsuba.live"
        try write(session: UUID().uuidString, in: "-Users-me-projects-katsuba.live", under: root, lines: [])

        #expect(
            SessionCatalog.directory(for: cwd, root: root).lastPathComponent
                == "-Users-me-projects-katsuba.live"
        )
    }

    // MARK: - Listing

    @Test("a project's sessions come freshest first")
    func sessionsSortedByAge() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = "-Users-me-roost"
        try write(
            session: "11111111-1111-1111-1111-111111111111",
            in: directory,
            under: root,
            lines: [prompt("the old one")],
            modified: Date(timeIntervalSince1970: 1_000)
        )
        try write(
            session: "22222222-2222-2222-2222-222222222222",
            in: directory,
            under: root,
            lines: [prompt("the fresh one")],
            modified: Date(timeIntervalSince1970: 2_000)
        )

        let sessions = SessionCatalog.sessions(for: "/Users/me/roost", root: root)

        #expect(sessions.map(\.title) == ["the fresh one", "the old one"])
    }

    @Test("a session's name outranks its first message")
    func titleWinsOverPrompt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(
            session: "33333333-3333-3333-3333-333333333333",
            in: "-Users-me-roost",
            under: root,
            lines: [prompt("fix the build"), aiTitle("Fixing the build")]
        )

        let sessions = SessionCatalog.sessions(for: "/Users/me/roost", root: root)

        #expect(sessions.first?.title == "Fixing the build")
    }

    @Test("a nameless session is called by the head of its uuid")
    func labelFallsBackToID() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(
            session: "44444444-4444-4444-4444-444444444444",
            in: "-Users-me-roost",
            under: root,
            lines: [#"{"type":"system","subtype":"init"}"#]
        )

        let sessions = SessionCatalog.sessions(for: "/Users/me/roost", root: root)

        #expect(sessions.first?.label == "session 44444444")
    }

    @Test("one session under two path encodings is not counted twice")
    func deduplicatesAcrossEncodings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = "55555555-5555-5555-5555-555555555555"
        try write(session: session, in: "-Users-me-katsuba-live", under: root, lines: [prompt("one")])
        try write(session: session, in: "-Users-me-katsuba.live", under: root, lines: [prompt("one")])

        #expect(SessionCatalog.sessions(for: "/Users/me/katsuba.live", root: root).count == 1)
    }

    @Test("sessions from a project's branches share one list and remember their branch")
    func sessionsIncludeWorktrees() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The project has to be a real one: branch names are read from disk
        // rather than from the transcript's path — the original directory
        // cannot be recovered from it.
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("\(Worktree.container)/fix-login"),
            withIntermediateDirectories: true
        )

        try write(
            session: "99999999-9999-9999-9999-999999999999",
            in: SessionCatalog.directoryNames(for: project.path)[0],
            under: root,
            lines: [prompt("in the project")],
            modified: Date(timeIntervalSince1970: 1_000)
        )
        try write(
            session: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            in: SessionCatalog.directoryNames(
                for: Worktree.path(inside: project.path, name: "fix-login")
            )[0],
            under: root,
            lines: [prompt("in the branch")],
            modified: Date(timeIntervalSince1970: 2_000)
        )

        let sessions = SessionCatalog.sessions(forProject: project.path, root: root)

        #expect(sessions.map(\.title) == ["in the branch", "in the project"])
        #expect(sessions.map(\.worktree) == ["fix-login", nil])

        // The project itself still answers for its own directory only: the list
        // of branches is a separate request, not a side effect.
        #expect(SessionCatalog.sessions(for: project.path, root: root).count == 1)
    }

    // MARK: - Lookup by id

    @Test("a session of one's own project is continued on the spot")
    func resolvesHere() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = "66666666-6666-6666-6666-666666666666"
        try write(session: session, in: "-Users-me-roost", under: root, lines: [prompt("hello")])

        guard case .here(let record) = SessionCatalog.resolve(
            session,
            project: "/Users/me/roost",
            root: root
        ) else {
            Issue.record("the session should have been found under its own project")
            return
        }

        #expect(record.id == session)
        #expect(record.title == "hello")
    }

    @Test("a session of another project is recognised as somebody else's")
    func resolvesElsewhere() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = "77777777-7777-7777-7777-777777777777"
        let file = try write(session: session, in: "-Users-me-other", under: root, lines: [prompt("not here")])

        // The paths are compared resolved: walking the directory unwraps the
        // symlink of the temporary folder (`/var` → `/private/var`), and that
        // is about the fixture rather than about the lookup.
        guard case .elsewhere(let found) = SessionCatalog.resolve(
            session,
            project: "/Users/me/roost",
            root: root
        ) else {
            Issue.record("the session should have been found under another project")
            return
        }

        #expect(
            URL(fileURLWithPath: found).resolvingSymlinksInPath()
                == file.resolvingSymlinksInPath()
        )
    }

    @Test("a session that is nowhere names the directory to put it into")
    func resolvesMissing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            SessionCatalog.resolve(
                "88888888-8888-8888-8888-888888888888",
                project: "/Users/me/roost",
                root: root
            ) == .missing(root.appendingPathComponent("-Users-me-roost").path)
        )
    }

    // MARK: - Age

    @Test("age is written in English and without fractions")
    func age() {
        #expect(relativeAge(5) == "just now")
        #expect(relativeAge(20 * 60) == "20m ago")
        #expect(relativeAge(3 * 3600 + 59 * 60) == "3h ago")
        #expect(relativeAge(3 * 86_400) == "3d ago")
    }
}
