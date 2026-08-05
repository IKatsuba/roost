import Foundation

/// How the halves of a split are laid out.
public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Panes side by side: left and right.
    case row

    /// Panes stacked one under the other.
    case column
}

/// Where focus goes when moving between panes.
public enum PaneDirection: Hashable, Sendable {
    case left, right, up, down

    public var axis: SplitAxis {
        switch self {
        case .left, .right: .row
        case .up, .down: .column
        }
    }

    /// Movement towards the second half of a split rather than the first.
    public var isForward: Bool { self == .right || self == .down }
}

/// A tab's layout: either a single pane or a split of two nodes.
///
/// It is a value type, so the "immutable tree" comes for free: every operation
/// returns a new one, and nobody can spoil somebody else's layout behind their
/// back.
public indirect enum PaneNode: Hashable, Sendable {
    case leaf(PaneSpec)
    case split(Split)

    public struct Split: Hashable, Sendable {
        public let id: String
        public var axis: SplitAxis
        public var first: PaneNode
        public var second: PaneNode

        /// The share taken by `first`. Clamped, so that a pane cannot be
        /// dragged down to nothing and lost from sight.
        public var ratio: Double

        public static let minRatio = 0.1
        public static let maxRatio = 0.9

        public init(
            id: String = UUID().uuidString,
            axis: SplitAxis,
            first: PaneNode,
            second: PaneNode,
            ratio: Double = 0.5
        ) {
            self.id = id
            self.axis = axis
            self.first = first
            self.second = second
            self.ratio = min(max(ratio, Self.minRatio), Self.maxRatio)
        }
    }

    // MARK: - Reading

    /// Every pane of the tree, left to right, top to bottom.
    public var panes: [PaneSpec] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    public func pane(_ id: String) -> PaneSpec? {
        panes.first { $0.id == id }
    }

    public func contains(_ id: String) -> Bool {
        pane(id) != nil
    }

    // MARK: - Changes

    /// Replaces a pane with a new subtree — this is how a split is made.
    public func replacing(_ id: String, with replacement: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? replacement : self

        case .split(var split):
            split.first = split.first.replacing(id, with: replacement)
            split.second = split.second.replacing(id, with: replacement)
            return .split(split)
        }
    }

    /// Updates a pane's description, leaving the structure untouched.
    public func updating(_ id: String, _ transform: (PaneSpec) -> PaneSpec) -> PaneNode {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? .leaf(transform(pane)) : self

        case .split(var split):
            split.first = split.first.updating(id, transform)
            split.second = split.second.updating(id, transform)
            return .split(split)
        }
    }

    /// Removes a pane, collapsing the split into the sibling that stays.
    /// `nil` — the pane was the last one and the tree is now empty.
    public func removing(_ id: String) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? nil : self

        case .split(var split):
            if split.first.contains(id) {
                guard let rest = split.first.removing(id) else { return split.second }
                split.first = rest
                return .split(split)
            }
            if split.second.contains(id) {
                guard let rest = split.second.removing(id) else { return split.first }
                split.second = rest
                return .split(split)
            }
            return self
        }
    }

    /// Changes the proportion of one particular split.
    public func settingRatio(_ splitID: String, to ratio: Double) -> PaneNode {
        guard case .split(var split) = self else { return self }

        if split.id == splitID {
            split.ratio = min(max(ratio, Split.minRatio), Split.maxRatio)
            return .split(split)
        }

        split.first = split.first.settingRatio(splitID, to: ratio)
        split.second = split.second.settingRatio(splitID, to: ratio)
        return .split(split)
    }

    // MARK: - Navigation

    /// The neighbouring pane in a given direction — `nil` if there is none.
    ///
    /// We climb from the leaf up to the nearest split on the right axis whose
    /// sibling lies the way we are going, then descend into it, always picking
    /// the half closest to us. That way `⌘⇧→` from the left pane lands in the
    /// one that really borders it on the right, not in the first leaf around.
    public func neighbour(of paneID: String, to direction: PaneDirection) -> String? {
        guard let path = Self.path(from: self, to: paneID) else { return nil }

        for step in path.reversed() {
            guard step.split.axis == direction.axis else { continue }
            guard step.tookFirst == direction.isForward else { continue }

            let subtree = direction.isForward ? step.split.second : step.split.first
            return Self.nearestLeaf(in: subtree, enteredFrom: direction).id
        }
        return nil
    }

    private struct Step {
        let split: Split
        let tookFirst: Bool
    }

    private static func path(from node: PaneNode, to paneID: String) -> [Step]? {
        switch node {
        case .leaf(let pane):
            return pane.id == paneID ? [] : nil

        case .split(let split):
            if let inFirst = path(from: split.first, to: paneID) {
                return [Step(split: split, tookFirst: true)] + inFirst
            }
            if let inSecond = path(from: split.second, to: paneID) {
                return [Step(split: split, tookFirst: false)] + inSecond
            }
            return nil
        }
    }

    /// The nearest leaf of a subtree, seen from the side we enter it.
    private static func nearestLeaf(in node: PaneNode, enteredFrom direction: PaneDirection) -> PaneSpec {
        var current = node
        while case .split(let split) = current {
            current = split.axis == direction.axis
                // Entering from the left means the left half is closer, and
                // the other way round.
                ? (direction.isForward ? split.first : split.second)
                : split.first
        }
        guard case .leaf(let pane) = current else {
            preconditionFailure("the loop ended somewhere other than a leaf")
        }
        return pane
    }
}

// MARK: - Codable

/// The tree is written by hand rather than in the format synthesised for enums:
/// the snapshot has to stay readable and must not drift when a case is renamed.
extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, pane, id, axis, ratio, first, second
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if try container.decode(String.self, forKey: .type) == "split" {
            self = .split(
                Split(
                    id: try container.decode(String.self, forKey: .id),
                    axis: try container.decode(SplitAxis.self, forKey: .axis),
                    first: try container.decode(PaneNode.self, forKey: .first),
                    second: try container.decode(PaneNode.self, forKey: .second),
                    ratio: try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
                )
            )
        } else {
            self = .leaf(try container.decode(PaneSpec.self, forKey: .pane))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .leaf(let pane):
            try container.encode("leaf", forKey: .type)
            try container.encode(pane, forKey: .pane)

        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split.id, forKey: .id)
            try container.encode(split.axis, forKey: .axis)
            try container.encode(split.ratio, forKey: .ratio)
            try container.encode(split.first, forKey: .first)
            try container.encode(split.second, forKey: .second)
        }
    }
}
