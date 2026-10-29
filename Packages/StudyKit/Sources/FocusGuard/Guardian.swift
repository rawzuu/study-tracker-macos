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
        /// Kdy Mac naposledy nastartoval (ms) – zámek „odemknout po restartu“.
        public var bootTime: () -> Int
        /// Monotónní čas v ms (běží i ve spánku, nejde posunout) – pozná posunutí hodin Macu.
        public var monotonic: () -> Int

        public init(apps: any AppControl, safari: any SafariControl, shield: any ShieldControl, store: FocusStore, files: FocusFiles?,
                    readConfig: @escaping () -> FocusConfig?, readSnapshot: @escaping () -> WidgetSnapshot?,
                    now: @escaping () -> Int, idleSeconds: @escaping () -> Double, clock: StudyClock, version: String,
                    bootTime: @escaping () -> Int = { 0 },
                    monotonic: @escaping () -> Int = { Int(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000) }) {
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
            self.bootTime = bootTime
            self.monotonic = monotonic
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
    private var lastSweep = 0
    /// Nástěnný a monotónní čas při poslední kontrole.
    private var lastClock: (wall: Int, mono: Int)?
    /// Posun hodin dopředu větší než tohle je změna času, ne oprava podle sítě.
    static let clockJumpMs = 120_000
    static let sweepEveryMs = 20_000
    /// Poslední zaznamenaný pokus podle cíle – opakované kliknutí v Docku je jeden pokus.
    private var lastAttemptAt: [String: Int] = [:]
    /// Zablokovaná adresa v Safari a od kdy (rozšíření dostane chvilku, než zasáhne Strážce).
    private var blockedPage: (key: String, since: Int)?
    private var tamperReported: [String: String] = [:]
    /// Co ukazuje blokovací obrazovka (odemykání se týká toho).
    private var shown: (hit: FocusHit, attempt: Int, url: String?)?
    private var requests: [String: UnlockRequest] = [:]

    /// Opakovaný pokus o totéž do tolika ms se počítá jako jeden.
    static let attemptDedupMs = 4000
    /// Rozšíření je „zapnuté“, když se ozvalo v posledních minutách.
    static let extensionFreshMs = 10 * 60_000
    /// Jak dlouho smí zablokovaná stránka zůstat otevřená, než zasáhne Strážce (když rozšíření běží).
    static let extensionGraceMs = 3000
    static let flushEveryMs = 60_000
    static let refreshEveryMs = 15_000

    private let startedAt: Int

    public init(_ dependencies: Dependencies) {
        d = dependencies
        startedAt = dependencies.now()
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
            requests = Dictionary(try await d.store.unlockRequests().map { ($0.target.key, $0) }, uniquingKeysWith: { _, b in b })
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
            let changed = next.rules != state.rules || next.protectionApps != state.protectionApps || next.browserApps != state.browserApps || next.exceptions != state.exceptions
            state = next
            if changed { await enforceRunning() }
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

    /// Pravidla začala (nebo se změnila): běžící zakázané aplikace hned schovat nebo ukončit, zablokované
    /// záložky Safari zavřít.
    func enforceRunning() async {
        sweepSafari()
        let front = d.apps.frontmost()
        for app in d.apps.running() {
            guard let hit = state.check(app: app.bundleId, name: app.name) else { continue }
            if hit.appAction == .quit { d.apps.quit(app) } else { d.apps.hide(app) }
            if app.pid == front?.pid { await showShield(hit, attempt: attemptsToday[hit.target.key] ?? 0) }
        }
    }

    // MARK: - Aplikace

    /// Aplikace přešla do popředí (nebo se spustila).
    public func appActivated(_ app: RunningApp) async {
        // Safari po spuštění obnoví záložky z minula – ty zablokované hned zavřít.
        if app.bundleId == SystemSafari.bundleId { sweepSafari() }
        guard let hit = state.check(app: app.bundleId, name: app.name) else {
            if d.shield.isShown, !Self.isGuard(app.bundleId) {
                d.shield.close()
                shown = nil
            }
            return
        }
        if hit.appAction == .quit { d.apps.quit(app) } else { d.apps.hide(app) }
        let attempt = await recordAttempt(hit, at: now)
        await showShield(hit, attempt: attempt)
    }

    private func showShield(_ hit: FocusHit, attempt: Int, url: String? = nil) async {
        shown = (hit, attempt, url)
        await updateShield()
    }

    /// Obrazovka s aktuálním krokem odemykání.
    private func updateShield(error: String? = nil) async {
        guard let (hit, attempt, _) = shown else { return }
        let step = Unlock.step(hit, request: requests[hit.target.key], allowanceLeft: await allowanceLeft(hit), now: now,
                               bootTime: d.bootTime(), clock: d.clock)
        d.shield.show(ShieldInfo(name: hit.name, isSite: { if case .site = hit.target { true } else { false } }(), lists: hit.listNames,
                                 attempt: max(1, attempt), until: hit.until, locked: hit.strictness.locked, unlock: step, error: error))
    }

    private func allowanceLeft(_ hit: FocusHit) async -> Int? {
        guard hit.strictness.weeklyAllowance != nil else { return nil }
        let used = (try? await d.store.unlockLists(since: d.clock.startOfWeek(now))) ?? []
        return ActiveFocus.allowanceLeft(hit, unlocksThisWeek: used)
    }

    // MARK: - Odemykání

    /// „Odemknout…“ / „Pokračovat“ na blokovací obrazovce: založí žádost, nebo posune další krok.
    public func requestUnlock() async {
        guard let (hit, _, url) = shown else { return }
        let key = hit.target.key
        if requests[key] == nil {
            guard hit.strictness.canUnlock, await allowanceLeft(hit) != 0 else { return await updateShield() }
            let request = UnlockRequest(target: hit.target, name: hit.name, listIds: hit.listIds, requestedAt: now, bootTime: d.bootTime(),
                                        challenge: Unlock.challenge(length: hit.strictness.typingCharacters), url: url)
            requests[key] = request
            try? await d.store.save(request)
        }
        await advance()
    }

    /// Opsaný text.
    public func submit(typed: String) async {
        guard let (hit, _, _) = shown, var request = requests[hit.target.key] else { return }
        guard Unlock.matches(typed, request.challenge) else { return await updateShield(error: "Text nesouhlasí – opiš ho přesně, včetně velkých písmen.") }
        request.typed = true
        requests[hit.target.key] = request
        try? await d.store.save(request)
        await advance()
    }

    /// Heslo (zadává ho ten, kdo ho zná).
    public func submit(password: String) async {
        guard let (hit, _, _) = shown, var request = requests[hit.target.key], let lock = hit.strictness.password else { return }
        guard Unlock.verify(password, lock) else { return await updateShield(error: "Heslo nesouhlasí.") }
        request.passwordOK = true
        requests[hit.target.key] = request
        try? await d.store.save(request)
        await advance()
    }

    private func advance() async {
        guard let (hit, _, _) = shown else { return }
        let step = Unlock.step(hit, request: requests[hit.target.key], allowanceLeft: await allowanceLeft(hit), now: now,
                               bootTime: d.bootTime(), clock: d.clock)
        if step == .ready { await grant(hit) } else { await updateShield() }
    }

    /// Všechny překážky splněné: výjimka na `unlockMinutes`, zapíše se do statistik.
    private func grant(_ hit: FocusHit) async {
        let t = now
        let request = requests.removeValue(forKey: hit.target.key)
        try? await d.store.removeRequest(hit.target)
        try? await d.store.record(FocusEvent(at: t, kind: .unlock, target: hit.target, name: hit.name, listIds: hit.listIds,
                                             until: t + hit.strictness.unlockMinutes * StudyClock.minute))
        shown = nil
        d.shield.close()
        await refresh()
        switch hit.target {
        case let .app(bundleId): d.apps.open(bundleId: bundleId)
        case .site: if let url = request?.url.flatMap(URL.init(string:)) { d.safari.open(url) }
        }
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
        await showShield(hit, attempt: attempt, url: url.absoluteString)
    }

    /// Zablokované záložky Safari (i na pozadí) přepne na prázdnou stránku. Aktivní záložku Safari v popředí
    /// nechá na `checkSafari` – ta k ní ukáže blokovací obrazovku.
    func sweepSafari() {
        guard safariWatch == .on, d.safari.isRunning,
              state.rules.contains(where: { !$0.list.sites.isEmpty || !$0.list.keywords.isEmpty }) else { return }
        lastSweep = now
        let frontmost = d.safari.isFrontmost
        let blocked = d.safari.tabs().filter { tab in
            guard !(frontmost && tab.isCurrent), let target = SiteRule.target(of: tab.url) else { return false }
            return state.check(host: target.host, path: target.path) != nil
        }
        d.safari.blank(blocked)
    }

    /// Porušení (jednou denně za druh) – ukáže se ve statistikách.
    func reportTamper(_ detail: String, app: String, at t: Int) async {
        let day = d.clock.dayKey(t)
        guard tamperReported[detail] != day else { return }
        tamperReported[detail] = day
        try? await d.store.record(FocusEvent(at: t, kind: .tamper, target: nil, name: app, detail: detail))
    }

    /// Pokusy (a žádosti o odemknutí), které poslalo rozšíření Safari.
    public func ingestSafariAttempts() async {
        guard let files = d.files else { return }
        for a in files.takeAttempts() {
            guard let hit = state.check(host: a.host, path: a.path) else { continue }
            if a.unlock == true {
                await showShield(hit, attempt: attemptsToday[hit.target.key] ?? 1, url: a.url)
            } else {
                await recordAttempt(hit, at: a.at)
            }
        }
    }

    // MARK: - Pravidelná kontrola

    /// Jedna kontrola: měření, Safari, občas znovu vyhodnotit (časová okna, denní limity).
    public func tick() async {
        let t = now
        await checkClock(at: t)
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
        if t - lastSweep >= Self.sweepEveryMs, state.isActive { sweepSafari() }
        await measure(front: front, host: host, at: t)
        if t - lastReportAt >= 30_000 { writeReport() }
    }

    /// Hodiny Macu se posunuly dopředu (víc, než uběhlo): přísné závazky prodloužit o stejný kus a zapsat porušení.
    func checkClock(at t: Int) async {
        let mono = d.monotonic()
        defer { lastClock = (t, mono) }
        guard let last = lastClock else { return }
        let jump = (t - last.wall) - (mono - last.mono)
        guard jump > Self.clockJumpMs else { return }
        try? await d.store.shiftCommitments(by: jump, activeAfter: last.wall)
        await reportTamper("Čas Macu se posunul dopředu o \(jump / StudyClock.minute) min – přísné zámky se o tolik prodloužily.", app: "Datum a čas", at: t)
        await refresh()
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
                                 safari: safariWatch, extensionSeenAt: d.files?.extensionSeenAt(), startedAt: startedAt)
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

extension Guardian: ShieldActions {
    public func shieldRequestUnlock() { Task { await requestUnlock() } }
    public func shieldSubmit(typed: String) { Task { await submit(typed: typed) } }
    public func shieldSubmit(password: String) { Task { await submit(password: password) } }
}
