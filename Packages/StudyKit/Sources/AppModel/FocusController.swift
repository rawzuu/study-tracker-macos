import AppKit
import Engine
import Focus
import FocusStore
import Foundation
import Observation
import OSLog
import SafariServices

/// Soustředění v aplikaci: nastavení (zapisuje do sdíleného kontejneru), stav Strážce a jeho zapnutí.
/// Vynucuje Strážce – samostatný proces, takže blokování platí i po ukončení aplikace.
@MainActor
@Observable
public final class FocusController {
    public enum GuardStatus: Equatable, Sendable {
        /// Build bez sdíleného kontejneru nebo bez Strážce (testy, nepodepsaný build).
        case unavailable
        case off
        case starting
        /// Zaregistrovaný, ale macOS čeká na povolení v Položkách při přihlášení.
        case needsApproval
        case stopping
        case running
    }

    public private(set) var config: FocusConfig
    public private(set) var report: GuardReport?
    public private(set) var status: GuardStatus = .off
    /// Hláška pro uživatele (Strážce nejde vypnout, nepovedlo se ho spustit…).
    public var message: String?
    /// Poslední výsledek zapnutí/vypnutí (zapisuje Strážce).
    public private(set) var registration: GuardRegistration?

    @ObservationIgnored private let files: FocusFiles?
    @ObservationIgnored private let guardURL: URL?
    @ObservationIgnored private let guardId: String
    @ObservationIgnored private let safariExtensionId: String
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored public private(set) lazy var store: FocusStore? = files.flatMap { try? FocusStore(at: $0.databaseURL) }
    private nonisolated static let log = Logger(subsystem: "cz.rawzuu.studytracker", category: "focus")

    public init(bundle: Bundle = .main, files: FocusFiles? = FocusFiles.shared()) {
        self.files = files
        guardId = bundle.object(forInfoDictionaryKey: "STGuardBundleId") as? String ?? ""
        safariExtensionId = bundle.object(forInfoDictionaryKey: "STSafariExtensionId") as? String ?? ""
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let url = bundle.bundleURL.appending(path: "Contents/Library/LoginItems/StudyTrackerGuard.app")
        guardURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        config = files?.readConfig() ?? .empty
        report = files?.readReport()
        if files == nil || guardURL == nil || guardId.isEmpty || guardId.hasPrefix("$") { status = .unavailable }
    }

    public var isAvailable: Bool { status != .unavailable }

    public func start() {
        guard !started, let files, isAvailable else { return }
        started = true
        FocusFiles.observe(FocusFiles.dataChanged(files.group)) { [weak self] in self?.reload() }
        reload()
        // Strážce ze starší verze aplikace (po aktualizaci): ať se spustí znovu s novým kódem.
        if let report, report.guardVersion != appVersion {
            if isGuardRunning { files.postRestart() }
            // Verze 0.12.0 se u launchd nezaregistrovala (běžela jen ručně spuštěná kopie) – zapnout znovu správně.
            if files.readRegistration() == nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.enableGuard()
                }
            }
        }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.reload()
            }
        }
    }

    @ObservationIgnored private var simulatesGuard = false

    /// Jen UI testy: chovat se, jako by Strážce běžel (ovládání je povolené; nic se neblokuje, Strážce se nespouští).
    public func simulateGuard() {
        simulatesGuard = true
        status = .running
    }

    private var isGuardRunning: Bool { simulatesGuard || !NSRunningApplication.runningApplications(withBundleIdentifier: guardId).isEmpty }

    func reload() {
        guard let files, isAvailable else { return }
        report = files.readReport()
        registration = files.readRegistration()
        guard status != .starting, status != .stopping else { return }
        status = isGuardRunning ? .running : registration?.status == .requiresApproval ? .needsApproval : .off
    }

    /// Stav pravidel teď (ze zprávy Strážce; bez Strážce nic neplatí).
    public func state(at t: Int) -> ActiveFocus {
        status == .running ? report?.state(at: t) ?? ActiveFocus() : ActiveFocus()
    }

    /// Rozšíření Safari se ozvalo v posledních minutách.
    public func extensionActive(at t: Int) -> Bool {
        (files?.extensionSeenAt()).map { t - $0 < 10 * 60_000 } ?? false
    }

    // MARK: - Nastavení

    public func update(_ change: (inout FocusConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        config = next
        do { try files?.write(next) } catch { Self.log.error("Soustředění: nastavení se nepovedlo uložit: \(error.localizedDescription, privacy: .public)") }
    }

    /// Ruční zámek od teď na `minutes` (všechny seznamy, nebo vybrané); přísnost `nil` = podle seznamů.
    public func lock(listIds: [String]? = nil, minutes: Int, strictness: Strictness?, now: Int) {
        update {
            $0.locks.removeAll { $0.end <= now }
            $0.locks.append(FocusLock(listIds: listIds ?? $0.lists.map(\.id), start: now, end: now + minutes * 60_000, strictness: strictness))
        }
    }

    /// Zmrazí celý Mac od teď na `minutes` (povolené aplikace a přísnost podle nastavení Zmrazení).
    public func freeze(minutes: Int, now: Int) {
        update {
            $0.locks.removeAll { $0.end <= now }
            $0.locks.append(FocusLock(listIds: [], start: now, end: now + minutes * 60_000, freeze: true))
        }
    }

    // MARK: - Export a import seznamů

    /// Seznamy jako JSON (sdílení mezi Macy nebo se spolužáky). Hesla odemykání se neexportují.
    public nonisolated static func exportLists(_ lists: [FocusList]) throws -> Data {
        let clean = lists.map { list -> FocusList in
            var l = list
            l.strictness.password = nil
            return l
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ListsFile(lists: clean))
    }

    /// Načte seznamy z JSON exportu, nebo z prostého textu (weby po řádcích → jeden nový seznam).
    /// Vždy jako nové seznamy (nové id), stávající se nemění.
    public nonisolated static func importLists(_ data: Data, name: String) -> [FocusList] {
        if let file = try? JSONDecoder().decode(ListsFile.self, from: data) {
            return file.lists.map { list in
                var l = list
                l.id = UUID().uuidString
                l.freeze = false
                return l
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        let sites = text.split(whereSeparator: { $0.isNewline || $0.isWhitespace || $0 == "," || $0 == ";" })
            .compactMap { SiteRule(String($0))?.text }
        var seen = Set<String>()
        let unique = sites.filter { seen.insert($0).inserted }
        return unique.isEmpty ? [] : [FocusList(name: name, sites: unique)]
    }

    public func importLists(_ data: Data, name: String) -> Int {
        let lists = Self.importLists(data, name: name)
        if !lists.isEmpty { update { $0.lists += lists } }
        return lists.count
    }

    struct ListsFile: Codable {
        var format = "study-tracker-focus-lists"
        var version = 1
        var lists: [FocusList]
    }

    /// Nový seznam ze šablony (vrací jeho id).
    @discardableResult
    public func addList(from template: FocusTemplates.Template) -> String {
        let list = template.makeList()
        update { $0.lists.append(list) }
        return list.id
    }

    // MARK: - Strážce

    /// Zapne Strážce: spustí ho, on se zaregistruje u launchd a skončí; launchd pak spustí kopii, která běží
    /// na pozadí (i po restartu Macu, po pádu znovu). Čeká, až se ozve, jinak řekne proč ne.
    public func enableGuard() {
        guard let guardURL else { return }
        status = .starting
        message = nil
        if config == .empty { update { $0.enabled = true } }
        let since = Date().timeIntervalSince1970 * 1000
        let open = NSWorkspace.OpenConfiguration()
        open.createsNewApplicationInstance = true
        open.activates = false
        open.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: guardURL, configuration: open) { _, error in
            if let error { Self.log.error("Strážce se nespustil: \(error.localizedDescription, privacy: .public)") }
        }
        Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let files else { return }
                let registration = files.readRegistration().flatMap { Double($0.at) >= since - 1000 ? $0 : nil }
                if let registration, registration.status != .enabled {
                    finishStarting(registration)
                    return
                }
                if let report = files.readReport(), Double(report.generatedAt) >= since, isGuardRunning {
                    status = .running
                    reload()
                    return
                }
            }
            self?.finishStarting(nil)
        }
    }

    private func finishStarting(_ registration: GuardRegistration?) {
        status = .off
        self.registration = registration ?? files?.readRegistration()
        switch registration?.status {
        case .requiresApproval:
            status = .needsApproval
        case .failed:
            message = "Strážce se nepovedlo zapnout: \(registration?.error ?? "neznámá chyba"). Zkus to znovu, případně restartuj Mac."
        default:
            message = "Strážce se nespustil. Zkontroluj Nastavení systému → Obecné → Položky při přihlášení (Study Tracker musí být zapnutý)."
        }
    }

    /// Vypne Strážce (sám se odregistruje u launchd a skončí). Během přísného zámku odmítne.
    public func disableGuard(now: Int) {
        guard let files else { return }
        if state(at: now).isLocked {
            message = "Běží přísný zámek – Strážce do jeho konce vypnout nejde."
            return
        }
        status = .stopping
        message = nil
        files.postDisable()
        Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if !isGuardRunning { break }
                if files.readRegistration()?.status == .locked {
                    message = "Běží přísný zámek – Strážce do jeho konce vypnout nejde."
                    break
                }
            }
            guard let self else { return }
            status = .off
            reload()
            if status == .running, message == nil { message = "Strážce se nevypnul. Jde vypnout v Nastavení systému → Obecné → Položky při přihlášení." }
        }
    }

    // MARK: - Souhrn

    /// Věta Soustředění do pondělního souhrnu za týden `[from, to)`.
    public func weeklyLine(from: Int, to: Int, clock: StudyClock) async -> String? {
        guard let store else { return nil }
        let last = clock.addDays(to, -1)
        guard let usage = try? await store.usage(fromDay: clock.dayKey(from), toDay: clock.dayKey(last)),
              let events = try? await store.events(from: from, to: to) else { return nil }
        return FocusStats.make(usage: usage, events: events, days: 7, now: last, clock: clock).weeklyLine
    }

    // MARK: - Systémová nastavení

    public func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: safariExtensionId) { _ in }
    }

    public func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    public func openLoginItemsSettings() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
