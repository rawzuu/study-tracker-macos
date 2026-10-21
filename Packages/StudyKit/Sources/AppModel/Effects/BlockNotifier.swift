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
    nonisolated static let requestId = "study-timer"

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
        out.insert(UNNotificationCategory(identifier: awayCategory, actions: [TimerAction.resume, .countAway].map {
            UNNotificationAction(identifier: $0.identifier, title: $0.title, options: [])
        }, intentIdentifiers: []))
        return out
    }()

    static let awayId = "study-away"
    static let awayCategory = "st.away"

    /// Blok se pozastavil, protože uživatel odešel od Macu – po návratu nabídne pokračovat (s pauzou i bez).
    func notifyAway(minutes: Int) {
        let duration = Format.duration(minutes * 60)
        post(id: Self.awayId, title: "Blok je pozastavený",
             body: "Byl jsi pryč \(duration) – ten čas se nezapočítal. Učil ses mimo Mac? Započítej ho.", category: Self.awayCategory)
    }

    /// Okamžité oznámení; kliknutí otevře `url` (stránku aplikace).
    func post(id: String, title: String, body: String, category: String? = nil, url: URL? = nil) {
        Task {
            guard await authorize() else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category { content.categoryIdentifier = category }
            if let url { content.userInfo = ["url": url.absoluteString] }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

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
        // Konec bloku ohlásí v aplikaci zvonek; ostatní oznámení (nepřítomnost, souhrn) jsou vidět vždy.
        guard notification.request.identifier == Self.requestId else { return [.banner, .list] }
        return await MainActor.run { NSApp.isActive } ? [] : [.banner, .list]
    }

    /// Tlačítko v oznámení → časovač. Klik na samotné oznámení otevře aplikaci (to udělá systém),
    /// případně na stránce z odkazu v oznámení.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let action = TimerAction(identifier: response.actionIdentifier) {
            await MainActor.run { self.onAction?(action) }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link) {
            // Odkaz na stránku (`studytracker://statistiky`) zpracuje aplikace sama.
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
        }
    }
}
