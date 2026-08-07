import RoostCore
import SwiftUI

/// The strip under the window: the active project's sessions in "work", the
/// filters in "overview".
///
/// Two rows, two jobs: the upper one belongs to the window, this one to the
/// view. In the overview there is no single project, and tabs would have
/// nothing to lean on there.
struct SessionBar: View {
    let model: WorkspaceModel

    /// The tab drag in flight. View state, not model state: while the mouse is
    /// down the model is not touched at all — the strip pretends with offsets,
    /// and only releasing commits the new order. Reordering mid-gesture tears
    /// the views out from under the gesture and everything stutters.
    @State private var drag: TabDrag?

    /// Every tab's frame in the strip's own space, kept fresh by a preference:
    /// tabs are as wide as their titles, so crossings cannot be computed from
    /// an index alone. A drag snapshots this once, at its start — the offsets
    /// it causes must not feed back into its own arithmetic.
    @State private var tabFrames: [String: CGRect] = [:]

    var body: some View {
        HStack(spacing: 0) {
            switch model.mode {
            case .work:
                // The project's name is not here: in "work" the bar is one of
                // three columns, and the name heads the sidebar's own column.
                tabs
            case .deck:
                label("SHOW")
                Hairline(vertical: true)
                filters
            }
        }
        .frame(height: Metrics.sessionBar)
        .background(Palette.sunken)
    }

    /// The header is exactly the sidebar's width — the strips below continue
    /// its column instead of arguing with it.
    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.label)
            .kerning(1)
            .foregroundStyle(Palette.faint)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, Metrics.gutter)
            .frame(width: Metrics.sidebarWidth, alignment: .leading)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            if let project = model.activeProject {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.tabs(of: project.id).enumerated()), id: \.element.id) {
                            index, tab in
                            TabButton(
                                model: model,
                                tab: tab,
                                number: index + 1,
                                isActive: tab.id == model.activeTab?.id
                            )
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: TabFramesKey.self,
                                        value: [tab.id: proxy.frame(in: .named("tabs"))]
                                    )
                                }
                            )
                            // Only the x: a tab lives in a strip and must not
                            // leave it, whatever the mouse does vertically.
                            .offset(x: drag?.offset(of: tab.id) ?? 0)
                            // The carried tab rides over its neighbours, or the
                            // one drawn later would cut through it.
                            .zIndex(drag?.tabID == tab.id ? 1 : 0)
                            .gesture(dragGesture(for: tab.id))
                            Hairline(vertical: true)
                        }
                    }
                    .coordinateSpace(name: "tabs")
                    .onPreferenceChange(TabFramesKey.self) { [$tabFrames] frames in
                        $tabFrames.wrappedValue = frames
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 0)
            Hairline(vertical: true)

            Button {
                model.newTab()
            } label: {
                Text("+")
                    .font(Typography.item)
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New claude session — ⌘T")
        }
    }

    private var filters: some View {
        let counts = model.statusCounts

        return HStack(spacing: 0) {
            filter(nil, "All", count: counts.values.reduce(0, +))
            ForEach([AgentStatus.waiting, .working, .done, .idle], id: \.self) { status in
                filter(status, status.rawValue.capitalized, count: counts[status] ?? 0)
            }
            Spacer(minLength: 0)
        }
    }

    private func filter(_ status: AgentStatus?, _ title: String, count: Int) -> some View {
        let isActive = model.filter == status

        return Button {
            model.filter = status
        } label: {
            HStack(spacing: 7) {
                if let status { AgentMark(status: status) }
                Text(title)
                    .font(Typography.item)
                    .foregroundStyle(isActive ? Palette.text : Palette.muted)
                Text("\(count)")
                    .font(Typography.label)
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background(isActive ? Palette.terminal : .clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Palette.accent : .clear)
                    .frame(height: Metrics.marker)
            }
            // Otherwise only the label is clickable: a transparent background
            // has no hit area of its own.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
    }

    /// Not the system drag-and-drop but a plain gesture: the strip reorders
    /// under the mouse, and the tab itself never leaves its row — a floating
    /// preview would promise a drop somewhere else, which does not exist here.
    ///
    /// Four points before it starts, so an ordinary click still selects.
    private func dragGesture(for tabID: String) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if drag?.tabID != tabID {
                    drag = TabDrag(tabID: tabID, frames: tabFrames)
                }
                drag?.translation = value.translation.width

                // The carried tab follows the mouse raw; the neighbours' shifts
                // flip in steps, and only those steps are animated. One
                // withAnimation over everything would drag the cursor itself
                // on a spring.
                guard let drag, drag.shifts != drag.currentShifts() else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.drag?.shifts = drag.currentShifts()
                }
            }
            .onEnded { _ in
                guard let drag else { return }
                // One animation over the commit and the cleanup together: the
                // layout change and the dying offsets cancel out, and the tab
                // glides from under the cursor into its slot.
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.moveTab(drag.tabID, to: drag.targetIndex)
                    self.drag = nil
                }
            }
    }
}

/// The arithmetic of a drag over a snapshot of frames taken at its start.
///
/// Everything is derived from `translation` and static geometry: which slot
/// the tab is nearest to, which neighbours must step aside for it. Nothing
/// here reads the live layout, so nothing can feed back and oscillate.
///
/// Slots, not centre-against-centre: near the ends the clamp keeps the
/// carried tab's centre from ever reaching the edge tab's centre, and a
/// comparison of centres leaves the edge slots unreachable. The nearest slot
/// is exact everywhere — at the full stop against the wall it is the wall's.
private struct TabDrag {
    let tabID: String

    private let ownWidth: CGFloat
    private let startCenter: CGFloat
    private let stripMinX: CGFloat
    private let travel: ClosedRange<CGFloat>

    /// The rest of the strip in display order, and where the carried tab
    /// stood among them.
    private let others: [(id: String, width: CGFloat)]
    private let homeIndex: Int

    var shifts: [String: CGFloat] = [:]

    var translation: CGFloat = 0 {
        // Clamped so the tab cannot be carried out of the strip: the row is
        // the only place it can go, and the geometry should say so.
        didSet { translation = min(max(translation, travel.lowerBound), travel.upperBound) }
    }

    init?(tabID: String, frames: [String: CGRect]) {
        guard let own = frames[tabID] else { return nil }
        let strip = frames.values.reduce(CGRect.null) { $0.union($1) }
        let sorted = frames.filter { $0.key != tabID }.sorted { $0.value.midX < $1.value.midX }

        self.tabID = tabID
        ownWidth = own.width
        startCenter = own.midX
        stripMinX = strip.minX
        travel = (strip.minX - own.minX)...(strip.maxX - own.maxX)
        others = sorted.map { ($0.key, $0.value.width) }
        homeIndex = sorted.firstIndex { $0.value.midX > own.midX } ?? sorted.count
    }

    /// The slot whose centre is nearest to where the tab is being held now.
    /// Slot k is the gap after the first k neighbours, its centre a cumulative
    /// sum of their widths.
    var targetIndex: Int {
        let center = startCenter + translation
        var slotMinX = stripMinX
        var best = 0
        var bestDistance = CGFloat.infinity
        for slot in 0...others.count {
            let distance = abs(center - (slotMinX + ownWidth / 2))
            if distance < bestDistance {
                best = slot
                bestDistance = distance
            }
            if slot < others.count { slotMinX += others[slot].width }
        }
        return best
    }

    /// Everyone between the home slot and the target slot steps over by the
    /// carried tab's width; the rest stand still.
    func currentShifts() -> [String: CGFloat] {
        let target = targetIndex
        var shifts: [String: CGFloat] = [:]
        for index in min(target, homeIndex)..<max(target, homeIndex) {
            shifts[others[index].id] = target > homeIndex ? -ownWidth : ownWidth
        }
        return shifts
    }

    func offset(of id: String) -> CGFloat {
        id == tabID ? translation : shifts[id] ?? 0
    }
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct TabButton: View {
    let model: WorkspaceModel
    let tab: TabSpec
    let number: Int
    let isActive: Bool

    @State private var hovered = false

    private var session: TerminalSession? { model.session(tab.activePaneID) }

    var body: some View {
        HStack(spacing: 7) {
            let status = session?.status ?? .none
            if status != .none {
                AgentMark(status: status)
            }

            Text(session?.name ?? tab.title)
                .font(Typography.item)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive || hovered ? Palette.text : Palette.muted)

            // The number is ⌘1…9 itself: the hint stands where it is pressed.
            Text("\(number)")
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Palette.faint)

            if tab.paneCount > 1 {
                Text("▚")
                    .font(Typography.label)
                    .foregroundStyle(Palette.faint)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 190, maxHeight: .infinity)
        // The active tab is lighter than the strip — it continues the pane
        // beneath it.
        .background(isActive ? Palette.terminal : .clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? Palette.accent : .clear)
                .frame(height: Metrics.marker)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.selectTab(tab.id) }
    }
}
