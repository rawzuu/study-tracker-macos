import AppKit
import CoreGraphics
import Engine
import Focus
import FocusStore
import OSLog
import ServiceManagement
import WidgetData

/// Proces Strážce: registrace u launchd (`--register`, `--unregister`, `--status`) a běh na pozadí.
///
/// Strážce je aplikace bez sandboxu uvnitř balíčku Study Trackeru. Sandboxovaná aplikace smí registrovat
/// jen sandboxované pomocníky, proto se Strážce registruje sám (`SMAppService.agent` z vlastního balíčku):
/// aplikace ho spustí s `--register` a dál ho drží launchd (po pádu ho spustí znovu). Je vidět
/// v Nastavení systému → Obecné → Položky při přihlášení a jde tam kdykoli vypnout.
@MainActor
public enum GuardRunner {
    private static let log = Logger(subsystem: "cz.rawzuu.studytracker", category: "focus")
    private static var running: Running?

    public static func main() {
        let args = CommandLine.arguments.dropFirst()
        let label = Bundle.main.bundleIdentifier ?? ""
        let agent = SMAppService.agent(plistName: "\(label).plist")
        switch args.first {
        case "--register":
            exit(register(agent) == .enabled ? 0 : 1)
        case "--unregister":
            if hasCommitment() {
                print("locked")
                exit(2)
            }
            do { try agent.unregister() } catch { log.error("Strážce: odregistrace selhala: \(error.localizedDescription, privacy: .public)") }
            print(describe(agent.status))
            exit(0)
        case "--status":
            print(describe(agent.status))
            exit(0)
        default:
            break
        }
        // Spuštěný z aplikace („Zapnout“): jen se zaregistrovat u launchd a skončit – běžící kopii spustí
        // a hlídá launchd. Sandboxovaná aplikace argumenty nepředá, proto se to pozná podle prostředí.
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label else {
            exit(register(agent) == .enabled ? 0 : 1)
        }
        guard let files = FocusFiles.shared(), let store = try? FocusStore(at: files.databaseURL) else {
            log.error("Strážce: sdílený kontejner nedostupný")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        running = Running(files: files, store: store, agent: agent)
        running?.start()
        app.run()
    }

    /// Zaregistruje Strážce u launchd (RunAtLoad ho hned spustí) a výsledek zapíše pro aplikaci.
    private static func register(_ agent: SMAppService) -> GuardRegistration.Status {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        var failure: String?
        if agent.status == .enabled, !others.isEmpty {
            // Už běží.
        } else {
            // Zaregistrovaný, ale neběží (třeba skončil sám): znovu, ať ho launchd spustí.
            if agent.status == .enabled { try? agent.unregister() }
            do { try agent.register() } catch {
                failure = error.localizedDescription
                log.error("Strážce: registrace selhala: \(error.localizedDescription, privacy: .public)")
            }
        }
        let status: GuardRegistration.Status = switch agent.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: failure == nil ? .notRegistered : .failed
        default: .failed
        }
        FocusFiles.shared()?.write(GuardRegistration(status: status, at: Int(Date().timeIntervalSince1970 * 1000), error: failure))
        print(describe(agent.status))
        return status
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    /// Přísný závazek ještě běží – Strážce se sám nevypne (v Nastavení systému to jde, zapíše se porušení).
    private static func hasCommitment() -> Bool {
        guard let files = FocusFiles.shared() else { return false }
        if let report = files.readReport(), report.state(at: Int(Date().timeIntervalSince1970 * 1000)).isLocked { return true }
        return false
    }

    /// Běžící Strážce: systémová oznámení → `Guardian`.
    @MainActor
    final class Running {
        let files: FocusFiles
        let guardian: Guardian
        let agent: SMAppService
        private var observers: [(NotificationCenter, NSObjectProtocol)] = []
        private var loop: Task<Void, Never>?
        private var signalSource: DispatchSourceSignal?

        init(files: FocusFiles, store: FocusStore, agent: SMAppService) {
            self.files = files
            self.agent = agent
            let widgets = WidgetFiles.shared()
            let appId = Bundle.main.object(forInfoDictionaryKey: "STAppBundleId") as? String ?? "cz.rawzuu.studytracker"
            let shield = ShieldWindow(backToStudy: { Running.openApp(appId) })
            guardian = Guardian(Guardian.Dependencies(
                apps: SystemApps(), safari: SystemSafari(),
                shield: shield,
                store: store, files: files,
                readConfig: { files.readConfig() }, readSnapshot: { widgets?.readSnapshot() },
                now: { Int(Date().timeIntervalSince1970 * 1000) }, idleSeconds: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) },
                clock: .current, version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                bootTime: systemBootTime, notifier: SystemNotifier()
            ))
            shield.actions = guardian
        }

        func start() {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
                observeApp(name) { [weak self] info, isActive in
                    if name == NSWorkspace.didLaunchApplicationNotification, !isActive {
                        // Spuštěná na pozadí (třeba při přihlášení): jen schovat nebo ukončit, bez obrazovky.
                        Task { await self?.guardian.refresh() }
                        return
                    }
                    Task { await self?.guardian.appActivated(info) }
                }
            }
            let distributed = DistributedNotificationCenter.default()
            for (center, name) in [(workspace, NSWorkspace.willSleepNotification), (workspace, NSWorkspace.screensDidSleepNotification),
                                   (distributed, Notification.Name("com.apple.screenIsLocked"))] {
                observe(center, name) { [weak self] in self?.guardian.away = true }
            }
            for (center, name) in [(workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.screensDidWakeNotification),
                                   (distributed, Notification.Name("com.apple.screenIsUnlocked"))] {
                observe(center, name) { [weak self] in
                    self?.guardian.away = false
                    Task { await self?.guardian.refresh() }
                }
            }
            let group = files.group
            for name in [FocusFiles.configChanged(group), WidgetFiles.snapshotNotification(group)] {
                FocusFiles.observe(name) { [weak self] in Task { await self?.guardian.refresh() } }
            }
            FocusFiles.observe(FocusFiles.inbox(group)) { [weak self] in Task { await self?.guardian.ingestSafariAttempts() } }
            // Po aktualizaci aplikace: skončit s chybou, launchd spustí nový kód.
            FocusFiles.observe(FocusFiles.restart(group)) { [weak self] in
                Task {
                    await self?.guardian.flush()
                    exit(1)
                }
            }

            // „Vypnout“ v aplikaci: odregistrovat a skončit – jen když neběží přísný zámek.
            FocusFiles.observe(FocusFiles.disable(group)) { [weak self] in
                Task { await self?.disable() }
            }

            // Ukončení (odhlášení, kill): uložit naměřené.
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    _ = Task {
                        await self?.guardian.flush()
                        exit(1)
                    }
                }
            }
            source.resume()
            signalSource = source

            loop = Task { [weak self] in
                await self?.guardian.refresh()
                await self?.guardian.ingestSafariAttempts()
                while !Task.isCancelled {
                    guard let self else { return }
                    await guardian.tick()
                    try? await Task.sleep(for: guardian.tickInterval)
                }
            }
        }

        private func disable() async {
            let t = Int(Date().timeIntervalSince1970 * 1000)
            guard !guardian.state.isLocked else {
                files.write(GuardRegistration(status: .locked, at: t))
                return
            }
            await guardian.flush()
            files.write(GuardRegistration(status: .notRegistered, at: t))
            do { try await agent.unregister() } catch {
                GuardRunner.log.error("Strážce: odregistrace selhala: \(error.localizedDescription, privacy: .public)")
            }
            exit(0)
        }

        private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }))
        }

        /// Aktivace nebo spuštění aplikace s oknem (pomocníci na pozadí se přeskočí).
        private func observeApp(_ name: Notification.Name, _ handler: @escaping @MainActor (RunningApp, Bool) -> Void) {
            let center = NSWorkspace.shared.notificationCenter
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular, let info = SystemApps.info(app) else { return }
                let isActive = app.isActive
                MainActor.assumeIsolated { handler(info, isActive) }
            }))
        }

        static func openApp(_ bundleId: String) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
