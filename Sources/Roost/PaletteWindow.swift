import AppKit

/// The palette's window — separate, not a layer inside the main one.
///
/// Inside the main window the first responder is the terminal's `NSView`, and
/// taking that away for a text field would mean fighting SwiftTerm over every
/// keystroke. A key window of its own removes the question entirely: while the
/// palette is open the keyboard belongs to it, and nobody in the window below
/// loses anything.
final class PaletteWindow: NSPanel {
    /// Keys that have to be intercepted before the text field: it reads arrows
    /// as cursor movement and never lets them out again.
    var keyHandler: ((NSEvent) -> Bool)?

    // A borderless window does not become key by default — and without that the
    // palette would not get a single character.
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
