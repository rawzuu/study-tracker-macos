import AppKit
import CoreGraphics
import Engine

/// Automatická pauza, když uživatel odejde od Macu: po nastavené době bez myši a klávesnice (nebo hned
/// při zamčení obrazovky či uspání) se běžící blok učení pozastaví zpětně k poslední aktivitě. Po návratu
/// oznámení nabídne pokračovat – s dobou nepřítomnosti, nebo bez ní.
///
/// Kontroluje se jen během běžícího bloku (a po pozastavení, dokud se uživatel nevrátí); v klidu nic neběží.
@MainActor
public final class AwayMonitor {
    private let timer: TimerStore
    private let prefs: MacPreferences
    private let idleSeconds: () -> Double
    private let now: () -> Int
    private let interval: Duration
    private var polling: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false

    /// Za kolik sekund bez vstupu se uživatel bere jako „zpátky u Macu“ (pohnul myší, psal).
    static let returnedBelow: Double = 10

    public init(timer: TimerStore, prefs: MacPreferences, interval: Duration = .seconds(15),
                idleSeconds: @escaping () -> Double = AwayMonitor.systemIdleSeconds,
                now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.timer = timer
        self.prefs = prefs
        self.interval = interval
        self.idleSeconds = idleSeconds
        self.now = now
    }

    public func start() {
        guard !started else { return }
        started = true
        observeChanges({ [weak self] in
            _ = self?.timer.state
            _ = self?.prefs.awayMinutes
        }, react: { [weak self] in self?.update() })
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for (center, name) in [(workspace, NSWorkspace.willSleepNotification), (workspace, NSWorkspace.screensDidSleepNotification),
                               (distributed, Notification.Name("com.apple.screenIsLocked"))] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.left() }
            }))
        }
        for (center, name) in [(workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.screensDidWakeNotification),
                               (distributed, Notification.Name("com.apple.screenIsUnlocked"))] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }))
        }
        update()
    }

    /// Sekundy od posledního pohybu myší nebo stisku klávesy (celý systém).
    public nonisolated static func systemIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: - Interní

    private var isWorking: Bool { timer.state.status == .running && timer.state.phase == .work }
    private var awaitingReturn: Bool { timer.away?.until == nil && timer.away != nil }

    /// Kontrola běží jen během bloku (s nastavenou nečinností) nebo když se čeká na návrat.
    private func update() {
        let needed = (isWorking && prefs.awayMinutes > 0) || awaitingReturn
        guard needed else {
            polling?.cancel()
            polling = nil
            return
        }
        guard polling == nil else { return }
        polling = Task { [weak self, interval] in
            while !Task.isCancelled {
                // Při čekání na návrat častěji – oznámení má přijít hned, jak se uživatel vrátí.
                let wait = self?.awaitingReturn == true ? Duration.seconds(3) : interval
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                check()
            }
        }
    }

    /// Jedna kontrola: odešel? vrátil se?
    func check() {
        let idle = idleSeconds()
        let t = now()
        if awaitingReturn {
            if idle < Self.returnedBelow { returned(at: t) }
        } else if isWorking, prefs.awayMinutes > 0, idle >= Double(prefs.awayMinutes * 60) {
            timer.pauseAway(since: t - Int(idle * 1000))
        }
    }

    /// Zamčení obrazovky nebo uspání Macu.
    func left() {
        guard prefs.awayOnLock, isWorking else { return }
        timer.pauseAway(since: now())
    }

    private func returned(at t: Int) {
        guard let minutes = timer.awayReturned(at: t) else { return }
        if minutes >= 1 {
            timer.effects?.awayPaused(minutes: minutes)
        } else {
            // Rychlé zamčení a odemčení: pokračovat, jako by se nic nestalo.
            timer.resumeCountingAway()
        }
        update()
    }
}
