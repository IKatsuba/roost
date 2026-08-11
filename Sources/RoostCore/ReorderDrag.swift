import CoreGraphics

/// The arithmetic of a reorder drag over a snapshot of frames taken at its
/// start: the tab strip along the window, the project list down the sidebar.
///
/// Everything is derived from `translation` and static geometry: which slot the
/// carried item is nearest to, which neighbours must step aside for it. Nothing
/// here reads the live layout, so nothing can feed back and oscillate.
///
/// Slots, not centre-against-centre: near the ends the clamp keeps the carried
/// item's centre from ever reaching the edge item's centre, and a comparison of
/// centres leaves the edge slots unreachable. The nearest slot is exact
/// everywhere — at the full stop against the wall it is the wall's.
public struct ReorderDrag: Sendable {
    /// Which way the row of items runs. The arithmetic is the same either way,
    /// only the side of a rect that counts as "along" changes — which is the
    /// whole reason tabs and projects share this type instead of owning two
    /// copies of the same sums.
    public enum Axis: Sendable {
        case horizontal
        case vertical

        func span(_ rect: CGRect) -> (min: CGFloat, size: CGFloat, mid: CGFloat) {
            switch self {
            case .horizontal: (rect.minX, rect.width, rect.midX)
            case .vertical: (rect.minY, rect.height, rect.midY)
            }
        }

        public func along(_ translation: CGSize) -> CGFloat {
            switch self {
            case .horizontal: translation.width
            case .vertical: translation.height
            }
        }
    }

    public let id: String

    private let axis: Axis
    private let ownSize: CGFloat
    private let startCenter: CGFloat
    private let stripMin: CGFloat
    private let travel: ClosedRange<CGFloat>

    /// The rest of the strip in display order, and where the carried item stood
    /// among them.
    private let others: [(id: String, size: CGFloat)]
    private let homeIndex: Int

    public var shifts: [String: CGFloat] = [:]

    public var translation: CGFloat = 0 {
        // Clamped so the item cannot be carried out of the strip: the row is the
        // only place it can go, and the geometry should say so.
        didSet { translation = min(max(translation, travel.lowerBound), travel.upperBound) }
    }

    public init?(id: String, axis: Axis, frames: [String: CGRect]) {
        guard let ownRect = frames[id] else { return nil }
        let own = axis.span(ownRect)
        let strip = axis.span(frames.values.reduce(CGRect.null) { $0.union($1) })
        let sorted = frames.filter { $0.key != id }
            .map { ($0.key, axis.span($0.value)) }
            .sorted { $0.1.mid < $1.1.mid }

        self.id = id
        self.axis = axis
        ownSize = own.size
        startCenter = own.mid
        stripMin = strip.min
        travel = (strip.min - own.min)...(strip.min + strip.size - (own.min + own.size))
        others = sorted.map { ($0.0, $0.1.size) }
        homeIndex = sorted.firstIndex { $0.1.mid > own.mid } ?? sorted.count
    }

    /// The slot whose centre is nearest to where the item is being held now.
    /// Slot k is the gap after the first k neighbours, its centre a cumulative
    /// sum of their sizes.
    public var targetIndex: Int {
        let center = startCenter + translation
        var slotMin = stripMin
        var best = 0
        var bestDistance = CGFloat.infinity
        for slot in 0...others.count {
            let distance = abs(center - (slotMin + ownSize / 2))
            if distance < bestDistance {
                best = slot
                bestDistance = distance
            }
            if slot < others.count { slotMin += others[slot].size }
        }
        return best
    }

    /// Everyone between the home slot and the target slot steps over by the
    /// carried item's size; the rest stand still.
    public func currentShifts() -> [String: CGFloat] {
        let target = targetIndex
        var shifts: [String: CGFloat] = [:]
        for index in min(target, homeIndex)..<max(target, homeIndex) {
            shifts[others[index].id] = target > homeIndex ? -ownSize : ownSize
        }
        return shifts
    }

    public func offset(of id: String) -> CGFloat {
        id == self.id ? translation : shifts[id] ?? 0
    }
}
