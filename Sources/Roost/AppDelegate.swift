import AppKit
import RoostCore
import SwiftUI

@main
enum RoostMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = WorkspaceModel()
    private var window: NSWindow!
    private var clickMonitor: Any?

    private var palette: PaletteWindow?
    private var paletteState: PaletteState?

    /// The shortcut cheat sheet and the delayed show that waits for its second.
    private var hint: NSPanel?
    private var hintTask: Task<Void, Never>?

    /// How long `⌘` has to be held before the list appears.
    ///
    /// Half a second is too little: that is how long ⌘ is down in any ordinary
    /// shortcut, and the hint would flash on every `⌘T`. Almost a second is
    /// already the question "what is there?", not a pause before pressing.
    private static let hintDelay = Duration.milliseconds(900)

    /// The palette's top edge is remembered when it opens: the window changes
    /// height as you type, and it must grow downwards rather than jump.
    private var paletteTop: CGFloat = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        buildWindow()
        watchClicks()
        watchCommandKey()

        Task { await model.start() }
    }

    /// A click on a pane makes it active. A monitor rather than a SwiftUI
    /// gesture: the event is only observed and travels on to the terminal
    /// untouched.
    ///
    /// The event's location goes into `hitTest` as it comes, without being
    /// converted: `hitTest` asks for a point in the **superview's** system, and
    /// the content view's superview is the window's frame — the very system
    /// `locationInWindow` is already in. Converting it into the content view
    /// first looks like the careful thing to do and is exactly the trap:
    /// `NSHostingView` is flipped, so the conversion mirrors y, and a click in
    /// the upper pane of a `⌘⇧D` split made the lower one active. A `⌘D` split
    /// hid it — mirroring y leaves left and right where they were.
    private func watchClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            if let self, let root = event.window?.contentView,
               let hit = root.hitTest(event.locationInWindow) {
                MainActor.assumeIsolated { self.model.focusPane(containing: hit) }
            }
            return event
        }
    }

    /// Holding `⌘` for a while shows the shortcut list.
    ///
    /// A monitor, same as for clicks: the event is only observed and travels on
    /// untouched — nothing may be taken away from the terminal for the sake of
    /// a hint.
    private func watchCommandKey() {
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
            [weak self] event in
            if let self { MainActor.assumeIsolated { self.trackCommandHold(event) } }
            return event
        }
    }

    private func trackCommandHold(_ event: NSEvent) {
        // Any key on top of ⌘ is an ordinary shortcut, not the question "what
        // is there?": we cancel without waiting for ⌘ to be released.
        let held = event.type == .flagsChanged
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command

        guard held else {
            hideHint()
            return
        }

        // While the palette is open the hint would only cover it — and the
        // palette is that same list of commands anyway, only searchable.
        guard hint == nil, hintTask == nil, !model.isPaletteOpen else { return }

        hintTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hintDelay)
            guard !Task.isCancelled else { return }
            self?.showHint()
        }
    }

    private func showHint() {
        guard hint == nil else { return }

        let content = NSHostingController(
            rootView: ShortcutHint(groups: shortcutGroups(of: NSApp.mainMenu))
        )
        content.sizingOptions = [.preferredContentSize]

        // Not a `PaletteWindow`: that one deliberately becomes key, while the
        // hint is there to be read — there is no reason to take focus from
        // anybody, and the mouse passes through it to whatever is underneath.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        // The size is taken from the content, not from the panel: the panel
        // still holds the size it was created with, and the hint would end up
        // off centre.
        let size = content.view.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(
            NSPoint(
                x: window.frame.midX - size.width / 2,
                y: window.frame.midY - size.height / 2
            )
        )

        hint = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    private func hideHint() {
        hintTask?.cancel()
        hintTask = nil

        guard let panel = hint else { return }
        hint = nil
        window.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `⌘⇥` leaves the app without releasing ⌘, and we will never see the
    /// release event — the hint would be left hanging over somebody else's
    /// window.
    func applicationDidResignActive(_ notification: Notification) {
        hideHint()
    }

    /// Quitting with an agent mid-task is asked about — see [QuitGuard] for
    /// why only `working` earns the question.
    ///
    /// It hangs on terminate rather than on the window's close button: `⌘Q`,
    /// the Dock's Quit and a logout all arrive here, while closing the window
    /// only gets here because the app quits after it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prompt = QuitGuard.prompt(working: model.workingNames) else {
            return .terminateNow
        }

        // The hint is a child of the window and would stay on top of the
        // dialog: ⌘Q is pressed with ⌘ held, which is exactly what raises it.
        hideHint()

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.body
        alert.addButton(withTitle: "quit")
        // The second button is the one Esc and Return-on-default pick — the
        // safe answer is the accidental one.
        alert.addButton(withTitle: "cancel")
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// The usage ledger is deliberately not saved here: it is a cache of what
    /// the transcripts already say, and writing it would mean blocking the quit
    /// on a background actor that may be mid-scan. Whatever the last periodic
    /// save missed is read again from the files on the next launch.
    func applicationWillTerminate(_ notification: Notification) {
        model.save()
    }

    // MARK: - Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.setFrameAutosaveName("roost.main")
        window.contentView = NSHostingView(rootView: RootView(model: model))

        // There is no title: the path to the project is written in the bar
        // itself.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The dynamic NSColor, not one squeezed through SwiftUI: the window
        // has to repaint itself when the system appearance changes.
        window.backgroundColor = Palette.chromeColor

        // The window bar holds only the path and the view switch. Nothing that
        // changes from session to session: sessions live one row below, in
        // ordinary content, where clicks can be relied upon unconditionally.
        //
        // Two accessories rather than one: each has its own edge of the window.
        // A single full-width one would have to know that width in advance —
        // and would lag behind it on every resize.
        addTitleBar(NSHostingView(rootView: TitleBarPath(model: model)), at: .leading, width: 520)
        addTitleBar(NSHostingView(rootView: ViewSwitch(model: model)), at: .trailing)

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// An accessory needs a real frame: under Auto Layout it collapses to zero
    /// and disappears from the screen. The width is either given or taken from
    /// the content — the switch's content is constant, and the room for the
    /// counter is reserved inside it.
    private func addTitleBar(_ view: NSView, at edge: NSLayoutConstraint.Attribute, width: CGFloat? = nil) {
        let measured = width ?? max(view.fittingSize.width, 1)
        view.frame = NSRect(x: 0, y: 0, width: measured, height: Metrics.titleBar)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = edge
        accessory.view = view
        window.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: - Menu

    /// Shortcuts are declared as menu items rather than by intercepting keys:
    /// that way a human can see them, and they do not argue with whatever is
    /// being typed in the terminal.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(submenu("Roost") { app in
            app.addItem(item("Hide Roost", "h", [.command], #selector(NSApplication.hide(_:)), target: nil))
            app.addItem(.separator())
            app.addItem(item("Quit Roost", "q", [.command], #selector(NSApplication.terminate(_:)), target: nil))
        })

        menu.addItem(submenu("File") { file in
            file.addItem(action("New Project…", "n", [.command], #selector(openProjectMenu)))
            file.addItem(action("Open Session…", "o", [.command], #selector(openSessionPalette)))
            file.addItem(.separator())
            file.addItem(action("New Claude Session", "t", [.command], #selector(newClaudeTab)))
            file.addItem(action("New Shell", "t", [.command, .shift], #selector(newShellTab)))
            file.addItem(action("Claude in a Worktree…", "n", [.command, .shift], #selector(openWorktreePalette)))
            file.addItem(.separator())
            file.addItem(action("Close Pane", "w", [.command], #selector(closePane)))
        })

        menu.addItem(submenu("Edit") { edit in
            // A nil target means the first responder: copying and pasting is
            // done by the terminal itself, which has its own implementations.
            edit.addItem(item("Copy", "c", [.command], #selector(NSText.copy(_:)), target: nil))
            edit.addItem(item("Paste", "v", [.command], #selector(NSText.paste(_:)), target: nil))
            edit.addItem(item("Select All", "a", [.command], #selector(NSText.selectAll(_:)), target: nil))
        })

        // The submenu order goes top down by nesting: the project, the session
        // inside it, the pane inside the session. The ⌘ hint inherits that
        // order — it reads the menu as it is.
        // ⌥ moves through lists, ⇧ moves inside a split. The split is
        // consistent: the sidebar and the tab bar are lists, panes are one tab
        // seen from within, and fingers never confuse the two.
        menu.addItem(submenu("Projects") { projects in
            // Up and down, because the sidebar is a vertical list. Left and
            // right went to tabs, which lie in a strip.
            projects.addItem(action("Previous Project", arrow(NSUpArrowFunctionKey), [.command, .option], #selector(previousProject)))
            projects.addItem(action("Next Project", arrow(NSDownArrowFunctionKey), [.command, .option], #selector(nextProject)))
            projects.addItem(.separator())
            for index in 1...9 {
                let item = action("Project \(index)", "\(index)", [.command, .option], #selector(selectProjectByNumber(_:)))
                item.tag = index - 1
                projects.addItem(item)
            }
        })

        menu.addItem(submenu("Sessions") { tabs in
            tabs.addItem(action("Previous Session", arrow(NSLeftArrowFunctionKey), [.command, .option], #selector(previousTab)))
            tabs.addItem(action("Next Session", arrow(NSRightArrowFunctionKey), [.command, .option], #selector(nextTab)))
            tabs.addItem(.separator())
            for index in 1...9 {
                let item = action("Session \(index)", "\(index)", [.command], #selector(selectTabByNumber(_:)))
                item.tag = index - 1
                tabs.addItem(item)
            }
        })

        menu.addItem(submenu("Pane") { pane in
            // The letter says what to raise, ⇧ says where to put it. Modifiers
            // beyond ⌘ will not do: the system takes ⌥⌘D for the Dock and ⌃⌘D
            // for "Look Up", and such a press never reaches the menu at all.
            pane.addItem(action("Split Right with Claude", "d", [.command], #selector(splitRight)))
            pane.addItem(action("Split Down with Claude", "d", [.command, .shift], #selector(splitDown)))
            pane.addItem(action("Split Right with Shell", "e", [.command], #selector(splitRightShell)))
            pane.addItem(action("Split Down with Shell", "e", [.command, .shift], #selector(splitDownShell)))
            pane.addItem(.separator())
            pane.addItem(action("Focus Left", arrow(NSLeftArrowFunctionKey), [.command, .shift], #selector(focusLeft)))
            pane.addItem(action("Focus Right", arrow(NSRightArrowFunctionKey), [.command, .shift], #selector(focusRight)))
            pane.addItem(action("Focus Up", arrow(NSUpArrowFunctionKey), [.command, .shift], #selector(focusUp)))
            pane.addItem(action("Focus Down", arrow(NSDownArrowFunctionKey), [.command, .shift], #selector(focusDown)))
        })

        menu.addItem(submenu("View") { find in
            find.addItem(action("Command Palette", "k", [.command], #selector(togglePalette)))
            find.addItem(action("Jump to Waiting Agent", "a", [.command, .shift], #selector(nextWaiting)))
            find.addItem(.separator())
            find.addItem(action("Toggle Projects Sidebar", "b", [.command], #selector(toggleSidebar)))
            find.addItem(action("Toggle Side Panel", "b", [.command, .shift], #selector(toggleSidePanel)))
        })

        return menu
    }

    private func submenu(_ title: String, _ fill: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        fill(menu)
        item.submenu = menu
        return item
    }

    private func item(
        _ title: String,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags,
        _ selector: Selector,
        target: AnyObject?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target

        // We mark our own item so that the hint can tell it from the ones the
        // system appends.
        item.representedObject = ownMenuItem
        return item
    }

    private func action(
        _ title: String,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags,
        _ selector: Selector
    ) -> NSMenuItem {
        item(title, key, modifiers, selector, target: self)
    }

    private func arrow(_ code: Int) -> String {
        String(UnicodeScalar(code) ?? " ")
    }

    // MARK: - Menu commands

    @objc private func openProjectMenu() { openProject(model: model) }
    @objc private func newClaudeTab() { model.newTab(kind: .claude) }
    @objc private func newShellTab() { model.newTab(kind: .shell) }
    @objc private func closePane() { model.closeActivePane() }
    @objc private func splitRight() { model.splitActivePane(.row, kind: .claude) }
    @objc private func splitDown() { model.splitActivePane(.column, kind: .claude) }
    @objc private func splitRightShell() { model.splitActivePane(.row, kind: .shell) }
    @objc private func splitDownShell() { model.splitActivePane(.column, kind: .shell) }
    @objc private func focusLeft() { model.focus(.left) }
    @objc private func focusRight() { model.focus(.right) }
    @objc private func focusUp() { model.focus(.up) }
    @objc private func focusDown() { model.focus(.down) }
    @objc private func nextTab() { model.cycleTab(by: 1) }
    @objc private func previousTab() { model.cycleTab(by: -1) }
    @objc private func nextWaiting() { model.focusNextWaiting() }
    @objc private func toggleSidebar() { model.toggleSidebar() }
    @objc private func toggleSidePanel() { model.toggleSidePanel() }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        model.selectTab(index: sender.tag)
    }

    @objc private func nextProject() { model.cycleProject(by: 1) }
    @objc private func previousProject() { model.cycleProject(by: -1) }

    @objc private func selectProjectByNumber(_ sender: NSMenuItem) {
        model.selectProject(index: sender.tag)
    }

    @objc private func togglePalette() { showPalette(scope: .everything) }
    @objc private func openSessionPalette() { showPalette(scope: .sessions) }
    @objc private func openWorktreePalette() { showPalette(scope: .worktree) }

    // MARK: - Palette

    /// The same shortcut closes its own palette but switches somebody else's:
    /// `⌘O` on top of an open `⌘K` means "show me the sessions", not "close".
    private func showPalette(scope: PaletteState.Scope) {
        if let open = paletteState {
            closePalette(refocus: open.scope == scope)
            guard open.scope != scope else { return }
        }

        openPalette(scope: scope)
    }

    private func openPalette(scope: PaletteState.Scope) {
        guard palette == nil else { return }

        // The session catalog is re-read on every open: sessions have been
        // added while we worked, and some may have arrived from another
        // machine.
        model.refreshKnownSessions()

        let state = PaletteState(scope: scope)
        let content = NSHostingController(
            rootView: CommandPalette(model: model, state: state) { [weak self] refocus in
                self?.closePalette(refocus: refocus)
            }
        )
        // The window fits itself to the content: the list is ten rows one
        // moment and one row the next.
        content.sizingOptions = [.preferredContentSize]

        let panel = PaletteWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handlePaletteKey(event) ?? false }

        palette = panel
        paletteState = state
        model.isPaletteOpen = true

        paletteTop = window.frame.maxY - 120
        place(panel)

        // A child window follows the main one and does not get lost when apps
        // are switched.
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePalette(refocus: Bool) {
        // Cleared before `orderOut`: that call triggers `windowDidResignKey`
        // itself, and without this the close would go round a second time.
        guard let panel = palette else { return }
        palette = nil
        paletteState = nil
        model.isPaletteOpen = false

        panel.delegate = nil
        window.removeChildWindow(panel)
        panel.orderOut(nil)
        window.makeKeyAndOrderFront(nil)

        if refocus { model.focusActivePane() }
    }

    /// Arrows, Return and escape have to be taken before the text field: to it
    /// they are its own editing commands, and it does not hand them out.
    private func handlePaletteKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: closePalette(refocus: true)
        case 125: paletteState?.move(1)
        case 126: paletteState?.move(-1)
        // The option key travels with the press: on a row that names a session
        // it means "copy the id" instead of "open it".
        case 36, 76: paletteState?.submit?(event.modifierFlags.contains(.option))
        default: return false
        }
        return true
    }

    private func place(_ panel: NSWindow) {
        panel.setFrameOrigin(
            NSPoint(
                x: window.frame.midX - panel.frame.width / 2,
                y: paletteTop - panel.frame.height
            )
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? PaletteWindow else { return }
        place(panel)
    }

    /// A click outside the palette closes it — more familiar than hunting for
    /// where to press.
    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? PaletteWindow != nil else { return }
        closePalette(refocus: false)
    }
}
