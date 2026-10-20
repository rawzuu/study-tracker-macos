import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Desktopová Anki (`net.ankiweb.dtop`).
enum AnkiApp {
    static let bundleId = "net.ankiweb.dtop"

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }

    static func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Stav synchronizace jako krátký text (`statusText` v `AnkiPanel.tsx`).
@MainActor
func ankiStatusText(_ sync: AnkiSync, today: AnkiImport.Today?, clock: StudyClock, now: Int) -> String {
    let stale = today.map { t in "stav z \(Format.time(t.at, clock: clock))\(t.fresh ? "" : " (\(Format.date(t.at, .dayNumericMonth, clock: clock)))")" }
    switch sync.status {
    case .syncing: return "načítám…"
    case .ok(let at): return "živě · \(Format.time(at, clock: clock))"
    case .failed(let error, _):
        let reason = error == .offline ? "Anki neběží" : "chyba"
        return stale.map { "\(reason) · \($0)" } ?? reason
    case .off: return stale ?? "vypnuto"
    }
}

/// „Anki dnes“ ve sloupci vpravo na stránce Dnes (`AnkiPanel` na webu): kolik karet zbývá, po balíčcích,
/// kolik je hotovo. Nové modře, učené oranžově, k opakování zeleně – jako v Anki.
struct AnkiSummary: View {
    @Environment(AppStore.self) private var store
    @Environment(AnkiSync.self) private var sync
    let now: Int

    var body: some View {
        let clock = store.clock
        let today = AnkiImport.today(store.document, now: now, clock: clock)
        VStack(alignment: .leading, spacing: 11) {
            SummaryTitle("Anki", detail: ankiStatusText(sync, today: today, clock: clock, now: now))
            if let t = today {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t.fresh ? "\(t.due)" : "–").font(Typo.number(24)).foregroundStyle(Palette.text)
                    Text(t.fresh ? "\(Format.plural(t.due, "karta", "karty", "karet")) zbývá" : "stav není z dneška")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.text2)
                    Spacer(minLength: 8)
                    if t.fresh { AnkiCounts(new: t.new, learn: t.learn, review: t.review) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dash.anki.due")
                ForEach(t.decks.prefix(4), id: \.name) { d in
                    HStack(spacing: 10) {
                        Text(d.name).lineLimit(1)
                        Spacer(minLength: 8)
                        AnkiCounts(new: d.newCount, learn: d.learnCount, review: d.reviewCount).font(.system(size: 12))
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack {
                    if t.fresh {
                        Text("dnes hotovo \(t.reviewedToday) \(Format.plural(t.reviewedToday, "karta", "karty", "karet")) · \(Format.duration(t.msToday / 1000))")
                            .font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                    }
                    Spacer(minLength: 8)
                    if AnkiApp.isInstalled { Button("Otevřít Anki") { AnkiApp.open() }.buttonStyle(.link).font(.system(size: 12.5)) }
                }
            } else {
                Text(sync.enabled ? "Čekám na Anki – spusť ji na tomto Macu." : "Anki není propojená – zapni ji v Nastavení.")
                    .font(Typo.small).foregroundStyle(Palette.text3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dash.anki")
    }
}

/// Nové · učené · k opakování.
struct AnkiCounts: View {
    let new: Int
    let learn: Int
    let review: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("\(new)").foregroundStyle(Palette.accent).help("Nové")
            Text("\(learn)").foregroundStyle(Palette.warn).help("Učené")
            Text("\(review)").foregroundStyle(Palette.success).help("K opakování")
        }
        .monospacedDigit()
        .accessibilityLabel("\(new) nových, \(learn) učených, \(review) k opakování")
    }
}

/// Anki v Nastavení (`AnkiSettings.tsx` na webu): zapnutí pro tento Mac, počítání času a přiřazení balíčků k předmětům.
struct AnkiSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(AnkiSync.self) private var sync

    private static let newSubject = "__new__"

    var body: some View {
        let cfg = store.document.settings.anki
        let today = AnkiImport.today(store.document, now: store.nowMs, clock: store.clock)
        PageSection("Anki", accessory: { chip }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Na stránce Dnes uvidíš, kolik karet ti dnes zbývá, a čas strávený v Anki se započítá do statistik i kalendáře. Mac čte desktopovou Anki přímo (bez omezení Safari); na mobilu se ukáže poslední stav z Macu.")
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jak propojit (jednou)").fontWeight(.semibold)
                    Text("1. V Anki: Nástroje → Doplňky → Získat doplňky → kód **2055492159** (AnkiConnect) → restartuj Anki.")
                    Text("2. Nech Anki běžet a zapni přepínač níže.")
                }
                .font(Typo.small).foregroundStyle(Palette.text2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                SettingSwitch("Načítat z Anki na tomto Macu", detail: "Každé 2 minuty a po návratu do aplikace, když Anki běží. Zapnutí platí jen pro tento Mac.",
                              isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }), id: "settings.anki.enabled")
                if sync.enabled {
                    if case .failed(let error, _) = sync.status {
                        Banner(error.localizedDescription, systemImage: "exclamationmark.triangle", tone: error == .offline ? .warn : .bad)
                    }
                    HStack(spacing: 8) {
                        Button { Task { await sync.syncNow() } } label: { Label("Načíst teď", systemImage: "arrow.clockwise") }
                            .buttonStyle(.study(.normal))
                        Button { Task { await sync.syncNow(fullHistory: true) } } label: { Label("Přepočítat historii", systemImage: "clock.arrow.circlepath") }
                            .buttonStyle(.study(.ghost))
                            .help("Znovu načte historii a přepočítá bloky")
                        if AnkiApp.isInstalled { Button("Otevřít Anki") { AnkiApp.open() }.buttonStyle(.study(.ghost)) }
                    }
                    .disabled(sync.status == .syncing)
                }
                SettingSwitch("Započítávat čas z Anki", detail: "Opakování se zapíše jako sezení (blok = opakování bez pauzy delší než 10 min).",
                              isOn: Binding(get: { cfg.countTime }, set: { on in sync.updateSettings { $0.countTime = on } }))
                HStack {
                    Text("Načíst historii").foregroundStyle(Palette.text2)
                    Picker("Načíst historii", selection: Binding(get: { cfg.importDays }, set: { days in sync.updateSettings { $0.importDays = days } })) {
                        ForEach([7, 30, 60, 180, 365], id: \.self) { Text("\($0) dní").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("zpětně při prvním propojení nebo přepočtu").font(Typo.small).foregroundStyle(Palette.text3)
                }
                if let decks = today?.decks, !decks.isEmpty { mapping(decks, cfg: cfg) }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .accessibilityIdentifier("settings.anki")
    }

    @ViewBuilder private var chip: some View {
        switch sync.status {
        case .ok(let at): Chip("připojeno \(Format.time(at, clock: store.clock))", tone: .ok)
        case .syncing: Chip("připojuji…", tone: .accent)
        case .failed: Chip("nepřipojeno", tone: .warn)
        case .off: Chip("vypnuto")
        }
    }

    // MARK: - Balíček → předmět

    private var subjects: [Subject] {
        store.document.alive(Subject.self).filter { !$0.archived && $0.id != AnkiImport.subjectId }
    }

    private func mapping(_ decks: [AnkiDeckStat], cfg: AnkiSettings) -> some View {
        let subjects = subjects
        let valid = Set(subjects.map(\.id))
        let unmapped = decks.filter { !valid.contains(cfg.deckSubjects[$0.name] ?? "") }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Balíček → předmět").fontWeight(.semibold)
                Spacer()
                if !unmapped.isEmpty {
                    Button { createAll(unmapped) } label: {
                        Label("Založit předměty pro \(unmapped.count) \(Format.plural(unmapped.count, "balíček", "balíčky", "balíčků"))", systemImage: "plus")
                    }
                    .buttonStyle(.study(.normal, size: .small))
                }
            }
            ForEach(decks, id: \.name) { d in
                let mapped = cfg.deckSubjects[d.name] ?? ""
                HStack {
                    Text(d.name).lineLimit(1)
                    Text("· \(d.total) karet").font(Typo.small).monospacedDigit().foregroundStyle(Palette.text3)
                    Spacer(minLength: 12)
                    Picker(d.name, selection: Binding(get: { valid.contains(mapped) ? mapped : "" }, set: { choose($0, for: d.name) })) {
                        Text("Anki (samostatně)").tag("")
                        ForEach(subjects) { Text($0.name).tag($0.id) }
                        Divider()
                        Text("Nový předmět „\(Self.prettyName(d.name))“").tag(Self.newSubject)
                    }
                    .labelsHidden()
                    .frame(width: 240, alignment: .trailing)
                }
            }
            Text("Čas strávený v balíčku se zapíše k vybranému předmětu – započítá se do jeho týdenního cíle, statistik a v kalendáři bude mít jeho barvu. Na samotnou Anki to nemá vliv. Po změně se historie přepočítá.")
                .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose(_ value: String, for deck: String) {
        var used = Set(store.document.alive(Subject.self).map(\.color))
        let id = value == Self.newSubject ? subjectFor(deck, used: &used) : value
        sync.updateSettings(recompute: true) { $0.deckSubjects[deck] = id }
    }

    private func createAll(_ decks: [AnkiDeckStat]) {
        var used = Set(store.document.alive(Subject.self).map(\.color))
        let ids = decks.map { ($0.name, subjectFor($0.name, used: &used)) }
        sync.updateSettings(recompute: true) { s in for (deck, id) in ids { s.deckSubjects[deck] = id } }
    }

    /// Předmět se stejným názvem (bez ohledu na velikost písmen a diakritiku), jinak nový v nepoužité barvě.
    private func subjectFor(_ deck: String, used: inout Set<String>) -> String {
        let name = Self.prettyName(deck)
        if let existing = store.document.alive(Subject.self).first(where: { normalizedName($0.name) == normalizedName(name) && $0.id != AnkiImport.subjectId }) {
            return existing.id
        }
        let palette = SubjectDraft.palette
        let color = palette.first { !used.contains($0) } ?? palette[used.count % palette.count]
        used.insert(color)
        let id = Subject.newID()
        store.upsert(Subject(raw: ["id": .string(id), "name": .string(name), "color": .string(color), "weeklyGoalMin": 0, "archived": false]))
        return id
    }

    /// „algoritmizace“ → „Algoritmizace“
    static func prettyName(_ deck: String) -> String {
        guard let first = deck.first else { return deck }
        return String(first).uppercased(with: Locale(identifier: "cs_CZ")) + deck.dropFirst()
    }
}

/// Přepínač s popisem; přepínač vpravo.
private struct SettingSwitch: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var id = ""

    init(_ title: String, detail: String, isOn: Binding<Bool>, id: String = "") {
        self.title = title
        self.detail = detail
        _isOn = isOn
        self.id = id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).accessibilityIdentifier(id)
        }
    }
}
