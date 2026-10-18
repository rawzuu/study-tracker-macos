import Core
import Engine
import Foundation

/// Šum, zvonky a notifikace k časovači. Aplikace používá `LiveTimerEffects`, testy si volání zapisují.
@MainActor
public protocol TimerEffects: AnyObject {
    /// Po každé změně stavu. `phaseEnd` = konec běžící fáze (`nil` = nic neběží).
    func update(state: TimerState, phaseEnd: Int?, settings: Settings, now: Int)
    /// Přechod časovače (zvonek při přirozeném konci fáze).
    func handle(_ event: TimerEvent, settings: Settings)
    /// Ukázka šumu na 5 s (mimo blok).
    func previewNoise(_ type: NoiseType, volume: Double)
    /// Hraje teď ukázka šumu?
    var isPreviewing: Bool { get }
    /// Ukázka zvonku (Nastavení).
    func previewChime(volume: Double)
    /// Kam poslat tlačítko stisknuté v oznámení.
    func setActionHandler(_ handler: @escaping @MainActor (TimerAction) -> Void)
}

public extension TimerEffects {
    func setActionHandler(_ handler: @escaping @MainActor (TimerAction) -> Void) {}
}

/// Skutečné zvuky a systémové notifikace.
@MainActor
public final class LiveTimerEffects: TimerEffects {
    private let audio: AudioOutput
    private lazy var notifier = BlockNotifier()
    private let notifications: Bool
    private var activity: NSObjectProtocol?
    private var preview: Task<Void, Never>?

    /// - Parameter notifications: `false` bez systémových notifikací (náhledy a testy bez balíčku aplikace).
    public init(notifications: Bool = true) {
        self.audio = AudioOutput()
        self.notifications = notifications
    }

    init(audio: AudioOutput) {
        self.audio = audio
        self.notifications = false
    }

    public var isPreviewing: Bool { preview != nil }

    public func update(state: TimerState, phaseEnd: Int?, settings: Settings, now: Int) {
        // Šum hraje jen během běžícího bloku práce.
        if state.status == .running, state.phase == .work, settings.noiseType != .off {
            endPreview()
            audio.playNoise(settings.noiseType, volume: settings.noiseVolume)
        } else if preview == nil {
            audio.stopNoise()
        }

        if notifications {
            if settings.notifications, let phaseEnd {
                notifier.schedule(at: phaseEnd, phase: state.phase, settings: settings, now: now)
            } else {
                notifier.cancel()
            }
        }

        // Během běžící fáze bez App Nap: zvonek zazní přesně na konci, ne až po probuzení aplikace.
        if state.status == .running {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Běží časovač")
            }
        } else if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    public func handle(_ event: TimerEvent, settings: Settings) {
        guard settings.sound else { return }
        switch event {
        case .workEnded: audio.chime(.workEnd, volume: settings.volume)
        case .breakEnded: audio.chime(.breakEnd, volume: settings.volume)
        case .session, .tooShort: break
        }
    }

    public func previewNoise(_ type: NoiseType, volume: Double) {
        guard type != .off else { return }
        endPreview()
        audio.playNoise(type, volume: volume)
        preview = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            preview = nil
            audio.stopNoise()
        }
    }

    public func setActionHandler(_ handler: @escaping @MainActor (TimerAction) -> Void) {
        // Oznámení musí mít příjemce hned po spuštění – aplikaci mohlo spustit právě tlačítko v oznámení.
        if notifications { notifier.onAction = handler }
    }

    public func previewChime(volume: Double) {
        audio.chime(.workEnd, volume: volume)
    }

    private func endPreview() {
        preview?.cancel()
        preview = nil
    }
}
