import AppKit
import SwiftUI

/// One row of the hint: what it does and what it is called.
struct ShortcutRow: Identifiable {
    let id = UUID()
    let title: String
    let keys: String
}

/// A section of the hint — exactly one submenu of the main menu.
struct ShortcutGroup: Identifiable {
    let id = UUID()
    let title: String
    let rows: [ShortcutRow]
}

/// Every shortcut at once — on a long hold of `⌘`.
///
/// The list is assembled from the main menu rather than written out a second
/// time next to it. A second list drifts away from the first sooner or later:
/// that already happened with `⌘O`, which stayed in three places of the
/// interface after the menu item moved to `⌘N`. The menu, meanwhile, is what
/// the system actually registered: if a row is here, the key works.
struct ShortcutHint: View {
    let groups: [ShortcutGroup]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                if index > 0 { Hairline(vertical: true) }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(column) { group in
                        Text(group.title.uppercased())
                            .font(Typography.label)
                            .kerning(1)
                            .foregroundStyle(Palette.faint)
                            .padding(.horizontal, 12)
                            .padding(.top, 9)
                            .padding(.bottom, 5)

                        ForEach(group.rows) { row in
                            HStack(spacing: 10) {
                                Text(row.title)
                                    .font(Typography.item)
                                    .lineLimit(1)
                                    .foregroundStyle(Palette.muted)

                                Spacer(minLength: 12)

                                Text(row.keys)
                                    .font(Typography.item)
                                    .foregroundStyle(Palette.text)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: Metrics.rowHeight)
                        }
                    }
                }
                .frame(width: 250, alignment: .leading)
                .padding(.bottom, 9)
            }
        }
        .background(Palette.chrome)
        .overlay(Rectangle().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
    }

    /// Two columns split by height rather than evenly by section count: "Pane"
    /// is twice as long as the rest, and splitting in half would give a lopsided
    /// column.
    private var columns: [[ShortcutGroup]] {
        var columns: [[ShortcutGroup]] = [[], []]
        var heights = [0, 0]

        for group in groups {
            let shorter = heights[0] <= heights[1] ? 0 : 1
            columns[shorter].append(group)
            heights[shorter] += group.rows.count + 1
        }

        return columns.filter { !$0.isEmpty }
    }
}

// MARK: - Gathering from the menu

/// The mark for "this item is ours".
///
/// AppKit appends items of its own: "Start Dictation…" and "Emoji & Symbols" in
/// Edit, the ⌥ twin of Quit in the app menu. They have no place in the hint —
/// they are not about Roost and they arrive in the system's language, while the
/// interface here is English.
let ownMenuItem = "dev.katsuba.roost.menu"

/// The hint's sections, taken from the app's main menu.
///
/// Items without a key are skipped: the hint promises the keyboard, and a row
/// without one means nothing in it.
func shortcutGroups(of menu: NSMenu?) -> [ShortcutGroup] {
    (menu?.items ?? []).compactMap { top in
        guard let submenu = top.submenu else { return nil }

        let rows = shortcutRows(of: submenu.items)
        return rows.isEmpty ? nil : ShortcutGroup(title: top.title, rows: rows)
    }
}

private func shortcutRows(of items: [NSMenuItem]) -> [ShortcutRow] {
    var rows: [ShortcutRow] = []
    var digits: [NSMenuItem] = []

    // Nine "Session N" items would take half a column while adding nothing: a
    // row of digits reads as a single rule anyway.
    func flush() {
        guard let first = digits.first, let last = digits.last else { return }
        defer { digits = [] }

        guard digits.count > 1 else {
            rows.append(ShortcutRow(title: first.title, keys: shortcutKeys(of: first)))
            return
        }

        // The title is taken from the item itself, minus the number: there are
        // two numbered sections — "Session 1" and "Project 1" — and labelling
        // them with one word would lie about one of them.
        let base = first.title.split(separator: " ").dropLast().joined(separator: " ")

        rows.append(
            ShortcutRow(
                title: "\(base) by Number",
                keys: "\(modifierGlyphs(first.keyEquivalentModifierMask))"
                    + "\(first.keyEquivalent)…\(last.keyEquivalent)"
            )
        )
    }

    let own = items.filter {
        !$0.keyEquivalent.isEmpty && $0.representedObject as? String == ownMenuItem
    }

    for item in own {
        if item.keyEquivalent.count == 1, item.keyEquivalent.first?.isNumber == true {
            digits.append(item)
            continue
        }

        flush()
        rows.append(ShortcutRow(title: item.title, keys: shortcutKeys(of: item)))
    }
    flush()

    return rows
}

private func shortcutKeys(of item: NSMenuItem) -> String {
    modifierGlyphs(item.keyEquivalentModifierMask) + keyGlyph(item.keyEquivalent)
}

/// The glyph order follows the rest of the interface (`⌘⇧T`, `⌘⌥↓`) rather than
/// the system menu (`⇧⌘T`): the hint is read next to the palette, and two
/// spellings of one shortcut inside one app would confuse more than a mismatch
/// with the menu, which is closed at that moment.
private func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
    var glyphs = ""
    if flags.contains(.command) { glyphs += "⌘" }
    if flags.contains(.control) { glyphs += "⌃" }
    if flags.contains(.option) { glyphs += "⌥" }
    if flags.contains(.shift) { glyphs += "⇧" }
    return glyphs
}

/// Arrows sit in `keyEquivalent` as non-printable codes: drawn as they are,
/// they would come out as empty space.
private func keyGlyph(_ key: String) -> String {
    switch key.unicodeScalars.first.map({ Int($0.value) }) {
    case NSLeftArrowFunctionKey: "←"
    case NSRightArrowFunctionKey: "→"
    case NSUpArrowFunctionKey: "↑"
    case NSDownArrowFunctionKey: "↓"
    default: key.uppercased()
    }
}
