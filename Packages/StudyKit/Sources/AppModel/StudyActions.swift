import Core
import Engine
import Foundation

/// Akce pro Zkratky a Siri (App Intents v aplikaci jsou jen tenká vrstva nad tímhle). Odpovědi jsou
/// věty v češtině – Zkratky je ukážou nebo přečtou.
@MainActor
public struct StudyActions {
    public enum Failure: Error, Equatable, LocalizedError {
        case notLoaded
        case noSubject
        case blockRunning(String)
        case notRunning
        case cannotStart

        public var errorDescription: String? {
            switch self {
            case .notLoaded: "Data Study Trackeru se nepodařilo načíst."
            case .noSubject: "Nejdřív přidej předmět ve Study Trackeru."
            case .blockRunning(let name): "Blok už běží: \(name). Nejdřív ho ukonči."
            case .notRunning: "Časovač neběží."
            case .cannotStart: "Blok se nepodařilo spustit."
            }
        }
    }

    public struct Choice: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
    }

    let store: AppStore
    let timer: TimerStore
    let advisor: Advisor

    public init(store: AppStore, timer: TimerStore, advisor: Advisor) {
        self.store = store
        self.timer = timer
        self.advisor = advisor
    }

    /// Počká na načtení dat (aplikaci mohla spustit právě zkratka).
    public func ready() async throws(Failure) {
        for _ in 0..<200 where store.phase == .loading {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard store.phase == .ready else { throw .notLoaded }
        timer.refresh()
    }

    // MARK: - Výběr

    public var subjects: [Choice] {
        store.document.alive(Subject.self).filter { !$0.archived }.map { Choice(id: $0.id, name: $0.name) }
    }

    public var modes: [Choice] {
        timer.modes.map { Choice(id: $0.id, name: $0.name) }
    }

    // MARK: - Časovač

    /// Spustí blok: zadaný předmět, jinak doporučení „Co teď?“, jinak naposledy použitý předmět.
    @discardableResult
    public func start(subjectId: String?, topic: String?, modeId: String?) throws(Failure) -> String {
        let state = timer.state
        if state.phase == .work && (state.status == .running || state.status == .paused) {
            throw .blockRunning(subjectName(state.subjectId))
        }
        let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if state.phase != .work && state.status != .idle {
            // Během pauzy: bez zadání pokračuje série dalším blokem, jinak začne nová.
            timer.skip()
            if subjectId == nil && topic == nil && modeId == nil {
                if timer.state.status == .ready { timer.start() }
                return try started()
            }
        }
        if let subjectId {
            guard store.document.record(Subject.self, id: subjectId) != nil else { throw .noSubject }
            timer.setup(TimerSetup(subjectId: subjectId, topic: topic ?? "", modeId: modeId))
        } else if let top = advisor.recommendations(now: store.nowMs).first(where: { $0.subjectId != nil }) {
            timer.setup(TimerSetup(subjectId: top.subjectId, topic: topic ?? top.topic, modeId: modeId ?? top.modeId, planBlockId: top.planBlockId))
        } else if !state.subjectId.isEmpty, store.document.record(Subject.self, id: state.subjectId) != nil {
            timer.setup(TimerSetup(topic: topic, modeId: modeId))
        } else {
            throw .noSubject
        }
        timer.start()
        return try started()
    }

    private func started() throws(Failure) -> String {
        guard timer.state.status == .running, timer.state.phase == .work else { throw .cannotStart }
        let mode = timer.mode
        let length = mode.workMin.map { " · \(Int($0.rounded())) min" } ?? ""
        let topicText = timer.state.topic.isEmpty ? "" : " – \(timer.state.topic)"
        return "Začínám: \(subjectName(timer.state.subjectId))\(topicText)\(length) (\(mode.name))."
    }

    public func pause() throws(Failure) -> String {
        guard timer.state.status == .running else { throw .notRunning }
        timer.pause()
        return "Pozastaveno – \(remainingText)."
    }

    public func resume() throws(Failure) -> String {
        guard timer.state.status == .paused else { throw .notRunning }
        timer.resume()
        return "Pokračuji – \(remainingText)."
    }

    /// „Hotovo“: uloží blok a jde na pauzu.
    public func finish() throws(Failure) -> String {
        let state = timer.state
        guard state.phase == .work, state.status == .running || state.status == .paused, timer.mode.kind != .stopwatch else { throw .notRunning }
        let name = subjectName(state.subjectId)
        timer.finishWork()
        return "Blok uložen (\(name)). Dej si pauzu."
    }

    /// „Ukončit“: uloží rozpracovaný blok a ukončí sérii.
    public func stop() throws(Failure) -> String {
        let state = timer.state
        guard state.status != .idle else { throw .notRunning }
        let saving = state.phase == .work && (state.status == .running || state.status == .paused)
        if saving { timer.stop() } else { timer.discard() }
        return saving ? "Ukončeno, blok je uložený." : "Série ukončena."
    }

    // MARK: - Dotazy

    /// „Co se mám teď učit?“
    public func whatNow() -> String {
        guard let top = advisor.recommendations(now: store.nowMs).first(where: { $0.subjectId != nil }) else {
            return "Teď není co doporučit – přidej předměty, cíle nebo zkoušky."
        }
        let reasons = top.reasons.prefix(2).joined(separator: ", ")
        return "\(subjectName(top.subjectId ?? ""))\(top.context.map { ": \($0)" } ?? ""), \(top.minutes) min" + (reasons.isEmpty ? "." : " – \(reasons).")
    }

    /// Kolik je dnes odučeno (minuty) a věta s cílem.
    public func today() -> (minutes: Int, text: String) {
        let now = store.nowMs
        let state = Stats.totalSec(Stats.inRange(store.document.alive(Session.self), from: store.clock.startOfDay(now), to: now + 1))
        let goal = store.document.settings.dailyGoalMin * 60
        var text = "Dnes \(Format.duration(state))"
        if goal > 0 {
            text += state >= goal ? " – denní cíl \(Format.duration(goal)) splněný." : " z \(Format.duration(goal)), zbývá \(Format.duration(goal - state))."
        } else {
            text += "."
        }
        return (state / 60, text)
    }

    // MARK: - Pomocné

    private var remainingText: String {
        let s = timer.state
        let now = timer.currentTime()
        if let left = s.remaining(at: now) { return "zbývá \(Format.clock(ms: left))" }
        return "uběhlo \(Format.clock(ms: s.elapsed(at: now)))"
    }

    private func subjectName(_ id: String) -> String {
        store.document.record(Subject.self, id: id)?.name ?? "Bez předmětu"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
