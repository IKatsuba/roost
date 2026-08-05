import RoostCore
import SwiftTerm
import SwiftUI

/// The pane layout of a tab.
///
/// The tree is drawn recursively, and sizes are computed from the available
/// space rather than stored in pixels: the window is resized more often than a
/// human drags a divider, and a proportion survives that without recalculation.
///
/// `AnyView` here is not laziness: without type erasure the "tree → split →
/// tree" recursion would be expanded by the compiler forever.
struct PaneTreeView: View {
    let model: WorkspaceModel
    let tab: TabSpec
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let pane):
            AnyView(
                PaneLeafView(
                    model: model,
                    pane: pane,
                    isActive: pane.id == tab.activePaneID,
                    // A single pane needs no marker — there is nothing to
                    // single out.
                    showsMarker: tab.paneCount > 1
                )
            )

        case .split(let split):
            AnyView(SplitLayout(model: model, tab: tab, split: split))
        }
    }
}

private struct PaneLeafView: View {
    let model: WorkspaceModel
    let pane: PaneSpec
    let isActive: Bool
    let showsMarker: Bool

    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            if showsMarker {
                Rectangle()
                    .fill(isActive ? Palette.accent : .clear)
                    .frame(width: Metrics.marker)
            }

            VStack(spacing: 0) {
                header
                Hairline()

                if let session = model.session(pane.id) {
                    TerminalPaneView(session: session)
                } else {
                    // The session comes up on the tick after the pane appears —
                    // until then we draw the terminal's background rather than
                    // a spinner: the pane is already in place.
                    Palette.terminal
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    /// The strip above a pane answers "what is here and for how long" — without
    /// it, in a split of four terminals there is no telling which one waits.
    private var header: some View {
        let session = model.session(pane.id)

        return HStack(spacing: 7) {
            AgentDot(status: session?.status ?? .none)

            Text(session?.name ?? pane.title)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            if let session, session.status != .none {
                Text(formatAge(Date().timeIntervalSince(session.statusChangedAt)))
                    .monospacedDigit()
                    .foregroundStyle(Palette.faint)
            }
        }
        .font(Typography.label)
        .kerning(0.4)
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10)
        .frame(height: Metrics.rowHeight)
        .background(Palette.chrome)
    }
}

private struct SplitLayout: View {
    let model: WorkspaceModel
    let tab: TabSpec
    let split: PaneNode.Split

    /// The proportion during a drag. It goes into the model only when the
    /// gesture ends: every update there rebuilds the layout.
    @State private var dragging: Double?

    /// A hairline down the middle with a wide grab area around it — hitting one
    /// pixel with a mouse is impossible.
    private let grip: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let horizontal = split.axis == .row
            let extent = horizontal ? geometry.size.width : geometry.size.height
            let available = max(0, extent - grip)
            let ratio = dragging ?? split.ratio
            let first = available * ratio

            let layout = horizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))

            layout {
                PaneTreeView(model: model, tab: tab, node: split.first)
                    .frame(
                        width: horizontal ? first : nil,
                        height: horizontal ? nil : first
                    )

                divider(horizontal: horizontal, available: available)

                PaneTreeView(model: model, tab: tab, node: split.second)
                    .frame(
                        width: horizontal ? available - first : nil,
                        height: horizontal ? nil : available - first
                    )
            }
        }
    }

    private func divider(horizontal: Bool, available: CGFloat) -> some View {
        ZStack {
            Palette.chrome
            Hairline(vertical: horizontal)
        }
        .frame(width: horizontal ? grip : nil, height: horizontal ? nil : grip)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard available > 0 else { return }
                    let moved = horizontal ? value.translation.width : value.translation.height
                    let ratio = (split.ratio * available + moved) / available
                    dragging = min(
                        max(ratio, PaneNode.Split.minRatio),
                        PaneNode.Split.maxRatio
                    )
                }
                .onEnded { _ in
                    if let dragging { model.setRatio(split.id, to: dragging) }
                    dragging = nil
                }
        )
    }
}

/// Shows the session's already existing view.
///
/// The widget deliberately owns neither the terminal nor the process —
/// otherwise rebuilding the tree would kill whatever is running.
struct TerminalPaneView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> PaneTerminalView { session.view }

    func updateNSView(_ view: PaneTerminalView, context: Context) {}
}
