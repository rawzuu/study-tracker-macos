import AppKit
import Engine
import UserNotifications

/// Systémová notifikace na konec bloku nebo pauzy. Naplánuje se dopředu na okamžik konce fáze,
/// takže přijde včas, i když je aplikace na pozadí. Když je aplikace vpředu, stačí zvonek (jako na webu).
@MainActor
final class BlockNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let requestId = "study-timer"

    private let center = UNUserNotificationCenter.current()
    private var scheduled: (at: Int, phase: TimerPhase)?
    /// `nil` = ještě se neptalo.
    private var allowed: Bool?

    override init() {
        super.init()
        center.delegate = self
    }

    func schedule(at deadline: Int, phase: TimerPhase, now: Int) {
        if let s = scheduled, s.at == deadline, s.phase == phase { return }
        scheduled = (deadline, phase)
        let title = phase == .work ? "Blok práce hotový" : "Pauza skončila"
        let body = phase == .work ? "Dej si pauzu – zasloužíš si ji." : "Jdeme na další blok."
        let seconds = max(1, Double(deadline - now) / 1000)
        Task {
            guard await authorize() else { return }
            // Mezitím se fáze mohla změnit (pauza, ukončení) – pak už nic neplánovat.
            guard let s = scheduled, s.at == deadline, s.phase == phase else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: Self.requestId, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            )
            try? await center.add(request)
        }
    }

    func cancel() {
        guard scheduled != nil else { return }
        scheduled = nil
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestId])
    }

    private func authorize() async -> Bool {
        if let allowed { return allowed }
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        allowed = granted
        return granted
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { NSApp.isActive } ? [] : [.banner, .list]
    }
}
