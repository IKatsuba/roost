import RoostCore
import SwiftUI

/// The strip under the window: the active project's sessions.
///
/// Two rows, two jobs: the upper one belongs to the window, this one to the
/// project. The overview does without it — there is no single project there for
/// tabs to lean on, and the columns head themselves.
struct SessionBar: View {
    let model: WorkspaceModel

    /// The tab drag in flight. View state, not model state: while the mouse is
    /// down the model is not touched at all — the strip pretends with offsets,
    /// and only releasing commits the new order. Reordering mid-gesture tears
    /// the views out from under the gesture and everything stutters.
    @State private var drag: ReorderDrag?

    /// Every tab's frame in the strip's own space, kept fresh by a preference:
    /// tabs are as wide as their titles, so crossings cannot be computed from
    /// an index alone. A drag snapshots this once, at its start — the offsets
    /// it causes must not feed back into its own arithmetic.
    @State private var tabFrames: [String: CGRect] = [:]

    var body: some View {
        // The project's name is not here: the bar is one of three columns, and
        // the name heads the sidebar's own column.
        tabs
            .frame(height: Metrics.sessionBar)
            .background(Palette.sunken)
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
                                        key: ItemFramesKey.self,
                                        value: [tab.id: proxy.frame(in: .named("tabs"))]
                                    )
                                }
                            )
                            // Only the x: a tab lives in a strip and must not
                            // leave it, whatever the mouse does vertically.
                            .offset(x: drag?.offset(of: tab.id) ?? 0)
                            // The carried tab rides over its neighbours, or the
                            // one drawn later would cut through it.
                            .zIndex(drag?.id == tab.id ? 1 : 0)
                            .gesture(dragGesture(for: tab.id))
                            Hairline(vertical: true)
                        }
                    }
                    .coordinateSpace(name: "tabs")
                    .onPreferenceChange(ItemFramesKey.self) { [$tabFrames] frames in
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

    /// Not the system drag-and-drop but a plain gesture: the strip reorders
    /// under the mouse, and the tab itself never leaves its row — a floating
    /// preview would promise a drop somewhere else, which does not exist here.
    ///
    /// Four points before it starts, so an ordinary click still selects.
    private func dragGesture(for tabID: String) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if drag?.id != tabID {
                    drag = ReorderDrag(id: tabID, axis: .horizontal, frames: tabFrames)
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
                    model.moveTab(drag.id, to: drag.targetIndex)
                    self.drag = nil
                }
            }
    }
}

/// Every draggable item's frame in its container's own space. Sizes cannot be
/// computed from an index: tabs are as wide as their titles, and a project row
/// grows with what is drawn inside it.
struct ItemFramesKey: PreferenceKey {
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
