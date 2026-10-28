import Engine
import Focus
import FocusStore
import Foundation
import OSLog
import WidgetData

/// Strážce Soustředění: vyhodnocuje pravidla, schovává nebo ukončuje zakázané aplikace, hlídá adresu
/// v Safari (pojistka k rozšíření), zapisuje pokusy a měří čas u obrazovky. Běží jako vlastní proces na
/// pozadí, takže blokování platí i bez spuštěné aplikace.
@MainActor
public final class Guardian {
    public struct Dependencies {
        public var apps: any AppControl
        public var safari: any SafariControl
        public var shield: any ShieldControl
        public var store: FocusStore
        public var files: FocusFiles?
        public var readConfig: () -> FocusConfig?
        public var readSnapshot: () -> WidgetSnapshot?
        public var now: () -> Int
        public var idleSeconds: () -> Double
        public var clock: StudyClock
        public var version: String

        public init(apps: any AppControl, safari: any SafariControl, shield: any ShieldControl, store: FocusStore, files: FocusFiles?,
                    readConfig: @escaping () -> FocusConfig?, readSnapshot: @escaping () -> WidgetSnapshot?,
                    now: @escaping () -> Int, idleSeconds: @escaping () -> Double, clock: StudyClock, version: String) {
            self.apps = apps
            self.safari = safari
            self.shield = shield
            self.store = store
            self.files = files
            self.readConfig = readConfig
            self.readSnapshot = readSnapshot
            self.now = now
            self.idleSeconds = idleSeconds
            self.clock = clock
            self.version = version
        }
    }

    private let d: Dependencies
    private static let log = Logger(subsystem: "cz.rawzuu.studytracker", category: "focus")

    public private(set) var config = FocusConfig.empty
    public private(set) var state = ActiveFocus()
    private var commitments: [Commitment] = []
    private var attemptsToday: [String: Int] = [:]
    private var safariWatch = GuardReport.SafariWatch.off
    private var askedForSafari = false
    /// Uživatel není u Macu (zamčeno, uspáno) – měření stojí.
    public var away = false

    private var meter = UsageMeter()
    private var pending: [UsageSegment] = []
    private var lastFlush = 0
    private var lastRefresh: Int?
    private var lastReport: GuardReport?
    private var lastReportAt = 0
    private var lastPrunedDay = ""
    /// Poslední zaznamenaný pokus podle cíle – opakované kliknutí v Docku je jeden pokus.
    private var lastAttemptAt: [String: Int] = [:]
    /// Zablokovaná adresa v Safari a od kdy (rozšíření dostane chvilku, než zasáhne Strážce).
    private var blockedPage: (key: String, since: Int)?
    private var tamperReported: [String: String] = [:]

    /// Opakovaný pokus o totéž do tolika ms se počítá jako jeden.
    static let attemptDedupMs = 4000
    /// Rozšíření je „zapnuté“, když se ozvalo v posledních minutách.
    static let extensionFreshMs = 10 * 60_000
    /// Jak dlouho smí zablokovaná stránka zůstat otevřená, než zasáhne Strážce (když rozšíření běží).
    static let extensionGraceMs = 3000
    static let flushEveryMs = 60_000
    static let refreshEveryMs = 15_000

    public init(_ dependencies: Dependencies) {
        d = dependencies
    }

    private var now: Int { d.now() }

    static func isGuard(_ bundleId: String) -> Bool { bundleId.hasPrefix("cz.rawzuu.studytracker") && bundleId.hasSuffix(".guard") }

    // MARK: - Vyhodnocení

    /// Načte nastavení a stav, vyhodnotí pravidla a při změně je vynutí.
    public func refresh() async {
        let t = now
        lastRefresh = t
        let previous = config
        config = d.readConfig() ?? .inactive
        if config.watchSafari, !previous.watchSafari { askedForSafari = false }
        let today = d.clock.startOfDay(t)
        do {
            commitments = try await d.store.commitments(now: t)
            let exceptions = try await d.store.activeExceptions(now: t)
            attemptsToday = try await d.store.attemptCounts(since: today)
            let usage = config.plans.contains { if case .dailyLimit = $0.trigger { $0.enabled } else { false } }
                ? try await d.store.totals(day: d.clock.dayKey(t)) : []
            var next = FocusEngine.evaluate(config, context: FocusContext(snapshot: d.readSnapshot(), now: t, usageToday: usage),
                                            commitments: commitments, exceptions: exceptions, clock: d.clock)
            let fresh = FocusEngine.newCommitments(next, existing: commitments)
            if !fresh.isEmpty {
                try await d.store.save(fresh)
                commitments += fresh
                next = FocusEngine.evaluate(config, context: FocusContext(snapshot: d.readSnapshot(), now: t, usageToday: usage),
                                            commitments: commitments, exceptions: exceptions, clock: d.clock)
            }
            let changed = next.rules != state.rules || next.protectionApps != state.protectionApps || next.exceptions != state.exceptions
            state = next
            if changed { enforceRunning() }
        } catch {
            Self.log.error("Soustředění: databáze nedostupná: \(error.localizedDescription, privacy: .public)")
        }
        await updateSafariPermission()
        if d.clock.dayKey(t) != lastPrunedDay {
            lastPrunedDay = d.clock.dayKey(t)
            try? await d.store.prune(keepDays: config.tracking.retentionDays, now: t, clock: d.clock)
        }
        writeReport()
    }

    /// Pravidla začala (nebo se změnila): běžící zakázané aplikace hned schovat nebo ukončit.
    func enforceRunning() {
        let front = d.apps.frontmost()
        for app in d.apps.running() {
            guard let hit = state.check(app: app.bundleId, name: app.name) else { continue }
            if hit.appAction == .quit { d.apps.quit(app) } else { d.apps.hide(app) }
            if app.pid == front?.pid { showShield(hit, attempt: attemptsToday[hit.target.key] ?? 0) }
        }
    }

    // MARK: - Aplikace

    /// Aplikace přešla do popředí (nebo se spustila).
    public func appActivated(_ app: RunningApp) async {
        guard let hit = state.check(app: app.bundleId, name: app.name) else {
            if d.shield.isShown, !Self.isGuard(app.bundleId) { d.shield.close() }
            return
        }
        if hit.appAction == .quit { d.apps.quit(app) } else { d.apps.hide(app) }
        let attempt = await recordAttempt(hit, at: now)
        showShield(hit, attempt: attempt)
    }

    private func showShield(_ hit: FocusHit, attempt: Int) {
        d.shield.show(ShieldInfo(name: hit.name, isSite: { if case .site = hit.target { true } else { false } }(), lists: hit.listNames,
                                 attempt: max(1, attempt), until: hit.until, locked: hit.strictness.locked))
    }

    /// Zapíše pokus (opakování do pár sekund = jeden pokus). Vrací kolikátý je dnes.
    @discardableResult
    func recordAttempt(_ hit: FocusHit, at t: Int) async -> Int {
        let key = hit.target.key
        if let last = lastAttemptAt[key], t - last < Self.attemptDedupMs { return attemptsToday[key] ?? 1 }
        lastAttemptAt[key] = t
        attemptsToday[key, default: 0] += 1
        try? await d.store.record(FocusEvent(at: t, kind: .attempt, target: hit.target, name: hit.name, listIds: hit.listIds))
        writeReport()
        return attemptsToday[key] ?? 1
    }

    // MARK: - Safari

    private func updateSafariPermission() async {
        guard config.watchSafari else {
            safariWatch = .off
            return
        }
        guard d.safari.isRunning else { return }
        let ask = !askedForSafari
        askedForSafari = true
        safariWatch = await d.safari.permission(ask: ask)
    }

    /// Kontrola aktivní záložky. Rozšíření Safari web obvykle zastaví samo; Strážce zasáhne, když stránka
    /// zůstane otevřená (rozšíření je vypnuté, nebo blokuje slovo či „jen tyhle weby“, které nestihlo).
    func checkSafari(_ url: URL?) async {
        guard let url, let target = SiteRule.target(of: url), let hit = state.check(host: target.host, path: target.path) else {
            blockedPage = nil
            return
        }
        let t = now
        let key = hit.target.key
        let extensionOn = d.files?.extensionSeenAt().map { t - $0 < Self.extensionFreshMs } ?? false
        if extensionOn {
            guard let page = blockedPage, page.key == key else {
                blockedPage = (key, t)
                return
            }
            guard t - page.since >= Self.extensionGraceMs else { return }
            await reportTamper("Rozšíření Safari web nezablokovalo – je vypnuté, nebo nemá přístup k webům.", app: "Safari", at: t)
        }
        blockedPage = nil
        d.safari.leaveBlockedPage()
        let attempt = await recordAttempt(hit, at: t)
        showShield(hit, attempt: attempt)
    }

    /// Porušení (jednou denně za druh) – ukáže se ve statistikách.
    func reportTamper(_ detail: String, app: String, at t: Int) async {
        let day = d.clock.dayKey(t)
        guard tamperReported[detail] != day else { return }
        tamperReported[detail] = day
        try? await d.store.record(FocusEvent(at: t, kind: .tamper, target: nil, name: app, detail: detail))
    }

    /// Pokusy, které zachytilo rozšíření Safari.
    public func ingestSafariAttempts() async {
        guard let files = d.files else { return }
        for a in files.takeAttempts() {
            guard let hit = state.check(host: a.host, path: a.path) else { continue }
            await recordAttempt(hit, at: a.at)
        }
    }

    // MARK: - Pravidelná kontrola

    /// Jedna kontrola: měření, Safari, občas znovu vyhodnotit (časová okna, denní limity).
    public func tick() async {
        let t = now
        if lastRefresh.map({ t - $0 >= Self.refreshEveryMs }) ?? true || state.rules.contains(where: { $0.until.map { $0 <= t } ?? false }) {
            await refresh()
        }
        let front = d.apps.frontmost()
        var host = ""
        if front?.bundleId == SystemSafari.bundleId, safariWatch == .on, state.isActive || config.tracking.enabled {
            let url = d.safari.currentURL()
            host = url.flatMap(SiteRule.target)?.host ?? ""
            if state.isActive { await checkSafari(url) }
        }
        await measure(front: front, host: host, at: t)
        if t - lastReportAt >= 30_000 { writeReport() }
    }

    /// Jak dlouho čekat na další kontrolu: v Safari s blokovanými weby často, jinak zřídka.
    public var tickInterval: Duration {
        d.safari.isFrontmost && safariWatch == .on && state.rules.contains(where: { !$0.list.sites.isEmpty || !$0.list.keywords.isEmpty })
            ? .milliseconds(1500) : .seconds(5)
    }

    private func measure(front: RunningApp?, host: String, at t: Int) async {
        guard config.tracking.enabled else { return }
        let idle = d.idleSeconds()
        if away || idle >= Double(config.tracking.idleMinutes * 60) {
            pending += meter.update(nil, at: away ? t : t - Int(idle * 1000))
        } else if let front, !Self.isGuard(front.bundleId) {
            pending += meter.update(UsageActivity(bundleId: front.bundleId, appName: front.name, host: host), at: t)
        } else {
            // Blokovací obrazovka Strážce se nepočítá.
            pending += meter.update(nil, at: t)
        }
        if t - lastFlush >= Self.flushEveryMs { await flush(at: t) }
    }

    /// Uloží naměřené (průběžně a při ukončení).
    public func flush(at t: Int? = nil) async {
        let t = t ?? now
        lastFlush = t
        pending += meter.flush(at: t)
        guard !pending.isEmpty else { return }
        let segments = pending
        pending = []
        try? await d.store.add(segments, clock: d.clock)
    }

    // MARK: - Hlášení pro aplikaci a rozšíření

    func writeReport() {
        let t = now
        let report = GuardReport(generatedAt: t, guardVersion: d.version, state: state, attemptsToday: attemptsToday,
                                 safari: safariWatch, extensionSeenAt: d.files?.extensionSeenAt())
        // Beze změny stačí jednou za půl minuty (aplikace podle stáří pozná, že Strážce běží).
        var same = report
        same.generatedAt = lastReport?.generatedAt ?? 0
        same.state.now = lastReport?.state.now ?? 0
        guard same != lastReport || t - lastReportAt >= 30_000 else { return }
        lastReport = report
        lastReportAt = t
        try? d.files?.write(report)
    }
}
