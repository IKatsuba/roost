import AppKit
import RoostCore
import SwiftUI

/// The look of the interface — the same one katsuba.dev wears.
///
/// The palette is the site's neutral scale, converted from its oklch tokens:
/// one ground, one text colour, two greys between them, and hairlines. Fills
/// carry no meaning here; borders separate things, exactly as they do on the
/// site.
///
/// One colour survives the monochrome, and it means one thing: an agent that
/// cannot move without a human. Everything else — working, done, idle — is told
/// apart by weight, the way the site tells its own states apart.
enum Palette {
    /// A colour that follows the system appearance.
    ///
    /// `NSColor` resolves it per view rather than per launch, so light and dark
    /// need no reload and no switch of our own — which is the whole reason the
    /// tokens are `NSColor` and not `Color`.
    private static func dynamic(light: Int, dark: Int, alpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: alpha
            )
        }
    }

    // MARK: - Grounds

    /// The ground everything stands on. The panes and the chrome share it: on
    /// the site nothing is separated by a fill, only by a line.
    static let chromeColor = dynamic(light: 0xFFFFFF, dark: 0x0A0A0A)
    static let chrome = Color(nsColor: chromeColor)
    static let terminal = Color(nsColor: chromeColor)

    /// One step off the ground — the session bar, so that it reads as a backing
    /// under the tabs.
    static let sunken = Color(nsColor: dynamic(light: 0xFAFAFA, dark: 0x171717))

    /// The fill under the cursor, and the only fill in the interface.
    static let lineSoft = Color(nsColor: dynamic(light: 0xF5F5F5, dark: 0x262626))

    /// Hairlines instead of borders and shadows. In the dark the site uses
    /// white at a tenth, not a grey — it keeps the line from going muddy over
    /// the near-black ground.
    static let line = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.1)
                : NSColor(srgbRed: 0.898, green: 0.898, blue: 0.898, alpha: 1)
        }
    )

    // MARK: - Type

    static let textColor = dynamic(light: 0x0A0A0A, dark: 0xFAFAFA)
    static let text = Color(nsColor: textColor)

    /// Secondary text: labels, hints, everything said quietly.
    static let muted = Color(nsColor: dynamic(light: 0x737373, dark: 0xA1A1A1))

    /// The quietest tier — decorative marks and states nobody owes anything to.
    static let faint = Color(nsColor: dynamic(light: 0xA3A3A3, dark: 0x525252))

    // MARK: - Meaning

    /// The accent is the text colour itself. The site marks what matters by
    /// inverting it — a solid bar, a filled badge — rather than by hue.
    ///
    /// There is no second colour, and no red: states are told apart by the
    /// texture of their mark, see [AgentMark].
    static let accent = text

    // MARK: - Terminal

    /// SwiftTerm takes concrete colours, not dynamic ones — it converts them
    /// the moment they are set. `PaneTerminalView` re-applies these when the
    /// appearance changes; see its `viewDidChangeEffectiveAppearance`.
    static var terminalBackground: NSColor { chromeColor }
    static var terminalForeground: NSColor { textColor }
}

enum Typography {
    /// Geist Mono is the site's face, so it is the app's face too. It travels
    /// inside the bundle: a machine without it installed would otherwise fall
    /// back to whatever monospaced font it has, and the rebrand would last
    /// exactly as far as this Mac.
    ///
    /// Registration is lazy on purpose — the first font asked for is the first
    /// one drawn, and a `static let` runs once, before it.
    @MainActor private static let registered: Bool = {
        guard let url = Bundle.module.url(forResource: "GeistMono", withExtension: "ttf") else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    @MainActor private static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        _ = registered
        return .custom("Geist Mono", size: size).weight(weight)
    }

    /// Rows, titles, terminal-adjacent text.
    @MainActor static var item: Font { geist(11.5) }

    /// Section headers and the status bar: smaller and sparser.
    @MainActor static var label: Font { geist(10) }

    /// The active row, and only it. The site sets what it means to point at in
    /// medium; anything heavier thickens a monospaced line more than it
    /// emphasises it.
    @MainActor static var itemEmphasis: Font { geist(11.5, .medium) }

    /// The terminal keeps Menlo, and this is not an oversight.
    ///
    /// Geist Mono has box drawing and blocks, but no braille — and braille is
    /// what Claude Code spins while an agent works (`⠋⠙⠹`), along with the `✳`
    /// in its own title. Missing glyphs come from a fallback face of another
    /// width, and a terminal grid pays for that in drifting columns.
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
/// A square, not a circle: there is not one rounded corner in this interface.
/// And with no colour left to spend, the states are told apart by **texture** —
/// how densely the square is filled:
///
///     ■  waiting   solid — the only mark that fills completely
///     ≡  working   bars, and the one thing allowed to move
///     ▨  done      a checker, half as present as solid
///     □  idle      an outline: nothing owed in either direction
///     ▫  exited    the same outline, gone quiet
///
/// Texture beats hue here for the same reason it does on a printed chart: it
/// survives greyscale, colour blindness, and a screenshot pasted into a chat.
/// The ladder is monotonic on purpose — the more ink, the more it wants from
/// you.
struct AgentMark: View {
    let status: AgentStatus
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    enum Texture {
        case solid
        case bars
        case checker
        case outline
    }

    static func texture(for status: AgentStatus) -> Texture {
        switch status {
        // Solid, and solid alone: without a human this one does not move.
        case .waiting: .solid
        case .working: .bars
        case .done: .checker
        case .idle, .exited, .none: .outline
        }
    }

    /// Lightness carries the same order as the texture, so the ladder still
    /// reads where a mark is too small for a pattern — the strips under a
    /// project's name, for one.
    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .waiting, .working: Palette.text
        case .done: Palette.muted
        case .idle: Palette.muted
        case .exited, .none: Palette.faint
        }
    }

    var body: some View {
        Canvas { context, size in
            let color = Self.color(for: status)
            let box = CGRect(origin: .zero, size: size)

            switch Self.texture(for: status) {
            case .solid:
                context.fill(Path(box), with: .color(color))

            case .bars:
                // Three bars with gaps of their own width: at 8pt that is two
                // pixels of ink and two of ground on a retina screen, which is
                // the finest stripe that does not turn into grey mush.
                var bars = Path()
                for y in stride(from: 0.0, to: size.height, by: 3) {
                    bars.addRect(CGRect(x: 0, y: y, width: size.width, height: 1.5))
                }
                context.fill(bars, with: .color(color))

            case .checker:
                // A 4×4 checker — the classic 50% dither, and the only way to
                // read "half filled" at this size.
                let unit = size.width / 4
                var cells = Path()
                for row in 0..<4 {
                    for column in 0..<4 where (row + column).isMultiple(of: 2) {
                        cells.addRect(
                            CGRect(
                                x: CGFloat(column) * unit,
                                y: CGFloat(row) * unit,
                                width: unit,
                                height: unit
                            )
                        )
                    }
                }
                context.fill(cells, with: .color(color))

            case .outline:
                // Inset by half a line, or the stroke would straddle the edge
                // and come out two pixels wide and grey.
                context.stroke(
                    Path(box.insetBy(dx: 0.5, dy: 0.5)),
                    with: .color(color),
                    lineWidth: 1
                )
            }
        }
        .frame(width: size, height: size)
        // A working agent is the only element of the interface allowed to move.
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
