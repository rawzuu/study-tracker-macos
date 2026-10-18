import Core
import Engine
import Foundation
import Observation
import WidgetData

/// Most mezi aplikací a widgety: po změně dat nebo časovače sestaví souhrn (`WidgetSnapshot`), zapíše ho
/// do sdíleného kontejneru a nechá widgety překreslit – jen když se opravdu změnil (widgety mají omezený
/// počet překreslení za den). Příkazy z tlačítek ve widgetech provede se skutečným časovačem.
@MainActor
public final class WidgetBridge {
    private let app: AppStore
    private let timer: TimerStore
    private let advisor: Advisor
    private let files: WidgetFiles?
    private let reload: @MainActor () -> Void
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var hourly: Task<Void, Never>?
    private var started = false
    /// Příkazy z odkazů ve widgetu, které přišly před načtením dat.
    private var queued: [WidgetCommand] = []
    /// Naposledy zapsaný souhrn bez času sestavení.
    private(set) var written: WidgetSnapshot?

    public init(app: AppStore, timer: TimerStore, advisor: Advisor, files: WidgetFiles?, delay: Duration = .seconds(1),
                reload: @escaping @MainActor () -> Void) {
        self.app = app
        self.timer = timer
        self.advisor = advisor
        self.files = files
        self.delay = delay
        self.reload = reload
    }

    /// Po načtení dat: vyřídí příkazy, které přišly, než aplikace běžela, a začne sledovat změny.
    public func start() {
        guard !started, files != nil else { return }
        started = true
        files?.observeCommands { [weak self] in self?.runCommands() }
        runCommands()
        for command in queued { perform(command) }
        queued = []
        observe()
        update()
        // „Co teď?“ se mění i s časem – jednou za hodinu (zápis jen při změně).
        hourly = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                self?.update()
            }
        }
    }

    // MARK: - Souhrn

    /// Souhrn pro widgety z dat a časovače v okamžiku `now`.
    static func snapshot(_ doc: AppDocument, timer: TimerState, mode: TimerMode, recommendations: [Recommendation], now: Int,
                         clock: StudyClock) -> WidgetSnapshot {
        let settings = doc.settings
        let today = clock.startOfDay(now)
        let week = clock.startOfWeek(now)
        let sessions = doc.alive(Session.self)
        let activeSubjects = doc.alive(Subject.self).filter { !$0.archived }
        var subjects: [String: WidgetSnapshot.SubjectStyle] = [:]
        for s in doc.records(Subject.self) { subjects[s.id] = .init(name: s.name, color: s.color) }
        let dayAfter = clock.addDays(today, 2)
        let plan = doc.alive(PlanBlock.self)
            .filter { $0.start >= today && $0.start < dayAfter }
            .sorted { $0.start < $1.start }
            .map { WidgetSnapshot.Block(id: $0.id, subjectId: $0.subjectId, title: $0.title, topic: blockTopics($0.title).first ?? "",
                                        start: $0.start, end: $0.start + $0.durationMin * StudyClock.minute, done: $0.done) }
        let exams = ExamCountdown.upcoming(doc, now: now, clock: clock).prefix(6).compactMap { e in
            clock.parseDayKey(e.date).map { WidgetSnapshot.ExamItem(id: e.id, subjectId: e.subjectId, name: e.name, day: $0, time: e.time) }
        }
        let status: WidgetSnapshot.TimerInfo.Status = switch timer.status {
        case .idle: .idle
        case .ready: .ready
        case .running: .running
        case .paused: .paused
        }
        let info = timer.status == .idle ? WidgetSnapshot.TimerInfo.idle : WidgetSnapshot.TimerInfo(
            status: status, isWork: timer.phase == .work, subjectId: timer.subjectId, topic: timer.topic, modeName: mode.name,
            countsUp: timer.phaseDurationMs == nil, segmentStart: timer.segmentStart, accumulated: timer.accumulated,
            phaseDurationMs: timer.phaseDurationMs, planBlockId: timer.planBlockId
        )
        return WidgetSnapshot(
            generatedAt: now,
            days: [today, clock.addDays(today, 1), dayAfter],
            goalSec: settings.dailyGoalMin * 60,
            studiedSec: Stats.totalSec(Stats.inRange(sessions, from: today, to: now + 1)),
            weekSec: Stats.totalSec(Stats.inRange(sessions, from: week, to: now + 1)),
            weekGoalSec: activeSubjects.reduce(0) { $0 + $1.weeklyGoalMin * 60 },
            week: (0..<7).map { i in Stats.totalSec(Stats.inRange(sessions, from: clock.addDays(week, i), to: clock.addDays(week, i + 1))) },
            todayIndex: clock.weekdayIndex(now),
            streak: Stats.streaks(sessions, restDays: settings.streakRestDays, minMin: settings.streakMinMin, now: now, clock: clock).current,
            subjects: subjects,
            plan: plan,
            exams: Array(exams),
            timer: info,
            nextUp: recommendations.filter { $0.subjectId != nil }.prefix(3).map {
                .init(subjectId: $0.subjectId!, title: $0.title, topic: $0.topic, modeId: $0.modeId, minutes: $0.minutes, reason: $0.reasons.first ?? "")
            }
        )
    }

    /// Sestaví souhrn a zapíše ho, jen když se změnil.
    func update() {
        guard let files, app.phase == .ready else { return }
        let now = app.nowMs
        let snapshot = Self.snapshot(app.document, timer: timer.state, mode: timer.mode, recommendations: advisor.recommendations(now: now),
                                     now: now, clock: app.clock)
        var comparable = snapshot
        comparable.generatedAt = 0
        guard comparable != written else { return }
        do {
            try files.write(snapshot)
            written = comparable
            reload()
        } catch {
            // Bez sdíleného kontejneru (nepodepsané sestavení) widgety prostě nejsou.
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    private func observe() {
        withObservationTracking {
            _ = app.document
            _ = timer.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observe()
            }
        }
    }

    // MARK: - Příkazy z widgetů

    func runCommands() {
        guard let files, app.phase == .ready else { return }
        for command in files.takeCommands(now: app.nowMs) { perform(command) }
        // I když se nic nezměnilo (příkaz už neplatil), widget musí ukázat skutečný stav.
        written = nil
        update()
    }

    /// Odkaz z tlačítka widgetu (aplikace neběžela): provede se po načtení dat.
    public func open(_ command: WidgetCommand) {
        guard started else {
            queued.append(command)
            return
        }
        perform(command)
        written = nil
        update()
    }

    /// Aplikace končí – widgety pak tlačítky aplikaci otevřou.
    public func markStopped() {
        guard let files, var s = files.readSnapshot() else { return }
        s.appRunning = false
        try? files.write(s)
        reload()
    }

    private func perform(_ command: WidgetCommand) {
        let actions = StudyActions(store: app, timer: timer, advisor: advisor)
        timer.refresh()
        switch command.action {
        case .pause: _ = try? actions.pause()
        case .resume: _ = try? actions.resume()
        case .finish: _ = try? actions.finish()
        case .stop: _ = try? actions.stop()
        case .next: timer.perform(.startWork)
        case .start: _ = try? actions.start(subjectId: command.subjectId, topic: command.topic, modeId: command.modeId)
        }
    }
}
