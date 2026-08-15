import Combine
import SwiftUI

/// How long ago something happened, counting up on its own.
///
/// The label keeps its own `now`, and that is the whole point. The counter has
/// to move every second, and it used to move by side effect: the overview, the
/// side panel and every pane each raised a one-second timer that wrote a `now`
/// nobody read, purely so the body would be built again and the `Date()` inside
/// it come out later than before. A tick therefore invalidated whatever held
/// the timer — all the cards, the whole panel, the view that owns the terminal
/// — and SwiftUI laid the window out once a second to change four characters.
/// Here the second hand reaches the label and stops.
struct Age: View {
    /// What the count is from — the moment the status last changed, or the
    /// event's own time. Nil reads as `0:00`: a pane whose session has not come
    /// up yet has nothing to count from, and an empty slot where a figure
    /// belongs would jump the row's layout the moment it arrives.
    let since: Date?

    /// A word the reading needs to be read at all: `2:03 idle`, `1h 4m back`.
    /// Inside the label rather than beside it, because two `Text`s in a stack
    /// would cost a layout pass of their own every second.
    var suffix: String?

    @State private var now = Date()

    var body: some View {
        let age = formatAge(since.map { now.timeIntervalSince($0) } ?? 0)

        Text(suffix.map { "\(age) \($0)" } ?? age)
            .monospacedDigit()
            .onReceive(Clock.second) { now = $0 }
    }
}

/// The one clock every age on screen runs on.
///
/// A single publisher rather than a timer per label: a busy machine shows
/// dozens of these at once, and dozens of timers would wake the run loop
/// dozens of times to say the same second.
/// On the main actor because that is where it fires and where it is heard: the
/// publisher is scheduled on the main run loop, and every subscriber is a view.
@MainActor
enum Clock {
    static let second = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
}
