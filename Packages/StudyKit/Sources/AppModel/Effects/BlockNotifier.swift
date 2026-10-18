import AppKit
import Core
import Engine
import UserNotifications

/// Systémová notifikace na konec bloku nebo pauzy. Naplánuje se dopředu na okamžik konce fáze,
/// takže přijde včas, i když je aplikace na pozadí. Když je aplikace vpředu, stačí zvonek (jako na webu).
/// Má tlačítka (v „Možnostech“): hodnocení soustředění, pauza, další blok, ukončení série – bez
/// přepínání do aplikace.
@MainActor
final class BlockNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let requestId = "study-timer"

    private let center = UNUserNotificationCenter.current()
    private var scheduled: (at: Int, phase: TimerPhase, category: String)?
    /// `nil` = ještě se neptalo.
    private var allowed: Bool?
    /// Kam jde stisknuté tlačítko (časovač).
    var onAction: (@MainActor (TimerAction) -> Void)?

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    /// Tlačítka podle toho, co po konci fáze nastane: pauza a další blok se spouští samy, nebo čekají.
    static func actions(phase: TimerPhase, autoBreak: Bool, autoWork: Bool, rating: Bool) -> [TimerAction] {
        if phase == .work {
            return (autoBreak ? [.skipBreak] : [.startBreak, .skipBreak]) + [.endSeries] + (rating ? (1...5).reversed().map { .focus($0) } : [])
        }
        return (autoWork ? [] : [.startWork]) + [.endSeries]
    }

    static func category(phase: TimerPhase, autoBreak: Bool, autoWork: Bool, rating: Bool) -> String {
        phase == .work ? "st.work.\(autoBreak ? "auto" : "wait").\(rating ? "rate" : "plain")" : "st.break.\(autoWork ? "auto" : "wait")"
    }

    private static let categories: Set<UNNotificationCategory> = {
        var out: Set<UNNotificationCategory> = []
        for autoBreak in [false, true] {
            for rating in [false, true] {
                out.insert(category(.work, autoBreak: autoBreak, autoWork: false, rating: rating))
            }
        }
        for autoWork in [false, true] { out.insert(category(.short, autoBreak: false, autoWork: autoWork, rating: false)) }
        return out
    }()

    private static func category(_ phase: TimerPhase, autoBreak: Bool, autoWork: Bool, rating: Bool) -> UNNotificationCategory {
        let actions = actions(phase: phase, autoBreak: autoBreak, autoWork: autoWork, rating: rating).map { a in
            // Bez přepnutí do aplikace – všechno se dá udělat rovnou z oznámení.
            UNNotificationAction(identifier: a.identifier, title: a.title, options: [])
        }
        return UNNotificationCategory(identifier: category(phase: phase, autoBreak: autoBreak, autoWork: autoWork, rating: rating),
                                      actions: actions, intentIdentifiers: [])
    }

    func schedule(at deadline: Int, phase: TimerPhase, settings: Settings, now: Int) {
        let category = Self.category(phase: phase, autoBreak: settings.autoStartBreaks, autoWork: settings.autoStartWork, rating: settings.askFocusRating)
        if let s = scheduled, s.at == deadline, s.phase == phase, s.category == category { return }
        scheduled = (deadline, phase, category)
        let title = phase == .work ? "Blok hotový" : "Pauza skončila"
        let body = switch (phase == .work, phase == .work ? settings.autoStartBreaks : settings.autoStartWork) {
        case (true, true): "Pauza běží. Jak šlo soustředění?"
        case (true, false): "Dej si pauzu – zasloužíš si ji."
        case (false, true): "Další blok už běží."
        case (false, false): "Jdeme na další blok."
        }
        let seconds = max(1, Double(deadline - now) / 1000)
        Task {
            guard await authorize() else { return }
            // Mezitím se fáze mohla změnit (pauza, ukončení) – pak už nic neplánovat.
            guard let s = scheduled, s.at == deadline, s.phase == phase else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
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

    /// Tlačítko v oznámení → časovač. Klik na samotné oznámení jen otevře aplikaci (to udělá systém).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let action = TimerAction(identifier: response.actionIdentifier) else { return }
        await MainActor.run { self.onAction?(action) }
    }
}
