import CoreGraphics
import Testing

@testable import RoostCore

/// Three rows of equal height, one under the other — the project sidebar:
///
///     a  y 0…34
///     b  y 34…68
///     c  y 68…102
private let column: [String: CGRect] = [
    "a": CGRect(x: 0, y: 0, width: 200, height: 34),
    "b": CGRect(x: 0, y: 34, width: 200, height: 34),
    "c": CGRect(x: 0, y: 68, width: 200, height: 34),
]

/// Tabs of three different widths, side by side — the strip is not a grid, and
/// the arithmetic must not assume it is:
///
///     a  x 0…60    b  x 60…160    c  x 160…200
private let strip: [String: CGRect] = [
    "a": CGRect(x: 0, y: 0, width: 60, height: 30),
    "b": CGRect(x: 60, y: 0, width: 100, height: 30),
    "c": CGRect(x: 160, y: 0, width: 40, height: 30),
]

private func drag(
    _ id: String,
    _ axis: ReorderDrag.Axis,
    _ frames: [String: CGRect],
    by translation: CGFloat
) -> ReorderDrag {
    var drag = ReorderDrag(id: id, axis: axis, frames: frames)!
    drag.translation = translation
    return drag
}

@Suite("reorder drag")
struct ReorderDragTests {
    @Test("an item held still stays in its own slot")
    func restingItemKeepsItsPlace() {
        for id in ["a", "b", "c"] {
            let held = drag(id, .vertical, column, by: 0)
            #expect(held.targetIndex == ["a": 0, "b": 1, "c": 2][id])
            #expect(held.currentShifts().isEmpty)
        }
    }

    @Test("crossing a neighbour by more than half its height takes its slot")
    func crossingNeighbourTakesItsSlot() {
        #expect(drag("a", .vertical, column, by: 16).targetIndex == 0)
        #expect(drag("a", .vertical, column, by: 18).targetIndex == 1)
        #expect(drag("a", .vertical, column, by: 52).targetIndex == 2)
    }

    @Test("the neighbours being passed step aside, the rest stand still")
    func passedNeighboursStepAside() {
        // Down over b: b comes up by a row, c has no reason to move.
        #expect(drag("a", .vertical, column, by: 40).currentShifts() == ["b": -34])

        // Up over both: they go down, each by the carried row's height.
        #expect(drag("c", .vertical, column, by: -68).currentShifts() == ["a": 34, "b": 34])
    }

    @Test("an item cannot be carried out of its container")
    func travelIsClamped() {
        // Far past the bottom edge and far past the top one: the last slot and
        // the first, not something beyond the ends.
        #expect(drag("a", .vertical, column, by: 4000).targetIndex == 2)
        #expect(drag("c", .vertical, column, by: -4000).targetIndex == 0)
        #expect(drag("a", .vertical, column, by: 4000).translation == 68)
        #expect(drag("c", .vertical, column, by: -4000).translation == -68)
    }

    @Test("the edge slots are reachable although the clamp stops short")
    func edgeSlotsAreReachable() {
        // The whole reason for slots rather than centre-against-centre: held
        // against the wall, a's centre is 13 short of c's, and a comparison of
        // centres would never let it into the last slot.
        let held = drag("a", .horizontal, strip, by: 4000)
        #expect(held.translation == 140)
        #expect(held.targetIndex == 2)
    }

    @Test("widths differ, so the slots do too")
    func slotsFollowNeighbourWidths() {
        // Slot 1 is the gap after b, its centre at 100 + 30; a's centre starts
        // at 30, so it takes 100 points of travel — b's width, not a's.
        #expect(drag("a", .horizontal, strip, by: 49).targetIndex == 0)
        #expect(drag("a", .horizontal, strip, by: 51).targetIndex == 1)
    }

    @Test("an item that is not in the snapshot has no drag")
    func unknownItemHasNoDrag() {
        #expect(ReorderDrag(id: "d", axis: .vertical, frames: column) == nil)
    }
}
