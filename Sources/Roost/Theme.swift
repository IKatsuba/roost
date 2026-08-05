import RoostCore
import SwiftUI

/// The look of the interface.
///
/// The chrome deliberately does not look like "an app around a terminal": the
/// same monospaced font, the same density, no rounded corners, shadows or
/// fills. Project names are directory names, tabs are processes; setting them
/// in a proportional font would be a lie.
enum Palette {
    /// The panes are darker than the terminal itself, so that output stays
    /// lighter than the chrome and draws the eye.
    static let chrome = Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x1A / 255)
    static let terminal = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)

    /// Darker than the chrome still — the session bar, so that it reads as a
    /// backing under the tabs rather than as one more panel.
    static let sunken = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x15 / 255)

    /// Hairlines instead of borders and shadows.
    static let line = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x2B / 255)

    /// The highlight of the row under the cursor — the only fill in the
    /// interface.
    static let lineSoft = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x24 / 255)

    static let text = Color(red: 0xC6 / 255, green: 0xC6 / 255, blue: 0xC1 / 255)
    static let muted = Color(red: 0x6A / 255, green: 0x6A / 255, blue: 0x71 / 255)
    static let faint = Color(red: 0x44 / 255, green: 0x44 / 255, blue: 0x4A / 255)

    /// The only accent — dusty blue. Used to mark the active element and for
    /// nothing else.
    static let accent = Color(red: 0x7F / 255, green: 0xA6 / 255, blue: 0xC4 / 255)

    static let danger = Color(red: 0xC9 / 255, green: 0x7A / 255, blue: 0x6E / 255)

    /// Muted green — only for "done, but unread".
    static let ok = Color(red: 0x8F / 255, green: 0xA8 / 255, blue: 0x8A / 255)

    static let terminalBackground = NSColor(
        srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1
    )
    static let terminalForeground = NSColor(
        srgbRed: 0xC6 / 255, green: 0xC6 / 255, blue: 0xC1 / 255, alpha: 1
    )
}

enum Typography {
    /// Not a single bold face: in a monospaced font, weight makes a line
    /// noticeably heavier, and colour is enough to tell elements apart.
    static let item = Font.custom("Menlo", size: 11.5)

    /// Section headers and the status bar: smaller and sparser.
    static let label = Font.custom("Menlo", size: 10)

    /// Computed rather than stored: `NSFont` is not `Sendable`, and a global
    /// constant holding one is an error in Swift 6.
    static var terminal: NSFont {
        NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
}

enum Metrics {
    static let sidebarWidth: CGFloat = 196
    static let rowHeight: CGFloat = 24
    static let statusBarHeight: CGFloat = 22

    /// The window bar: the path and the view switch. Nothing that changes from
    /// session to session lives here.
    static let titleBar: CGFloat = 34

    /// The session bar one row below — it belongs to the "work" view.
    static let sessionBar: CGFloat = 28

    /// Room on the left for the macOS traffic lights — tabs start after them.
    static let trafficLights: CGFloat = 78

    static let gutter: CGFloat = 10

    /// The width of the active element's marker.
    static let marker: CGFloat = 2

    /// A hairline — exactly one pixel on any screen.
    static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }
}

/// A divider: a line, not a frame.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(
                width: vertical ? Metrics.hairline : nil,
                height: vertical ? nil : Metrics.hairline
            )
    }
}

/// The agent's state as a single square.
///
/// A square, not a circle: there is not one rounded corner in this interface,
/// and a dot would break the row of hairlines and straight markers.
struct AgentDot: View {
    let status: AgentStatus
    var size: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    static func color(for status: AgentStatus) -> Color {
        switch status {
        // Red draws attention — it marks the one case where nothing moves
        // without a human.
        case .waiting: Palette.danger
        case .working: Palette.accent
        case .done: Palette.ok
        case .idle: Palette.muted
        case .exited, .none: Palette.faint
        }
    }

    var body: some View {
        Rectangle()
            .fill(Self.color(for: status))
            .frame(width: size, height: size)
            // A working agent is the only element of the interface allowed to
            // move.
            .opacity(status == .working && dimmed ? 0.28 : 1)
            .animation(
                status == .working && !reduceMotion
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .default,
                value: dimmed
            )
            .onAppear { dimmed = status == .working && !reduceMotion }
            .onChange(of: status) { dimmed = status == .working && !reduceMotion }
    }
}

/// Time spent waiting: `4:12` within the hour, `1h 2m` beyond it.
///
/// Tabular figures are a must — otherwise the counter twitches every second.
func formatAge(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let minutes = total / 60

    if minutes >= 60 {
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    return String(format: "%d:%02d", minutes, total % 60)
}
