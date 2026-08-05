import Testing

@testable import RoostCore

private func pane(_ id: String) -> PaneSpec {
    PaneSpec(id: id, title: id, cwd: "/tmp")
}

/// The layout navigation is checked against:
///
///     ┌───────┬───────┐
///     │       │   b   │
///     │   a   ├───────┤
///     │       │   c   │
///     └───────┴───────┘
private func twoColumns() -> PaneNode {
    .split(
        .init(
            id: "s1",
            axis: .row,
            first: .leaf(pane("a")),
            second: .split(
                .init(id: "s2", axis: .column, first: .leaf(pane("b")), second: .leaf(pane("c")))
            )
        )
    )
}

@Suite("pane tree")
struct PaneTreeTests {
    @Test("replacing a pane turns a leaf into a split")
    func replaceMakesSplit() {
        let layout = PaneNode.leaf(pane("a")).replacing(
            "a",
            with: .split(.init(axis: .row, first: .leaf(pane("a")), second: .leaf(pane("b"))))
        )

        #expect(layout.panes.map(\.id) == ["a", "b"])
    }

    @Test("removing a pane collapses the split into its sibling")
    func removeCollapses() throws {
        let layout = try #require(twoColumns().removing("b"))

        #expect(layout.panes.map(\.id) == ["a", "c"])

        // The inner split disappeared with the pane instead of staying as an
        // empty node.
        guard case .split(let split) = layout else {
            Issue.record("the root stopped being a split")
            return
        }
        guard case .leaf = split.second else {
            Issue.record("the sibling did not collapse into a leaf")
            return
        }
    }

    @Test("removing the last pane empties the tree")
    func removeLast() {
        #expect(PaneNode.leaf(pane("a")).removing("a") == nil)
    }

    @Test("removing somebody else's pane breaks nothing")
    func removeUnknown() {
        #expect(twoColumns().removing("no such pane")?.panes.count == 3)
    }

    @Test("an update touches only the named pane")
    func updateOne() {
        let layout = twoColumns().updating("b") { pane in
            var copy = pane
            copy.title = "claude"
            return copy
        }

        #expect(layout.pane("b")?.title == "claude")
        #expect(layout.pane("a")?.title == "a")
    }

    @Test("a split's ratio does not let a pane be dragged down to zero")
    func ratioClamped() {
        guard case .split(let split) = twoColumns().settingRatio("s1", to: 0.001) else {
            Issue.record("the root stopped being a split")
            return
        }
        #expect(split.ratio == PaneNode.Split.minRatio)
    }
}

@Suite("moving between panes")
struct NeighbourTests {
    @Test("going right from the left column lands in the upper right one")
    func right() {
        #expect(twoColumns().neighbour(of: "a", to: .right) == "b")
    }

    @Test("going left from any right-hand pane returns to the left column")
    func left() {
        #expect(twoColumns().neighbour(of: "b", to: .left) == "a")
        #expect(twoColumns().neighbour(of: "c", to: .left) == "a")
    }

    @Test("down and up move within their own column")
    func vertical() {
        #expect(twoColumns().neighbour(of: "b", to: .down) == "c")
        #expect(twoColumns().neighbour(of: "c", to: .up) == "b")
    }

    @Test("beyond the layout's edge there is no neighbour")
    func edges() {
        #expect(twoColumns().neighbour(of: "a", to: .left) == nil)
        #expect(twoColumns().neighbour(of: "a", to: .up) == nil)
        #expect(twoColumns().neighbour(of: "c", to: .down) == nil)
        #expect(twoColumns().neighbour(of: "b", to: .right) == nil)
    }

    @Test("panes outside the tree have no neighbours")
    func unknown() {
        #expect(twoColumns().neighbour(of: "nope", to: .right) == nil)
    }
}

@Suite("tab")
struct TabSpecTests {
    @Test("the title comes from the active pane")
    func title() {
        let tab = TabSpec(id: "t1", layout: twoColumns(), activePaneID: "c")

        #expect(tab.title == "c")
        #expect(tab.paneCount == 3)
    }

    @Test("after the active pane is closed the focus does not hang in the void")
    func focusSurvivesClose() throws {
        var tab = TabSpec(id: "t1", layout: twoColumns(), activePaneID: "b")
        tab.setLayout(try #require(tab.layout.removing("b")))

        #expect(tab.activePaneID == "a")
    }

    @Test("a broken activePaneID from a snapshot is fixed on reading")
    func brokenActiveID() {
        let tab = TabSpec(id: "t1", layout: twoColumns(), activePaneID: "vanished")

        #expect(tab.activePaneID == "a")
    }
}
