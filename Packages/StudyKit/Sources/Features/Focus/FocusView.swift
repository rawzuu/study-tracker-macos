import AppModel
import DesignSystem
import Focus
import SwiftUI

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
        case .running: break
        }
        guard !state.rules.isEmpty else { return enabled ? "Teď se nic neblokuje" : "Blokování je vypnuté" }
        let names = state.rules.map(\.list.name).uniqued().joined(separator: ", ")
        return "Teď blokuje: \(names)" + (until(state.rules.compactMap(\.until).max()).map { " · \($0)" } ?? "")
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
                SettingRow("Strážce na pozadí", detail: guardDetail) {
                    switch focus.status {
                    case .running:
                        Button("Vypnout") { focus.disableGuard(now: now) }.buttonStyle(.study(.normal, size: .small))
                    case .starting:
                        ProgressView().controlSize(.small)
                    case .off, .unavailable:
                        Button("Zapnout") { focus.enableGuard() }.buttonStyle(.study(.primary, size: .small))
                            .accessibilityIdentifier("focus.enableGuard")
                    }
                }
                SettingSwitch("Blokovat podle plánů", detail: "Hlavní vypínač. Přísný zámek, který už běží, platí do konce i po vypnutí.",
                              isOn: Binding(get: { focus.config.enabled }, set: { v in focus.update { $0.enabled = v } }), id: "focus.enabled")
                SettingRow("Rozšíření Safari", detail: focus.extensionActive(at: now)
                    ? "Zapnuté – weby se zablokují ještě před načtením."
                    : "Zapni ho v Safari → Nastavení → Rozšíření a povol mu přístup ke všem webům.") {
                    Button("Otevřít v Safari") { focus.openSafariExtensionSettings() }.buttonStyle(.study(.ghost, size: .small))
                }
                SettingRow("Hlídat adresu v Safari", detail: safariDetail) {
                    HStack(spacing: 6) {
                        if focus.report?.safari == .needsPermission {
                            Button("Povolit") { focus.openAutomationSettings() }.buttonStyle(.study(.ghost, size: .small))
                        }
                        Toggle("Hlídat adresu v Safari", isOn: Binding(get: { focus.config.watchSafari }, set: { v in focus.update { $0.watchSafari = v } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingSwitch("Měřit čas u obrazovky", detail: "Čas v aplikacích a na webech po hodinách, jen na tomto Macu. Bez myši a klávesnice déle než \(focus.config.tracking.idleMinutes) min se nepočítá.",
                              isOn: Binding(get: { focus.config.tracking.enabled }, set: { v in focus.update { $0.tracking.enabled = v } }))
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var guardDetail: String {
        switch focus.status {
        case .running: "Běží – blokuje i bez otevřené aplikace. Je vidět v Nastavení systému → Obecné → Položky při přihlášení."
        case .starting: "Zapíná se…"
        case .off, .unavailable: "Pomocník, který blokuje aplikace a weby. macOS ohlásí novou položku na pozadí."
        }
    }

    private var safariDetail: String {
        guard focus.config.watchSafari else { return "Vypnuto – weby blokuje jen rozšíření a čas na webech se neměří." }
        return switch focus.report?.safari {
        case .on: "Pojistka k rozšíření a měření času na webech."
        case .needsPermission: "Chybí souhlas: Nastavení systému → Soukromí a zabezpečení → Automatizace → Strážce → Safari."
        default: "Strážce se zeptá na souhlas, až poběží Safari."
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
                    ForEach([15, 30, 60, 90, 120, 180, 240, 480], id: \.self) { m in Text(m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min").tag(m) }
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

    private func detail(_ plan: FocusPlan) -> String {
        var parts = [FocusText.trigger(plan.trigger)]
        let names = plan.listIds.compactMap { focus.config.list($0)?.name }
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        if let s = plan.strictness { parts.append(FocusText.strictness(s)) }
        return parts.joined(separator: " · ")
    }

    private func lock(_ strictness: Strictness?) {
        let end = now + lockMinutes * 60_000
        focus.update {
            $0.locks.removeAll { $0.end <= now }
            $0.locks.append(FocusLock(listIds: $0.lists.map(\.id), start: now, end: end, strictness: strictness))
        }
    }

    private func setPlan(_ id: String, _ change: (inout FocusPlan) -> Void) {
        focus.update { c in
            if let i = c.plans.firstIndex(where: { $0.id == id }) { change(&c.plans[i]) }
        }
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
