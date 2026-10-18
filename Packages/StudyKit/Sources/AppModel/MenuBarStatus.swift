import Engine
import Foundation
import Observation

/// Co ukazuje ikona v horní liště: symbol podle stavu časovače a odpočet běžícího bloku.
/// Text se mění jednou za sekundu jen tehdy, když časovač běží (zarovnaně na začátek úseku);
/// jinak se nepřekresluje vůbec – v klidu nestojí žádné CPU.
@MainActor
@Observable
public final class MenuBarStatus {
    public private(set) var symbol = "graduationcap"
    /// Odpočet nebo uplynulý čas; `nil` = jen ikona.
    public private(set) var title: String?

    @ObservationIgnored private let timer: TimerStore
    @ObservationIgnored private var ticking: Task<Void, Never>?

    public init(timer: TimerStore) {
        self.timer = timer
        observe()
    }

    /// Stav pro daný okamžik (bez tikání – testy).
    func render(at now: Int) {
        let state = timer.state
        let work = state.phase == .work
        switch state.status {
        case .idle:
            symbol = "graduationcap"
            title = nil
        case .ready:
            symbol = work ? "play.circle" : "cup.and.saucer"
            title = nil
        case .running, .paused:
            symbol = state.status == .paused ? "pause.circle" : work ? "book" : "cup.and.saucer"
            title = Format.clock(ms: state.remaining(at: now) ?? state.elapsed(at: now))
        }
    }

    private func observe() {
        withObservationTracking {
            _ = timer.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        ticking?.cancel()
        ticking = nil
        render(at: timer.currentTime())
        let state = timer.state
        guard state.status == .running, let start = state.segmentStart else { return }
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                // Na celou sekundu od začátku úseku – číslice přeskakují přesně.
                let now = Int(Date().timeIntervalSince1970 * 1000)
                let wait = 1000 - (now - start).quotientAndRemainder(dividingBy: 1000).remainder
                try? await Task.sleep(for: .milliseconds(max(1, wait)))
                guard !Task.isCancelled, let self else { return }
                self.render(at: self.timer.currentTime())
            }
        }
    }
}
