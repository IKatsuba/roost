import AppKit
import RoostCore
import UserNotifications

/// System notifications and the dock badge.
///
/// There is exactly one point to them: while the window is in front of you,
/// everything is visible anyway — the queue, the feed, the squares in the tabs.
/// A notification is needed when the human has left for another app while the
/// agent has run into a question and waits in silence.
@MainActor
final class Notifier: NSObject {
    /// A notification was clicked — the pane's id arrives here.
    var onOpen: ((String) -> Void)?

    private var allowed = false

    /// Asks for permission once per launch. A refusal is no trouble: the app
    /// works exactly as it did, only silently.
    func prepare() {
        UNUserNotificationCenter.current().delegate = self
        // `.badge` is not cosmetic: since macOS 11 the dock tile ignores
        // `badgeLabel` unless the badge authorization was asked for.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            granted, _ in
            Task { @MainActor [weak self] in self?.allowed = granted }
        }
    }

    /// Reports a state change — but only the kind worth interrupting for.
    ///
    /// We stay silent while the app is active: the human is looking at the
    /// queue anyway. "Started" and "went quiet" never arrive at all — that is
    /// the background of work, not news.
    func post(paneID: String, project: String, title: String, status: AgentStatus, body: String?) {
        guard allowed, !NSApp.isActive else { return }

        let verb: String
        switch status {
        case .waiting: verb = "needs you"
        case .done: verb = "finished"
        default: return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(title) — \(verb)"
        content.subtitle = project
        if let body { content.body = body }
        // Sound for a question only: finished work can wait until you are back.
        if status == .waiting { content.sound = .default }
        content.userInfo = ["pane": paneID]

        // The identifier is the pane: news about it replaces the previous one
        // instead of piling up as a stack of a dozen identical banners.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: paneID, content: content, trigger: nil)
        )
    }

    /// Clears the banners of a pane the human came to on their own.
    func clear(paneID: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [paneID])
    }

    /// The dock badge — the same number as in the view switch: how many agents
    /// are waiting for an answer. Zero is hidden entirely, otherwise the icon
    /// would be shouting for nothing.
    func badge(waiting: Int) {
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }
}

/// The protocol is declared without `@MainActor`, though it is called from the
/// main queue.
extension Notifier: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let paneID = response.notification.request.content.userInfo["pane"] as? String {
            NSApp.activate(ignoringOtherApps: true)
            onOpen?(paneID)
        }
        completionHandler()
    }
}
