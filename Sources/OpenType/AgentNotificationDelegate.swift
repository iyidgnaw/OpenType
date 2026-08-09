import Foundation
import UserNotifications

/// Small standalone `UNUserNotificationCenterDelegate` for the "Agent
/// finished" completion notification (see `AppModel.postAgentCompletionNotification`).
/// Kept as its own `NSObject` subclass rather than making `AppModel` itself
/// conform, because `UNUserNotificationCenterDelegate` refines
/// `NSObjectProtocol` and `AppModel` deliberately stays a plain
/// `ObservableObject` (no `NSObject` base) like the rest of this codebase's
/// collaborators. Delegate callbacks arrive on an arbitrary thread, so both
/// methods hop back to the main actor before touching anything.
final class AgentNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Fired when the user taps/clicks a delivered "Agent finished" banner,
    /// with the `AgentRunRecord.id` that notification was about. `AppModel`
    /// wires this to `focusAgentRun(_:)`, which opens the main app window
    /// (Part A) and scrolls the Task List panel to that run.
    var onAgentRunTapped: (@MainActor (UUID) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let idString = response.notification.request.content.userInfo["agentRunID"] as? String
        let handler = onAgentRunTapped
        Task { @MainActor in
            if let idString, let id = UUID(uuidString: idString) {
                handler?(id)
            }
        }
        completionHandler()
    }

    /// Without this, macOS suppresses the banner entirely while OpenType is
    /// the frontmost app — but the whole point of this notification is to
    /// tell the user about a background task that finished while they moved
    /// on to something else, which may well still be OpenType itself.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
