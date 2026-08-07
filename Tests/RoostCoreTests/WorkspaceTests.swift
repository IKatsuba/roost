import Foundation
import Testing

@testable import RoostCore

@Suite("workspace snapshot")
struct WorkspaceSnapshotTests {
    @Test("a nested layout survives a JSON round-trip")
    func nestedLayoutRoundTrip() throws {
        let tab = TabSpec(
            id: "t1",
            layout: .split(
                .init(
                    id: "s1",
                    axis: .row,
                    first: .leaf(PaneSpec(id: "a", title: "a", cwd: "/tmp")),
                    second: .split(
                        .init(
                            id: "s2",
                            axis: .column,
                            first: .leaf(PaneSpec(id: "b", title: "b", cwd: "/tmp")),
                            second: .leaf(
                                PaneSpec(id: "c", title: "claude", cwd: "/tmp", kind: .claude)
                            ),
                            ratio: 0.3
                        )
                    )
                )
            ),
            activePaneID: "c"
        )

        let restored = try JSONDecoder().decode(
            TabSpec.self,
            from: JSONEncoder().encode(tab)
        )

        #expect(restored.panes.map(\.id) == ["a", "b", "c"])
        #expect(restored.activePaneID == "c")
        #expect(restored.activePane.kind == .claude)

        guard case .split(let root) = restored.layout,
              case .split(let nested) = root.second
        else {
            Issue.record("the split structure did not survive")
            return
        }
        #expect(root.axis == .row)
        #expect(nested.axis == .column)
        #expect(nested.ratio == 0.3)
    }

    @Test("a snapshot reads back exactly as it was written")
    func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WorkspaceStore(directory: directory)
        let project = Project(path: "/tmp/roost")
        let tab = TabSpec(pane: PaneSpec(title: "claude", cwd: "/tmp/roost", kind: .claude))

        try store.save(
            WorkspaceSnapshot(
                projects: [project],
                tabs: [project.id: [tab]],
                activeProjectID: project.id,
                activeTabIDs: [project.id: tab.id]
            )
        )

        let restored = store.load()

        #expect(restored.projects.first?.name == "roost")
        #expect(restored.tabs[project.id]?.first?.title == "claude")
        #expect(restored.activeProjectID == project.id)
    }

    @Test("hidden side columns survive a round-trip")
    func hiddenColumnsRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = WorkspaceStore(directory: directory)
        try store.save(WorkspaceSnapshot(sidebarHidden: true, sidePanelHidden: true))

        let restored = store.load()

        #expect(restored.sidebarHidden)
        #expect(restored.sidePanelHidden)
    }

    @Test("a snapshot from before the hidden-columns flags still decodes")
    func decodesSnapshotWithoutVisibilityKeys() throws {
        // Missing keys must fall back, not throw: `load()` answers any throw
        // with a clean state, which would wipe the workspace over a boolean.
        let old = """
            {"version":1,"projects":[],"tabs":{},"activeTabIDs":{}}
            """
        let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(old.utf8))

        #expect(!restored.sidebarHidden)
        #expect(!restored.sidePanelHidden)
    }

    @Test("a missing snapshot gives an empty state rather than a crash")
    func missingSnapshot() {
        let store = WorkspaceStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("roost-no-such-\(UUID().uuidString)")
        )

        #expect(store.load().projects.isEmpty)
    }

    @Test("a broken snapshot does not stand in the way of launching")
    func brokenSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("roost-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkspaceStore(directory: directory)
        try Data("{ this is not json".utf8).write(to: store.file)

        #expect(store.load().projects.isEmpty)
    }

    @Test("the project's name comes from the path, the trailing slash is cut")
    func projectFromPath() {
        let project = Project(path: "/Users/me/projects/foo/")

        #expect(project.name == "foo")
        #expect(project.path == "/Users/me/projects/foo")
    }

    @Test("a project is called what the human wanted, an empty name returns the path")
    func renamesProject() {
        var project = Project(path: "/Users/me/projects/foo")

        project.rename(to: "  storefront  ")
        #expect(project.name == "storefront")
        // The path is left alone: the name is only a label in the sidebar.
        #expect(project.path == "/Users/me/projects/foo")

        project.rename(to: "   ")
        #expect(project.name == "foo")
    }

    @Test("the second copy of a folder gets a number, a free name stays as it is")
    func numbersRepeatedNames() {
        #expect(Project.uniqueName("foo", among: ["bar"]) == "foo")
        #expect(Project.uniqueName("foo", among: ["foo"]) == "foo 2")
        #expect(Project.uniqueName("foo", among: ["foo", "foo 2"]) == "foo 3")
        // A taken number is jumped over rather than appended after: "foo 3" is
        // already somebody's name, even if a human made it up.
        #expect(Project.uniqueName("foo", among: ["foo", "foo 3"]) == "foo 2")
    }
}
