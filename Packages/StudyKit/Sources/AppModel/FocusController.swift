import AppKit
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
        case running
    }

    public private(set) var config: FocusConfig
    public private(set) var report: GuardReport?
    public private(set) var status: GuardStatus = .off
    /// Hláška pro uživatele (Strážce nejde vypnout, nepovedlo se ho spustit…).
    public var message: String?

    @ObservationIgnored private let files: FocusFiles?
    @ObservationIgnored private let guardURL: URL?
    @ObservationIgnored private let guardId: String
    @ObservationIgnored private let safariExtensionId: String
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored public private(set) lazy var store: FocusStore? = files.flatMap { try? FocusStore(at: $0.databaseURL) }
    private static let log = Logger(subsystem: "cz.rawzuu.studytracker", category: "focus")

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
        if let report, report.guardVersion != appVersion, isGuardRunning { files.postRestart() }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.reload()
            }
        }
    }

    private var isGuardRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: guardId).isEmpty }

    func reload() {
        guard let files, isAvailable else { return }
        report = files.readReport()
        if status != .starting || isGuardRunning { status = isGuardRunning ? .running : .off }
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

    /// Nový seznam ze šablony (vrací jeho id).
    @discardableResult
    public func addList(from template: FocusTemplates.Template) -> String {
        let list = template.makeList()
        update { $0.lists.append(list) }
        return list.id
    }

    // MARK: - Strážce

    /// Zapne Strážce: spustí ho s `--register`, sám se zaregistruje u launchd a dál běží na pozadí.
    public func enableGuard() {
        guard let guardURL else { return }
        status = .starting
        message = nil
        if config == .empty { update { $0.enabled = true } }
        let open = NSWorkspace.OpenConfiguration()
        open.arguments = ["--register"]
        open.createsNewApplicationInstance = true
        open.activates = false
        open.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: guardURL, configuration: open) { _, error in
            if let error { Self.log.error("Strážce se nespustil: \(error.localizedDescription, privacy: .public)") }
        }
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if isGuardRunning, files?.readReport().map({ Date().timeIntervalSince1970 * 1000 - Double($0.generatedAt) < 10_000 }) == true {
                    status = .running
                    reload()
                    return
                }
            }
            self?.status = .off
            self?.message = "Strážce se nespustil. Zkontroluj Nastavení systému → Obecné → Položky při přihlášení."
        }
    }

    /// Vypne Strážce (odregistruje ho). Během přísného zámku odmítne.
    public func disableGuard(now: Int) {
        guard let guardURL else { return }
        if state(at: now).isLocked {
            message = "Běží přísný zámek – Strážce do jeho konce vypnout nejde."
            return
        }
        let open = NSWorkspace.OpenConfiguration()
        open.arguments = ["--unregister"]
        open.createsNewApplicationInstance = true
        open.activates = false
        open.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: guardURL, configuration: open) { _, _ in }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.reload()
        }
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
