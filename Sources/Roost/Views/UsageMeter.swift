import RoostCore
import SwiftUI

/// How much of each window is gone, at the bottom of the window.
///
/// In the status bar rather than the window bar, and quiet on purpose. A
/// percentage that is always on screen is news about one afternoon in ten: what
/// matters is nearing the ceiling, not the number itself. So it is written in
/// the same muted tone as everything else down here, and the window that has
/// gone past the mark is the one set in full text colour — the trick the count
/// of waiting agents already uses, in a palette with no colour to spend.
///
/// Clicking opens the spending panel, where the same windows are drawn with
/// what they cost.
struct UsageMeter: View {
    let model: WorkspaceModel

    @State private var now = Date()
    @State private var hovered = false

    /// Reset times are counted in minutes; half of one keeps the number from
    /// sitting visibly stale after a window turns over.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Where "nearly out" begins.
    ///
    /// Four fifths, because that is roughly where the answer changes: below it
    /// a human carries on, above it they start deciding what to spend the rest
    /// on. The exact figure matters less than there being one — the point is
    /// that the row is silent until it has something to say.
    private static let alarm: Double = 80

    var body: some View {
        let snapshot = model.usage.snapshot

        Group {
            if snapshot.limits.isEmpty {
                // No ceilings: nobody has logged in, the token wants replacing,
                // or the count is still running. The tokens are ours either
                // way, so the window says what it spent — quietly, and only
                // once there is something to say.
                if !snapshot.window.usage.isEmpty {
                    Text("5H \(formatTokens(snapshot.window.usage.total))")
                        .foregroundStyle(Palette.faint)
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(Array(plain(snapshot).enumerated()), id: \.element.id) { index, limit in
                        if index > 0 {
                            Text("·").foregroundStyle(Palette.faint)
                        }
                        row(limit)
                    }
                }
            }
        }
        .font(Typography.label)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(hovered ? Palette.lineSoft : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.showSpending() }
        .onReceive(tick) { now = $0 }
        .help("what each window has spent · click for the breakdown")
    }

    private func row(_ limit: LimitWindow) -> some View {
        // Full weight past the mark, muted below it. Both halves of the pair
        // move together: a window worth noticing is worth reading whole.
        let near = limit.usedPercent >= Self.alarm

        return HStack(spacing: 5) {
            Text(limit.title)
                .foregroundStyle(near ? Palette.text : Palette.faint)

            Text("\(Int(limit.usedPercent.rounded()))%")
                .foregroundStyle(near ? Palette.text : Palette.muted)

            if let resets = limit.resetsAt {
                Text(formatRemaining(resets.timeIntervalSince(now)))
                    .foregroundStyle(Palette.faint)
            }
        }
    }

    /// The two windows everything counts against.
    ///
    /// The per-model weeks stay in the panel: they are a ceiling on one model
    /// rather than on the work, and four of them along the bottom of the window
    /// would be a row of numbers nobody reads instead of one they do.
    private func plain(_ snapshot: UsageSnapshot) -> [LimitWindow] {
        snapshot.limits.filter { $0.label == nil }
    }
}
