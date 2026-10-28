import AppKit
import AppModel
import DesignSystem
import Focus
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Seznam

/// Úprava seznamu: název, režim, aplikace, weby, výjimky, slova v adrese, co s aplikací a přísnost.
struct FocusListEditor: View {
    @Environment(FocusController.self) private var focus
    @Environment(\.dismiss) private var dismiss
    @State private var list: FocusList
    @State private var sites: String
    @State private var allowed: String
    @State private var keywords: String
    private let isNew: Bool

    init(list: FocusList, isNew: Bool) {
        _list = State(initialValue: list)
        _sites = State(initialValue: list.sites.joined(separator: "\n"))
        _allowed = State(initialValue: list.allowedSites.joined(separator: "\n"))
        _keywords = State(initialValue: list.keywords.joined(separator: ", "))
        self.isNew = isNew
    }

    var body: some View {
        EditorSheet(isNew ? "Nový seznam" : "Upravit seznam", width: 620) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FormField("Název") { TextField("Název", text: $list.name).textFieldStyle(.roundedBorder).labelsHidden() }
                    Picker("Režim", selection: $list.mode) {
                        Text("Blokovat tyhle").tag(FocusList.Mode.block)
                        Text("Povolit jen tyhle").tag(FocusList.Mode.allowOnly)
                    }
                    .pickerStyle(.segmented)
                    Text(list.mode == .block ? "Zablokuje aplikace a weby ze seznamu." :
                            "Zablokuje všechno ostatní – i celý Mac kromě Study Trackeru a systému. Prázdná část (třeba žádné weby) nic neomezuje.")
                        .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                    apps
                    FormField("Weby", hint: "Jeden na řádek: doména platí i se subdoménami (youtube.com), nebo jen část webu (youtube.com/shorts).") {
                        TextArea("youtube.com\nreddit.com", text: $sites, minHeight: 90)
                    }
                    invalidSites
                    if list.mode == .block {
                        FormField("Výjimky", hint: "Zůstanou povolené, i když je doména v seznamu – třeba youtube.com/playlist.") {
                            TextArea(text: $allowed, minHeight: 44)
                        }
                        FormField("Slova v adrese", hint: "Zablokují kterýkoli web s tímhle slovem v adrese (aspoň 3 znaky, oddělit čárkou).") {
                            TextField("serial, game", text: $keywords).textFieldStyle(.roundedBorder).labelsHidden()
                        }
                    }
                    Picker("Zakázaná aplikace", selection: $list.appAction) {
                        Text("Schovat a ukázat blokovací obrazovku").tag(FocusList.AppAction.shield)
                        Text("Ukončit").tag(FocusList.AppAction.quit)
                    }
                    StrictnessEditor(strictness: $list.strictness)
                }
                .padding(.trailing, 12)
            }
            .frame(height: 560)
        } footer: {
            if !isNew {
                Button("Smazat seznam", role: .destructive) {
                    let id = list.id
                    focus.update { c in
                        c.lists.removeAll { $0.id == id }
                        for i in c.plans.indices { c.plans[i].listIds.removeAll { $0 == id } }
                        for i in c.locks.indices { c.locks[i].listIds.removeAll { $0 == id } }
                    }
                    dismiss()
                }
                .buttonStyle(.study(.ghost))
            }
            Spacer()
            Button("Zrušit") { dismiss() }.buttonStyle(.study(.normal)).keyboardShortcut(.cancelAction)
            Button("Uložit") { save() }.buttonStyle(.study(.primary)).keyboardShortcut(.defaultAction)
                .disabled(list.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("focusList.save")
        }
    }

    private var apps: some View {
        FormField("Aplikace") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(list.apps, id: \.bundleId) { app in
                    ListRow {
                        AppIconView(bundleId: app.bundleId)
                        Text(app.name)
                        Spacer()
                        Button { list.apps.removeAll { $0.bundleId == app.bundleId } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.study(.ghost, size: .small)).help("Odebrat")
                    }
                }
                HStack(spacing: 8) {
                    Button("Vybrat z Aplikací…") { pickApps() }.buttonStyle(.study(.normal, size: .small))
                    Menu("Spuštěné") {
                        ForEach(Self.runningApps(), id: \.bundleId) { app in
                            Button(app.name) { add(app) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var invalidSites: some View {
        let bad = lines(sites).filter { SiteRule($0) == nil }
        if !bad.isEmpty {
            Text("Tohle není web: \(bad.joined(separator: ", "))").font(Typo.small).foregroundStyle(Palette.danger)
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func add(_ app: FocusApp) {
        guard !list.apps.contains(where: { $0.bundleId == app.bundleId }) else { return }
        list.apps.append(app)
    }

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "Přidat"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            add(FocusApp(bundleId: id, name: name))
        }
    }

    static func runningApps() -> [FocusApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { FocusApp(bundleId: $0, name: app.localizedName ?? $0) } }
            .filter { !ActiveFocus.isAlwaysAllowed($0.bundleId) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func save() {
        list.name = list.name.trimmingCharacters(in: .whitespaces)
        list.sites = lines(sites).compactMap { SiteRule($0)?.text }
        list.allowedSites = lines(allowed).compactMap { SiteRule($0)?.text }
        list.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let saved = list
        focus.update { c in
            if let i = c.lists.firstIndex(where: { $0.id == saved.id }) {
                c.lists[i] = saved
            } else {
                c.lists.append(saved)
                // Nový seznam rovnou do plánů (nejčastěji jen „během bloku učení“).
                for i in c.plans.indices { c.plans[i].listIds.append(saved.id) }
            }
        }
        dismiss()
    }
}

/// Ikona aplikace podle bundle id (z LaunchServices).
struct AppIconView: View {
    let bundleId: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app.dashed").foregroundStyle(Palette.text3)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Přísnost

/// Přísnost: hotové úrovně a jednotlivé překážky (dají se kombinovat).
struct StrictnessEditor: View {
    @Binding var strictness: Strictness
    @State private var newPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Přísnost").font(Typo.heading)
                Spacer()
                Menu("Hotové úrovně") {
                    ForEach(FocusText.strictnessPresets, id: \.0) { name, s in Button(name) { strictness = s } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            SettingSwitch("Přísný zámek", detail: "Do konce bloku nejde zrušit vůbec – ani změnou nastavení, ukončením aplikace nebo restartem.",
                          isOn: $strictness.locked)
            if !strictness.locked {
                SettingRow("Odklad", detail: "Odemknutí začne platit až po tolika minutách od žádosti (0 = hned).") {
                    NumberField(value: $strictness.delayMinutes, in: 0...120)
                }
                SettingRow("Opsat text", detail: "Počet znaků náhodného textu, který je potřeba ručně opsat (0 = bez opisování).") {
                    NumberField(value: $strictness.typingCharacters, in: 0...1000, step: 10)
                }
                SettingRow("Odemknutí za týden", detail: "Kolikrát týdně jde odemknout (od pondělí). Vypnuto = bez omezení.") {
                    HStack(spacing: 6) {
                        if strictness.weeklyAllowance != nil {
                            NumberField(value: Binding(get: { strictness.weeklyAllowance ?? 3 }, set: { strictness.weeklyAllowance = $0 }), in: 0...50)
                        }
                        Toggle("Omezit", isOn: Binding(get: { strictness.weeklyAllowance != nil }, set: { strictness.weeklyAllowance = $0 ? 3 : nil }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingSwitch("Až po restartu Macu", detail: "Žádost o odemknutí platí až po restartu – impulz mezitím obvykle přejde.",
                              isOn: $strictness.requireRestart)
                SettingRow("Heslo", detail: strictness.password == nil
                    ? "Odemknout jde jen s heslem, které zná někdo jiný (zadá ho sám, ty ho neznáš)."
                    : "Nastavené. Odemknout jde jen s ním.") {
                    if strictness.password == nil {
                        HStack(spacing: 6) {
                            SecureField("Heslo", text: $newPassword).textFieldStyle(.roundedBorder).frame(width: 140)
                            Button("Nastavit") {
                                strictness.password = Unlock.makePassword(newPassword)
                                newPassword = ""
                            }
                            .buttonStyle(.study(.normal, size: .small))
                            .disabled(newPassword.count < 4)
                        }
                    } else {
                        Button("Zrušit heslo") { strictness.password = nil }.buttonStyle(.study(.ghost, size: .small))
                    }
                }
                SettingRow("Odemykat jen", detail: "Odemknout jde jen v tomhle čase (třeba večer). Vypnuto = kdykoli.") {
                    HStack(spacing: 6) {
                        if let w = strictness.unlockWindows.first {
                            MinutePicker(minutes: Binding(get: { w.start }, set: { strictness.unlockWindows = [TimeWindow(weekdays: Array(0...6), start: $0, end: w.end)] }))
                            Text("–")
                            MinutePicker(minutes: Binding(get: { w.end % 1440 }, set: { strictness.unlockWindows = [TimeWindow(weekdays: Array(0...6), start: w.start, end: $0 == 0 ? 1440 : $0)] }))
                        }
                        Toggle("Odemykat jen", isOn: Binding(get: { !strictness.unlockWindows.isEmpty }, set: {
                            strictness.unlockWindows = $0 ? [TimeWindow(weekdays: Array(0...6), start: 18 * 60, end: 22 * 60)] : []
                        }))
                        .labelsHidden().toggleStyle(.switch)
                    }
                }
                SettingRow("Odemknout na", detail: "Jak dlouho odemknutí platí.") {
                    HStack(spacing: 4) { NumberField(value: $strictness.unlockMinutes, in: 1...120); Text("min").foregroundStyle(Palette.text3) }
                }
            }
        }
    }
}

/// Čas dne (minuty od půlnoci) jako výběr hodin a minut.
struct MinutePicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("", selection: Binding(get: {
            Calendar.current.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: Date(timeIntervalSince1970: 0)) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
        .frame(width: 70)
    }
}

// MARK: - Plán

/// Úprava plánu: kdy, které seznamy a volitelně vlastní přísnost.
struct FocusPlanEditor: View {
    @Environment(FocusController.self) private var focus
    @Environment(\.dismiss) private var dismiss
    @State private var plan: FocusPlan
    @State private var kind: Kind
    @State private var study: StudyBlockOptions
    @State private var windows: [TimeWindow]
    @State private var limit: Int
    private let isNew: Bool

    enum Kind: String, CaseIterable, Identifiable {
        case study = "Blok učení", schedule = "Časová okna", plan = "Studijní plán", limit = "Denní limit"
        var id: String { rawValue }
    }

    init(plan: FocusPlan, isNew: Bool) {
        _plan = State(initialValue: plan)
        var study = StudyBlockOptions(), windows = [TimeWindow(weekdays: [0, 1, 2, 3, 4], start: 8 * 60, end: 16 * 60)], limit = 30
        let kind: Kind
        switch plan.trigger {
        case let .studyBlock(o): kind = .study; study = o
        case let .schedule(w): kind = .schedule; windows = w.isEmpty ? windows : w
        case .studyPlan: kind = .plan
        case let .dailyLimit(m): kind = .limit; limit = m
        }
        _kind = State(initialValue: kind)
        _study = State(initialValue: study)
        _windows = State(initialValue: windows)
        _limit = State(initialValue: limit)
        self.isNew = isNew
    }

    var body: some View {
        EditorSheet(isNew ? "Nový plán" : "Upravit plán", width: 620) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FormField("Název") { TextField("Název", text: $plan.name).textFieldStyle(.roundedBorder).labelsHidden() }
                    Picker("Kdy", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    trigger
                    FormField("Seznamy") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(focus.config.lists) { list in
                                Toggle(list.name, isOn: Binding(get: { plan.listIds.contains(list.id) }, set: { on in
                                    if on { plan.listIds.append(list.id) } else { plan.listIds.removeAll { $0 == list.id } }
                                }))
                            }
                        }
                    }
                    SettingSwitch("Vlastní přísnost", detail: "Místo přísnosti jednotlivých seznamů (přísnější z obou platí vždy).",
                                  isOn: Binding(get: { plan.strictness != nil }, set: { plan.strictness = $0 ? .strict : nil }))
                    if plan.strictness != nil {
                        StrictnessEditor(strictness: Binding(get: { plan.strictness ?? .soft }, set: { plan.strictness = $0 }))
                    }
                }
                .padding(.trailing, 12)
            }
            .frame(height: 520)
        } footer: {
            Spacer()
            Button("Zrušit") { dismiss() }.buttonStyle(.study(.normal)).keyboardShortcut(.cancelAction)
            Button("Uložit") { save() }.buttonStyle(.study(.primary)).keyboardShortcut(.defaultAction)
                .disabled(plan.name.trimmingCharacters(in: .whitespaces).isEmpty || plan.listIds.isEmpty)
                .accessibilityIdentifier("focusPlan.save")
        }
    }

    @ViewBuilder private var trigger: some View {
        switch kind {
        case .study:
            SettingSwitch("I o přestávce", detail: "Jinak je přestávka v časovači volná.", isOn: $study.duringBreaks)
            SettingSwitch("I v pozastaveném bloku", detail: "Jinak by stačilo blok pozastavit.", isOn: $study.whilePaused)
        case .schedule:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(windows.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        WeekdayToggles(days: $windows[i].weekdays)
                        MinutePicker(minutes: $windows[i].start)
                        Text("–")
                        MinutePicker(minutes: Binding(get: { windows[i].end % 1440 }, set: { windows[i].end = $0 == 0 ? 1440 : $0 }))
                        Button { windows.remove(at: i) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.study(.ghost, size: .small)).disabled(windows.count == 1)
                    }
                }
                Button("Přidat okno") { windows.append(TimeWindow(weekdays: [5, 6], start: 9 * 60, end: 12 * 60)) }
                    .buttonStyle(.study(.ghost, size: .small))
                Text("Konec před začátkem = přes půlnoc (22:00–2:00).").font(Typo.small).foregroundStyle(Palette.text3)
            }
        case .plan:
            Text("Blokuje během bloků Studijního plánu na dnešek (jako v Kalendáři); splněný blok už ne.")
                .font(Typo.small).foregroundStyle(Palette.text3)
        case .limit:
            SettingRow("Denně", detail: "Po tolika minutách v aplikacích a na webech ze seznamů se do půlnoci blokuje. Potřebuje měření času.") {
                HStack(spacing: 4) { NumberField(value: $limit, in: 1...600, step: 5); Text("min").foregroundStyle(Palette.text3) }
            }
        }
    }

    private func save() {
        plan.name = plan.name.trimmingCharacters(in: .whitespaces)
        plan.trigger = switch kind {
        case .study: .studyBlock(study)
        case .schedule: .schedule(windows.filter { !$0.weekdays.isEmpty })
        case .plan: .studyPlan
        case .limit: .dailyLimit(minutes: limit)
        }
        let saved = plan
        focus.update { c in
            if let i = c.plans.firstIndex(where: { $0.id == saved.id }) { c.plans[i] = saved } else { c.plans.append(saved) }
        }
        dismiss()
    }
}

/// Dny v týdnu Po–Ne jako přepínače.
struct WeekdayToggles: View {
    @Binding var days: [Int]
    private static let names = ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { d in
                let on = days.contains(d)
                Button(Self.names[d]) {
                    if on { days.removeAll { $0 == d } } else { days = (days + [d]).sorted() }
                }
                .buttonStyle(.study(on ? .primary : .ghost, size: .small))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
