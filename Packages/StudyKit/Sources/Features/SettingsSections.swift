import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI
import UniformTypeIdentifiers

// Sekce Nastavení, které web má a Mac přebírá (`SettingsPage.tsx`, `FeaturesSection.tsx`, `TrashSection.tsx`).
// Všechno kromě souborů zálohy je synchronizované nastavení – změna platí i na webu.

// MARK: - Řádky

/// Přepínač s popisem; přepínač vpravo.
struct SettingSwitch: View {
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
        SettingRow(title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).accessibilityIdentifier(id)
        }
    }
}

/// Název a popis vlevo, ovládací prvek vpravo (`Row` na webu).
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
        }
    }
}

/// Vazba na jedno synchronizované nastavení.
@MainActor
private func setting<T>(_ store: AppStore, _ key: WritableKeyPath<Core.Settings, T>) -> Binding<T> {
    Binding(get: { store.document.settings[keyPath: key] }, set: { v in store.updateSettings { $0[keyPath: key] = v } })
}

// MARK: - Vzhled a cíle

struct GoalsSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        PageSection("Vzhled a cíle") {
            VStack(alignment: .leading, spacing: 16) {
                SettingRow("Motiv") {
                    Picker("Motiv", selection: setting(store, \.theme)) {
                        Text("Tmavý").tag(ThemePreference.dark)
                        Text("Světlý").tag(ThemePreference.light)
                        Text("Systém").tag(ThemePreference.system)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.theme")
                }
                SettingRow("Denní cíl", detail: "Kolik minut denně se chceš učit. 0 = bez cíle.") {
                    NumberField(value: setting(store, \.dailyGoalMin), in: 0...1440, step: 15)
                        .accessibilityIdentifier("settings.dailyGoal")
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .disabled(!store.canEditShared)
        }
    }
}

// MARK: - Chování časovače

/// Pravidla časovače (část „Časovač“ na webu) – doplňuje zvuk a notifikace v `TimerSoundSettings`.
struct TimerBehaviorRows: View {
    @Environment(AppStore.self) private var store
    @Environment(TimerStore.self) private var timer

    var body: some View {
        let s = store.document.settings
        VStack(alignment: .leading, spacing: 16) {
            SettingRow("Výchozí režim") {
                Picker("Výchozí režim", selection: setting(store, \.defaultMode)) {
                    ForEach(timer.modes, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.defaultMode")
            }
            SettingSwitch("Automaticky spustit pauzu", detail: "Po konci bloku práce rovnou běží pauza.", isOn: setting(store, \.autoStartBreaks))
            SettingSwitch("Automaticky spustit další blok", detail: "Po pauze rovnou začne další blok práce.", isOn: setting(store, \.autoStartWork))
            SettingSwitch("Hodnotit soustředění", detail: "Po každém bloku se zeptá na hodnocení 1–5. Díky tomu uvidíš, kdy se učíš nejlépe.",
                          isOn: setting(store, \.askFocusRating), id: "settings.askFocus")
            SettingSwitch("Vybavení po bloku", detail: "Po bloku vyzve k sepsání hlavních bodů z hlavy (retrieval practice). Jde vždy přeskočit.",
                          isOn: setting(store, \.askRecall))
            SettingRow("Ukončit čekající časovač", detail: "Když časovač mezi bloky čeká na „Další blok“ déle, sám se ukončí. Hotové bloky zůstávají uložené.") {
                Picker("Ukončit čekající časovač", selection: setting(store, \.seriesTimeoutMin)) {
                    Text("nikdy").tag(0)
                    Text("po 20 min").tag(20)
                    Text("po hodině").tag(60)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingRow("Flowtime – poměr pauzy", detail: "Pauza = práce ÷ \(JSNumber.format(s.flowtimeRatio)) (50 min práce → \(Int((50 / s.flowtimeRatio).rounded())) min pauza)") {
                NumberField(value: Binding(get: { Int(s.flowtimeRatio.rounded()) }, set: { v in store.updateSettings { $0.flowtimeRatio = Double(v) } }), in: 2...10)
            }
            SettingRow("Minimální délka sezení", detail: "Kratší bloky (v sekundách) se neukládají.") {
                NumberField(value: setting(store, \.minSessionSec), in: 0...3600, step: 30)
            }
        }
        // Nová pravidla (konec fáze, ukončení série) platí hned i pro běžící časovač.
        .onChange(of: TimerRules(settings: s)) { timer.refresh() }
    }
}

// MARK: - Funkce

/// Volitelné funkce (`FeaturesSection` na webu) – jen ty, které Mac opravdu používá.
struct FeaturesSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        PageSection("Funkce") {
            VStack(alignment: .leading, spacing: 16) {
                SettingSwitch("Ranní výzva k plánování", detail: "Dopoledne na stránce Dnes nabídne naplánovat den.", isOn: setting(store, \.morningPrompt))
                SettingSwitch("Hotový blok zapsat jako odučený",
                              detail: "Tlačítko Hotovo u bloku v kalendáři nabídne zapsat jeho čas, aby se započítal do přehledu. Vypnuté jen odškrtne plán.",
                              isOn: setting(store, \.blockDoneLogs))
                SettingRow("Dny volna v sérii", detail: "Kolik dní bez učení za týden sérii nepřeruší.") {
                    Picker("Dny volna v sérii", selection: setting(store, \.streakRestDays)) {
                        Text("žádné").tag(0)
                        Text("1 týdně").tag(1)
                        Text("2 týdně").tag(2)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingRow("Den se počítá do série", detail: "Minimum učení, aby den sérii prodloužil.") {
                    Picker("Den se počítá do série", selection: setting(store, \.streakMinMin)) {
                        Text("jakékoli").tag(0)
                        Text("od 10 min").tag(10)
                        Text("od 25 min").tag(25)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                SettingSwitch("Hlídat zálohu na GitHub", detail: "Upozorní, když záloha selhává nebo se blíží konec platnosti tokenu.",
                              isOn: setting(store, \.tokenWarning))
            }
            .frame(maxWidth: 720, alignment: .leading)
            .disabled(!store.canEditShared)
        }
    }
}

// MARK: - Vlastní režimy časovače

struct PresetsSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @State private var name = ""
    @State private var work = 45
    @State private var short = 8
    @State private var long = 20
    @State private var rounds = 3

    var body: some View {
        let presets = store.document.alive(TimerPreset.self)
        PageSection("Vlastní režimy časovače") {
            VStack(alignment: .leading, spacing: 14) {
                if !presets.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(presets.enumerated()), id: \.element.id) { i, p in
                            ListRow(divider: i < presets.count - 1) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).fontWeight(.semibold)
                                    Text("\(JSNumber.format(p.workMin)) min práce · \(JSNumber.format(p.shortBreakMin)) min pauza · \(JSNumber.format(p.longBreakMin)) min dlouhá po \(p.roundsBeforeLong) kolech")
                                        .font(Typo.small).foregroundStyle(Palette.text3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button { remove(p) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.study(.ghost, size: .small))
                                    .help("Smazat režim")
                                    .accessibilityLabel("Smazat režim \(p.name)")
                            }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    FormField("Název") {
                        TextField("Můj režim", text: $name).textFieldStyle(.roundedBorder).frame(width: 150)
                            .accessibilityIdentifier("settings.preset.name")
                    }
                    FormField("Práce (min)") { NumberField(value: $work, in: 1...240) }
                    FormField("Pauza (min)") { NumberField(value: $short, in: 1...120) }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    FormField("Dlouhá pauza (min)") { NumberField(value: $long, in: 1...120) }
                    FormField("Kol do dlouhé pauzy") { NumberField(value: $rounds, in: 1...12) }
                    Button(action: add) { Label("Přidat režim", systemImage: "plus") }
                        .buttonStyle(.study(.normal))
                        .accessibilityIdentifier("settings.preset.add")
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .disabled(!store.canEditShared)
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsert(TimerPreset(raw: [
            "id": .string(TimerPreset.newID()), "name": .string(trimmed.isEmpty ? "\(work) / \(short)" : trimmed),
            "workMin": .number(Double(work)), "shortBreakMin": .number(Double(short)), "longBreakMin": .number(Double(long)),
            "roundsBeforeLong": .number(Double(rounds)),
        ]))
        name = ""
    }

    private func remove(_ preset: TimerPreset) {
        store.remove(.presets, id: preset.id)
        toasts.show("Režim smazán") { [store] in store.restore(.presets, id: preset.id) }
    }
}

// MARK: - Záloha do souboru

struct BackupSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @State private var error: String?

    var body: some View {
        PageSection("Záloha") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Export JSON uloží všechna data do souboru. CSV otevřeš v Excelu nebo Numbers. Import zálohu **sloučí** s aktuálními daty – nic nepřepíše ani nesmaže.")
                    .font(Typo.small).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                if let error {
                    Banner(error, systemImage: "exclamationmark.triangle", tone: .bad)
                }
                HStack(spacing: 8) {
                    Button { save(store.backupText(), name: "study-tracker-zaloha", type: .json) } label: { Label("Exportovat JSON", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.study(.normal))
                        .accessibilityIdentifier("settings.backup.export")
                    Button { save(SessionsCSV.make(store.document, clock: store.clock), name: "study-tracker-sezeni", type: .commaSeparatedText) } label: {
                        Label("Sezení do CSV", systemImage: "tablecells")
                    }
                    .buttonStyle(.study(.normal))
                    Button(action: importBackup) { Label("Importovat zálohu", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.study(.normal))
                        .disabled(!store.canEditShared)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func save(_ text: String, name: String, type: UTType) {
        error = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(name)-\(store.clock.dayKey(store.nowMs)).\(type.preferredFilenameExtension ?? "txt")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            self.error = "Soubor se nepodařilo uložit: \(error.localizedDescription)"
        }
    }

    private func importBackup() {
        error = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importBackup(Data(contentsOf: url))
            toasts.show("Záloha sloučena s aktuálními daty")
        } catch let schema as SchemaError {
            error = "Import selhal: \(schema.description)"
        } catch {
            self.error = "Import selhal: soubor není záloha Study Trackeru (\(error.localizedDescription))."
        }
    }
}

// MARK: - Koš

struct TrashSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(Toasts.self) private var toasts
    @State private var showsAll = false

    var body: some View {
        let clock = store.clock
        let now = store.nowMs
        let items = Trash.items(store.document, now: now, clock: clock)
        let shown = showsAll ? items : Array(items.prefix(6))
        PageSection("Koš", accessory: { Text(items.isEmpty ? "posledních \(Trash.days) dní" : "\(items.count) za \(Trash.days) dní") }) {
            VStack(alignment: .leading, spacing: 8) {
                if items.isEmpty {
                    Text("Prázdný. Smazané sezení, zkoušku, blok plánu nebo předmět tu najdeš ještě \(Trash.days) dní.")
                        .font(Typo.small).foregroundStyle(Palette.text3)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                            ListRow(divider: i < shown.count - 1) {
                                VStack(alignment: .leading, spacing: 2) {
                                    (Text(item.label).foregroundStyle(Palette.text3) + Text(" ") + Text(item.title).fontWeight(.semibold))
                                        .lineLimit(1)
                                    Text((item.detail.isEmpty ? "" : "\(item.detail) · ") + "smazáno \(Format.dayLabel(item.deletedAt, now: now, clock: clock).lowercased()) \(Format.time(item.deletedAt, clock: clock))")
                                        .font(Typo.small).foregroundStyle(Palette.text3).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    store.restore(item.key, id: item.id)
                                    toasts.show("Obnoveno: \(item.title)")
                                } label: { Label("Obnovit", systemImage: "arrow.uturn.backward") }
                                    .buttonStyle(.study(.normal, size: .small))
                                    .disabled(!store.canEditShared)
                            }
                        }
                    }
                    if items.count > shown.count {
                        Button("Zobrazit vše (\(items.count))") { showsAll = true }.buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .accessibilityIdentifier("settings.trash")
    }
}

// MARK: - O datech

struct AboutDataSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let doc = store.document
        PageSection("O datech") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Verze schématu **\(doc.schemaVersion)** · předmětů \(doc.alive(Subject.self).count) · sezení \(doc.alive(Session.self).count) · bloků plánu \(doc.alive(PlanBlock.self).count) · zkoušek \(doc.alive(Exam.self).count)")
                    .font(Typo.small).foregroundStyle(Palette.text2)
                Text("Data jsou uložená na tomto Macu a synchronizují se do tvého soukromého repa na GitHubu – stejná data jako na webu a v mobilu.")
                    .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                SettingSwitch("Zobrazovat Reflexi", detail: "Týdenní reflexe v nabídce. Skrytím se nic nesmaže – po zapnutí je vše zpátky.",
                              isOn: Binding(get: { !doc.settings.hiddenPages.contains("reflexe") }, set: { show in
                                  store.updateSettings { s in
                                      s.hiddenPages = show ? s.hiddenPages.filter { $0 != "reflexe" } : s.hiddenPages + ["reflexe"]
                                  }
                              }))
                    .disabled(!store.canEditShared)
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}
