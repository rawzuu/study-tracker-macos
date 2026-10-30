import AppKit
import AppModel
import DesignSystem
import Focus
import SwiftUI
import UniformTypeIdentifiers

/// Soustředění: blokování aplikací a webů a čas u obrazovky – samostatná část aplikace, jen na tomto Macu.
/// Vynucuje Strážce (pomocník na pozadí); stránka nastavuje seznamy a plány a ukazuje, co právě platí.
public struct FocusView: View {
    @Environment(FocusController.self) private var focus

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                page(metrics: PageMetrics(width: proxy.size.width), now: Int(Date().timeIntervalSince1970 * 1000))
            }
        }
        .pageBackground()
        .navigationTitle("Soustředění")
    }

    private func page(metrics: PageMetrics, now: Int) -> some View {
        let state = focus.state(at: now)
        return VStack(alignment: .leading, spacing: 40) {
            PageHeader("Soustředění", subtitle: FocusText.summary(state, enabled: focus.config.enabled, status: focus.status),
                       glyph: .symbol("moon.circle")) {}
            if let message = focus.message {
                Banner(message, systemImage: "exclamationmark.circle", tone: .warn) {
                    Button("Zavřít") { focus.message = nil }.buttonStyle(.study(.ghost, size: .small))
                }
            }
            if !focus.isAvailable {
                EmptyNote("Soustředění v tomhle sestavení nejde", systemImage: "moon.circle") {
                    Text("Chybí Strážce nebo sdílený kontejner (sestavení bez podpisu).")
                }
            } else {
                ColumnsLayout(columns: min(2, metrics.columns), spacing: 56, rowSpacing: 40) {
                    NowSection(state: state, now: now)
                    FocusListsSection(state: state)
                    FocusPlansSection(state: state, now: now)
                    FreezeSection(state: state, now: now)
                    FocusStatsSection()
                    GuardSection(now: now)
                    FocusMoreSection(state: state)
                }
            }
        }
        .padding(.horizontal, metrics.padding)
        .padding(.vertical, 36)
        .frame(maxWidth: 1600, alignment: .leading)
    }
}

/// Texty Soustředění (sdílené se stránkou i testy).
enum FocusText {
    static func summary(_ state: ActiveFocus, enabled: Bool, status: FocusController.GuardStatus) -> String {
        switch status {
        case .unavailable: return "Blokování aplikací a webů"
        case .off: return "Strážce je vypnutý – nic se neblokuje"
        case .starting: return "Strážce se zapíná…"
        case .stopping: return "Strážce se vypíná…"
        case .needsApproval: return "Strážce čeká na povolení v Nastavení systému"
        case .running: break
        }
        guard !state.rules.isEmpty else { return enabled ? "Teď se nic neblokuje" : "Blokování je vypnuté" }
        return "Teď blokuje: \(names(state))" + (until(state.rules.compactMap(\.until).max()).map { " · \($0)" } ?? "")
    }

    /// Názvy blokovaných seznamů („Sociální sítě, Video“).
    static func names(_ state: ActiveFocus) -> String {
        state.rules.map(\.list.name).uniqued().joined(separator: ", ")
    }

    /// „25 min“, „2 h“, „1 h 30 min“.
    static func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func until(_ t: Int?) -> String? {
        t.map { FocusFormat.until($0) }
    }

    static func strictness(_ s: Strictness) -> String {
        if s.locked { return "Přísná" }
        var parts: [String] = []
        if s.delayMinutes > 0 { parts.append("odklad \(s.delayMinutes) min") }
        if s.typingCharacters > 0 { parts.append("opsat \(s.typingCharacters) znaků") }
        if let n = s.weeklyAllowance { parts.append("\(n)× týdně") }
        if s.requireRestart { parts.append("po restartu") }
        if s.password != nil { parts.append("heslo") }
        if !s.unlockWindows.isEmpty { parts.append("jen \(Unlock.windowsText(s.unlockWindows))") }
        return parts.isEmpty ? "Volná" : parts.joined(separator: ", ")
    }

    static func trigger(_ t: FocusPlan.Trigger) -> String {
        switch t {
        case let .studyBlock(o): o.duringBreaks ? "během bloku učení i o přestávce" : "během bloku učení"
        case let .schedule(w): "\(w.count) časov\(w.count == 1 ? "é okno" : w.count < 5 ? "á okna" : "ých oken")"
        case .studyPlan: "během Studijního plánu"
        case let .dailyLimit(m): "po \(m) min denně"
        }
    }

    static let strictnessPresets: [(String, Strictness)] = [
        ("Volná – jen odkliknout", .soft), ("Odklad 5 minut", .delay), ("Opsat 120 znaků", .typing),
        ("3 odemknutí týdně", .allowance), ("Až po restartu Macu", .restart), ("Přísná – do konce nejde zrušit", .strict),
    ]
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Strážce a Safari

private struct GuardSection: View {
    @Environment(FocusController.self) private var focus
    let now: Int

    var body: some View {
        PageSection("Strážce") {
            VStack(alignment: .leading, spacing: 16) {
                StatusRow(guardHealth, "Strážce na pozadí", detail: guardDetail) {
                    switch focus.status {
                    case .running:
                        Button("Vypnout") { focus.disableGuard(now: now) }.buttonStyle(.study(.normal, size: .small))
                    case .starting, .stopping:
                        ProgressView().controlSize(.small)
                    case .needsApproval:
                        HStack(spacing: 6) {
                            Button("Otevřít Nastavení") { focus.openLoginItemsSettings() }.buttonStyle(.study(.primary, size: .small))
                            Button("Zkusit znovu") { focus.enableGuard() }.buttonStyle(.study(.ghost, size: .small))
                        }
                    case .off, .unavailable:
                        Button("Zapnout") { focus.enableGuard() }.buttonStyle(.study(.primary, size: .small))
                            .accessibilityIdentifier("focus.enableGuard")
                    }
                }
                StatusRow(safariHealth, "Blokovat weby v Safari", detail: safariDetail) {
                    HStack(spacing: 6) {
                        if focus.status == .running, focus.config.watchSafari, focus.report?.safari == .needsPermission {
                            Button("Povolit") { focus.openAutomationSettings() }.buttonStyle(.study(.primary, size: .small))
                        }
                        Toggle("Blokovat weby v Safari", isOn: Binding(get: { focus.config.watchSafari }, set: { v in focus.update { $0.watchSafari = v } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                StatusRow(focus.extensionActive(at: now) ? .ok : .optional, "Rozšíření Safari (volitelné)", detail: extensionDetail) {
                    Button("Otevřít v Safari") { focus.openSafariExtensionSettings() }.buttonStyle(.study(.ghost, size: .small))
                }
                SettingSwitch("Blokovat podle plánů", detail: "Hlavní vypínač. Přísný zámek, který už běží, platí do konce i po vypnutí.",
                              isOn: Binding(get: { focus.config.enabled }, set: { v in focus.update { $0.enabled = v } }), id: "focus.enabled")
                SettingSwitch("Měřit čas u obrazovky", detail: "Čas v aplikacích a na webech po hodinách, jen na tomto Macu. Bez myši a klávesnice déle než \(focus.config.tracking.idleMinutes) min se nepočítá.",
                              isOn: Binding(get: { focus.config.tracking.enabled }, set: { v in focus.update { $0.tracking.enabled = v } }))
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var guardHealth: StatusHealth {
        switch focus.status {
        case .running: .ok
        case .needsApproval: .problem
        case .starting, .stopping: .pending
        case .off, .unavailable: .off
        }
    }

    private var guardDetail: String {
        switch focus.status {
        case .running:
            var parts: [String] = []
            if let started = focus.report?.startedAt { parts.append("Běží od \(FocusFormat.moment(started, now: now))") } else { parts.append("Běží") }
            if let checked = focus.report?.generatedAt { parts.append("naposledy se ozval \(FocusFormat.ago(checked, now: now))") }
            return parts.joined(separator: ", ") + ". Blokuje i bez otevřené aplikace a spustí se sám po restartu Macu. Najdeš ho v Nastavení systému → Obecné → Položky při přihlášení."
        case .starting: return "Zapíná se…"
        case .stopping: return "Vypíná se…"
        case .needsApproval: return "macOS čeká na tvoje povolení: Nastavení systému → Obecné → Položky při přihlášení → u Study Trackeru zapni přepínač. Pak klikni na Zkusit znovu."
        case .off, .unavailable: return "Pomocník, který blokuje aplikace a weby a měří čas. macOS po zapnutí ohlásí novou položku na pozadí."
        }
    }

    private var safariHealth: StatusHealth {
        guard focus.config.watchSafari else { return .off }
        guard focus.status == .running else { return .pending }
        return switch focus.report?.safari {
        case .on: .ok
        case .needsPermission: .problem
        default: .pending
        }
    }

    private var safariDetail: String {
        guard focus.config.watchSafari else { return "Vypnuto – weby se neblokují a čas na webech se neměří." }
        guard focus.status == .running else { return "Začne, až poběží Strážce." }
        return switch focus.report?.safari {
        case .on: "Funguje – Strážce hlídá adresu v Safari, zablokovanou stránku zavře a ukáže blokovací obrazovku. Měří i čas na webech."
        case .needsPermission: "Chybí souhlas: Nastavení systému → Soukromí a zabezpečení → Automatizace → Study Tracker – Strážce → zapni Safari."
        default: "Až otevřeš Safari, macOS se zeptá, jestli smí Strážce ovládat Safari – potvrď Povolit."
        }
    }

    private var extensionDetail: String {
        focus.extensionActive(at: now)
            ? "Zapnuté – weby se zablokují ještě před načtením."
            : "Blokuje ještě před načtením stránky, ale bez placeného vývojářského účtu ho Safari ukáže jen se zapnutým Nastavení → Pro vývojáře → Povolit nepodepsaná rozšíření, a to se po ukončení Safari vypne. Weby se blokují i bez něj."
    }
}

private enum StatusHealth { case ok, problem, pending, off, optional }

/// Řádek nastavení se stavem vlevo (funguje / chybí krok / vypnuto).
private struct StatusRow<Control: View>: View {
    let health: StatusHealth
    let title: String
    let detail: String
    let control: Control

    init(_ health: StatusHealth, _ title: String, detail: String, @ViewBuilder control: () -> Control) {
        self.health = health
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color).frame(width: 16)
                .accessibilityLabel(label)
            SettingRow(title, detail: detail) { control }
        }
    }

    private var symbol: String {
        switch health {
        case .ok: "checkmark.circle.fill"
        case .problem: "exclamationmark.circle.fill"
        case .pending: "clock"
        case .off, .optional: "circle"
        }
    }

    private var color: Color {
        switch health {
        case .ok: Palette.success
        case .problem: Palette.warn
        case .pending, .off, .optional: Palette.text3
        }
    }

    private var label: String {
        switch health {
        case .ok: "Funguje"
        case .problem: "Chybí krok"
        case .pending: "Čeká"
        case .off: "Vypnuto"
        case .optional: "Volitelné"
        }
    }
}

// MARK: - Co platí teď

private struct NowSection: View {
    @Environment(FocusController.self) private var focus
    let state: ActiveFocus
    let now: Int

    var body: some View {
        PageSection("Teď", accessory: { Text(attemptsText) }) {
            if state.rules.isEmpty {
                Text(focus.status == .running ? "Nic se neblokuje." : "Bez Strážce se nic neblokuje.")
                    .font(Typo.body).foregroundStyle(Palette.text3).padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.rules.enumerated()), id: \.offset) { _, rule in
                        ListRow {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: rule.strictness.locked ? "lock.fill" : "circle.fill")
                                    .font(.system(size: rule.strictness.locked ? 11 : 7))
                                    .foregroundStyle(rule.strictness.locked ? Palette.danger : Palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.list.name)
                                    Text(([rule.sources.joined(separator: ", "), FocusText.strictness(rule.strictness)]).joined(separator: " · "))
                                        .font(Typo.small).foregroundStyle(Palette.text3)
                                }
                                Spacer()
                                Text(FocusText.until(rule.until) ?? "do konce bloku").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text2)
                            }
                        }
                    }
                }
            }
            if let top = topAttempts, !top.isEmpty {
                Text("Nejčastěji dnes: " + top).font(Typo.small).foregroundStyle(Palette.text3).padding(.top, 6)
            }
        }
    }

    private var attemptsText: String {
        let n = focus.report?.attemptsToday.values.reduce(0, +) ?? 0
        return n == 0 ? "dnes žádný pokus" : "dnes \(n) \(n == 1 ? "pokus" : n < 5 ? "pokusy" : "pokusů")"
    }

    private var topAttempts: String? {
        focus.report?.attemptsToday.sorted { $0.value > $1.value }.prefix(3).compactMap { key, n in
            FocusTarget(key: key).map { t -> String in
                switch t {
                case let .site(host): "\(host) \(n)×"
                case let .app(id): "\(id.split(separator: ".").last.map(String.init) ?? id) \(n)×"
                }
            }
        }.joined(separator: ", ")
    }
}

// MARK: - Seznamy

/// Seznam v přísném zámku, který právě běží: měnit ani mazat ho nejde (Strážce by stejně vynucoval
/// zapamatovanou podobu, tak ať je to vidět).
func isLocked(_ listId: String, _ state: ActiveFocus) -> Bool {
    state.rules.contains { $0.list.id == listId && $0.strictness.locked }
}

private struct FocusListsSection: View {
    @Environment(FocusController.self) private var focus
    let state: ActiveFocus
    @State private var editing: FocusList?
    @State private var isNew = false

    var body: some View {
        PageSection("Seznamy", accessory: {
            HStack(spacing: 10) {
                Menu("Ze šablony") {
                    ForEach([FocusTemplates.studyOnly] + FocusTemplates.all) { t in
                        Button(t.name) { open(template(t), isNew: true) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("focus.addList")
                Button("Nový") { open(FocusList(name: ""), isNew: true) }.buttonStyle(.study(.ghost, size: .small))
                Menu {
                    Button("Exportovat seznamy…") { exportLists() }.disabled(focus.config.lists.isEmpty)
                    Button("Importovat seznamy nebo weby…") { importLists() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Export a import")
                .accessibilityLabel("Export a import seznamů")
            }
        }) {
            if focus.config.lists.isEmpty {
                Text("Zatím žádný seznam. Začni šablonou – třeba Sociální sítě a Video.").font(Typo.body).foregroundStyle(Palette.text3).padding(.vertical, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(focus.config.lists) { list in
                    let locked = isLocked(list.id, state)
                    Button { if !locked { open(list, isNew: false) } } label: {
                        ListRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name).foregroundStyle(Palette.text)
                                Text(detail(list)).font(Typo.small).foregroundStyle(Palette.text3)
                            }
                            Spacer()
                            if locked {
                                Label("v přísném zámku", systemImage: "lock.fill").font(Typo.small).foregroundStyle(Palette.text3)
                            } else {
                                Text(FocusText.strictness(list.strictness)).font(Typo.small).foregroundStyle(Palette.text2)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.text3)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(locked ? "Během přísného zámku nejde seznam měnit." : "Upravit seznam")
                    .accessibilityIdentifier("focus.list.\(list.name)")
                }
            }
        }
        .sheet(item: $editing) { list in FocusListEditor(list: list, isNew: isNew).environment(focus) }
    }

    private func template(_ t: FocusTemplates.Template) -> FocusList {
        var list = t.makeList()
        if t.id == FocusTemplates.studyOnly.id { list.mode = .allowOnly }
        return list
    }

    private func open(_ list: FocusList, isNew: Bool) {
        self.isNew = isNew
        editing = list
    }

    private func detail(_ list: FocusList) -> String {
        let mode = list.mode == .allowOnly ? "povolit jen tyhle" : "blokovat"
        func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String { "\(n) \(n == 1 ? one : n > 1 && n < 5 ? few : many)" }
        var parts = [mode, count(list.apps.count, "aplikace", "aplikace", "aplikací"), count(list.sites.count, "web", "weby", "webů")]
        if !list.keywords.isEmpty { parts.append(count(list.keywords.count, "slovo", "slova", "slov")) }
        if list.appAction == .quit { parts.append("ukončit") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Plány

private struct FocusPlansSection: View {
    @Environment(FocusController.self) private var focus
    let state: ActiveFocus
    let now: Int
    @State private var editing: FocusPlan?
    @State private var isNew = false
    @State private var lockMinutes = 60

    var body: some View {
        PageSection("Plány", accessory: {
            Button("Nový") {
                isNew = true
                editing = FocusPlan(name: "Během učení", listIds: focus.config.lists.map(\.id), trigger: .studyBlock(StudyBlockOptions()))
            }
            .buttonStyle(.study(.ghost, size: .small))
            .disabled(focus.config.lists.isEmpty)
            .accessibilityIdentifier("focus.addPlan")
        }) {
            if focus.config.plans.isEmpty {
                Text("Kdy blokovat – nejčastěji během bloku učení.").font(Typo.body).foregroundStyle(Palette.text3).padding(.vertical, 8)
            }
            if !scheduled.isEmpty {
                // Rozvrh všech zapnutých časových oken v týdnu – přehled jako v kalendáři blokovačů.
                ScheduleGridEditor(windows: .constant(scheduled), readOnly: true)
                    .padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(focus.config.plans) { plan in
                    let locked = plan.listIds.contains { isLocked($0, state) } && state.rules.contains { $0.sources.contains(plan.name) }
                    ListRow {
                        Button {
                            if !locked {
                                isNew = false
                                editing = plan
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.name).foregroundStyle(Palette.text)
                                Text(detail(plan)).font(Typo.small).foregroundStyle(Palette.text3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("focus.plan.\(plan.name)")
                        if locked {
                            Image(systemName: "lock.fill").foregroundStyle(Palette.text3).help("Běží přísný zámek – plán do konce nejde měnit.")
                        } else {
                            Toggle(plan.name, isOn: Binding(get: { plan.enabled }, set: { v in setPlan(plan.id) { $0.enabled = v } }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
            }
            lockRow
        }
        .sheet(item: $editing) { plan in FocusPlanEditor(plan: plan, isNew: isNew).environment(focus) }
    }

    /// Ruční zámek: všechny seznamy na zvolenou dobu, přísnost podle seznamů.
    private var lockRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(focus.config.locks.filter { $0.end > now }) { lock in
                Label("Ruční zámek \(FocusText.until(lock.end) ?? "")\(lock.strictness?.locked == true ? " · přísný" : "")", systemImage: "lock")
                    .font(Typo.small).foregroundStyle(Palette.text2)
            }
            HStack(spacing: 8) {
                Text("Zamknout teď na").foregroundStyle(Palette.text2)
                Picker("Délka", selection: $lockMinutes) {
                    ForEach([15, 30, 60, 90, 120, 180, 240, 480], id: \.self) { m in Text(FocusText.minutes(m)).tag(m) }
                }
                .labelsHidden()
                .fixedSize()
                Menu("Zamknout") {
                    Button("Podle přísnosti seznamů") { lock(nil) }
                    Button("Přísně – do konce nejde zrušit") { lock(.strict) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(focus.config.lists.isEmpty)
            }
            .padding(.top, 10)
        }
    }

    /// Časová okna všech zapnutých plánů dohromady.
    private var scheduled: [TimeWindow] {
        focus.config.plans.filter(\.enabled).flatMap { plan -> [TimeWindow] in
            if case let .schedule(windows) = plan.trigger { windows } else { [] }
        }
    }

    private func detail(_ plan: FocusPlan) -> String {
        var parts = [FocusText.trigger(plan.trigger)]
        let names = plan.listIds.compactMap { focus.config.list($0)?.name }
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if plan.freeze { parts.append("zmrazí Mac") }
        if let b = plan.breaks, case .schedule = plan.trigger { parts.append("přestávky \(b.rest) min po \(b.work) min") }
        if let s = plan.strictness { parts.append(FocusText.strictness(s)) }
        return parts.joined(separator: " · ")
    }

    private func lock(_ strictness: Strictness?) {
        focus.lock(minutes: lockMinutes, strictness: strictness, now: now)
    }

    private func setPlan(_ id: String, _ change: (inout FocusPlan) -> Void) {
        focus.update { c in
            if let i = c.plans.firstIndex(where: { $0.id == id }) { change(&c.plans[i]) }
        }
    }
}

extension FocusListsSection {
    /// Uloží všechny seznamy do JSON souboru (bez hesel odemykání).
    func exportLists() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Soustředění – seznamy.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? FocusController.exportLists(focus.config.lists) else { return }
        do { try data.write(to: url, options: .atomic) } catch { focus.message = "Seznamy se nepovedlo uložit: \(error.localizedDescription)" }
    }

    /// Seznamy z exportu, nebo prostý text s weby (každý soubor = nový seznam).
    func importLists() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .commaSeparatedText, .text]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var added = 0
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            added += focus.importLists(data, name: url.deletingPathExtension().lastPathComponent)
        }
        if added == 0 { focus.message = "V souboru nebyl žádný seznam ani web." }
    }
}

// MARK: - Zmrazení

/// Zmrazení celého Macu (jako Frozen Turkey): na zvolenou dobu jen Study Tracker a povolené aplikace.
private struct FreezeSection: View {
    @Environment(FocusController.self) private var focus
    let state: ActiveFocus
    let now: Int
    @State private var minutes = 60
    @State private var confirming = false

    var body: some View {
        let active = state.freeze
        PageSection("Zmrazení") {
            VStack(alignment: .leading, spacing: 16) {
                if let active {
                    Label("Mac je zmrazený \(FocusText.until(active.until) ?? "do konce bloku")", systemImage: "snowflake")
                        .foregroundStyle(Palette.accent)
                }
                Text("Schová všechno kromě Study Trackeru a aplikací níž – i Finder a Nastavení systému – a přes obrazovku ukáže, do kdy. Jde naplánovat i v Plánech (Zmrazit celý Mac).")
                    .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                FormField("Povolené aplikace") {
                    AppListField(apps: Binding(get: { focus.config.freeze.allowedApps }, set: { v in focus.update { $0.freeze.allowedApps = v } }))
                }
                SettingRow("Přísnost", detail: FocusText.strictness(focus.config.freeze.strictness)) {
                    Menu("Změnit") {
                        ForEach(FocusText.strictnessPresets, id: \.0) { preset in
                            Button(preset.0) { focus.update { $0.freeze.strictness = preset.1 } }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Text("Zmrazit teď na").foregroundStyle(Palette.text2)
                    Picker("Délka zmrazení", selection: $minutes) {
                        ForEach([15, 30, 60, 90, 120, 180, 240], id: \.self) { m in Text(FocusText.minutes(m)).tag(m) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Zmrazit…") { confirming = true }
                        .buttonStyle(.study(.normal, size: .small))
                        .disabled(focus.status != .running || active != nil)
                        .accessibilityIdentifier("focus.freeze")
                }
            }
            .disabled(active != nil && state.isLocked)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .confirmationDialog("Zmrazit Mac na \(FocusText.minutes(minutes))?", isPresented: $confirming) {
            Button("Zmrazit") { focus.freeze(minutes: minutes, now: Int(Date().timeIntervalSince1970 * 1000)) }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text(freezeWarning)
        }
    }

    private var freezeWarning: String {
        let apps = focus.config.freeze.allowedApps.map(\.name)
        let allowed = apps.isEmpty ? "jen Study Tracker" : "Study Tracker a " + apps.joined(separator: ", ")
        let strict = focus.config.freeze.strictness.locked ? " Přísné zmrazení do konce nejde zrušit." : ""
        return "Ostatní aplikace se schovají, povolené zůstane \(allowed). Rozdělaná práce se neztratí.\(strict)"
    }
}

// MARK: - Další nastavení

private struct FocusMoreSection: View {
    @Environment(FocusController.self) private var focus
    let state: ActiveFocus
    @State private var confirmDelete = false

    var body: some View {
        PageSection("Další nastavení") {
            VStack(alignment: .leading, spacing: 16) {
                SettingRow("Přísněji před zkouškou", detail: "Pár dní před zkouškou platí ke všem plánům přísný zámek.") {
                    HStack(spacing: 6) {
                        if let boost = focus.config.examBoost {
                            NumberField(value: Binding(get: { boost.daysBefore }, set: { v in focus.update { $0.examBoost?.daysBefore = v } }), in: 0...30)
                            Text("dní").foregroundStyle(Palette.text3)
                        }
                        Toggle("Přísněji před zkouškou", isOn: Binding(get: { focus.config.examBoost != nil },
                                                                     set: { v in focus.update { $0.examBoost = v ? ExamBoost() : nil } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingSwitch("Oznámení", detail: "Blokování začne za 5 minut, začalo, skončilo – posílá Strážce (macOS se jednou zeptá na povolení).",
                              isOn: Binding(get: { focus.config.notify }, set: { v in focus.update { $0.notify = v } }))
                SettingSwitch("Blokovat jiné prohlížeče", detail: "Když se blokují weby, zablokuje i Chrome, Firefox, Arc, Edge a další – weby umí Strážce hlídat jen v Safari.",
                              isOn: Binding(get: { focus.config.protection.otherBrowsers }, set: { v in focus.update { $0.protection.otherBrowsers = v } }))
                SettingSwitch("Pojistka: nástroje", detail: "Během přísného zámku blokovat Monitor aktivity a terminály, kterými by šel Strážce vypnout.",
                              isOn: Binding(get: { focus.config.protection.systemTools }, set: { v in focus.update { $0.protection.systemTools = v } }))
                SettingSwitch("Pojistka: Nastavení systému", detail: "Během přísného zámku blokovat i Nastavení systému (Položky při přihlášení).",
                              isOn: Binding(get: { focus.config.protection.systemSettings }, set: { v in focus.update { $0.protection.systemSettings = v } }))
                SettingRow("Nečinnost", detail: "Po kolika minutách bez myši a klávesnice se čas u obrazovky přestane počítat.") {
                    Picker("Nečinnost", selection: Binding(get: { focus.config.tracking.idleMinutes }, set: { v in focus.update { $0.tracking.idleMinutes = v } })) {
                        ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow("Uchovávat historii", detail: "Starší měření a pokusy se mažou.") {
                    Picker("Uchovávat", selection: Binding(get: { focus.config.tracking.retentionDays }, set: { v in focus.update { $0.tracking.retentionDays = v } })) {
                        ForEach([30, 90, 180, 365], id: \.self) { Text("\($0) dní").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow("Smazat historii", detail: "Měření, pokusy, odemknutí a porušení. Běžící přísný zámek zůstane.") {
                    Button("Smazat…") { confirmDelete = true }.buttonStyle(.study(.ghost, size: .small))
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .confirmationDialog("Smazat celou historii Soustředění?", isPresented: $confirmDelete) {
            Button("Smazat", role: .destructive) { Task { try? await focus.store?.deleteHistory() } }
        }
    }
}
