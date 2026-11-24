import AppKit
import RelevoCode
import UserNotifications

struct Banner: Equatable {
    let session: Session.ID
    let title: String
    let subtitle: String
    let body: String
    let sound: Bool
}

@MainActor
protocol Notifier: AnyObject {
    var onOpen: ((Session.ID) -> Void)? { get set }
    func authorize()
    func post(_ banner: Banner)
    func withdraw(_ session: Session.ID)
}

@MainActor
final class SilentNotifier: Notifier {
    var onOpen: ((Session.ID) -> Void)?
    private(set) var posted: [Banner] = []
    private(set) var withdrawn: [Session.ID] = []

    func authorize() {}

    func post(_ banner: Banner) {
        posted.append(banner)
    }

    func withdraw(_ session: Session.ID) {
        withdrawn.append(session)
    }
}

@MainActor
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    var onOpen: ((Session.ID) -> Void)?
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func authorize() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ banner: Banner) {
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.subtitle = banner.subtitle
        content.body = banner.body
        content.sound = banner.sound ? .default : nil
        content.userInfo = ["session": banner.session.uuidString]
        center.add(UNNotificationRequest(identifier: banner.session.uuidString, content: content, trigger: nil))
    }

    func withdraw(_ session: Session.ID) {
        center.removeDeliveredNotifications(withIdentifiers: [session.uuidString])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let value = response.notification.request.content.userInfo["session"] as? String,
              let session = UUID(uuidString: value) else { return }
        await MainActor.run {
            onOpen?(session)
        }
    }
}
