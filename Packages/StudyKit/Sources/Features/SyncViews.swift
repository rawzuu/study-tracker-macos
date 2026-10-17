import AppModel
import DesignSystem
import Engine
import Networking
import SwiftUI
import Sync

/// Stav synchronizace v nástrojové liště okna; kliknutí = synchronizovat teď.
public struct SyncStatusButton: View {
    @Environment(AppStore.self) private var store

    public init() {}

    public var body: some View {
        Button {
            Task { await store.syncNow() }
        } label: {
            HStack(spacing: 6) {
                icon
                Text(label).monospacedDigit()
            }
        }
        .disabled(store.sync.status == .off || store.sync.status == .syncing)
        .help(help)
        .accessibilityIdentifier("sync.status")
    }

    @ViewBuilder private var icon: some View {
        switch store.sync.status {
        case .off: Image(systemName: "icloud.slash")
        case .idle: Image(systemName: "icloud")
        case .syncing: ProgressView().controlSize(.small)
        case .synced: Image(systemName: "checkmark.icloud")
        case .failed(let f, _): Image(systemName: f.isTransient ? "icloud.slash" : "exclamationmark.icloud").foregroundStyle(f.isTransient ? Palette.text2 : Palette.danger)
        }
    }

    private var label: String {
        let base: String = switch store.sync.status {
        case .off: "Bez zálohy"
        case .idle: "Připraveno"
        case .syncing: "Synchronizuji…"
        case .synced(let at): "Synchronizováno \(Format.time(Int(at.timeIntervalSince1970 * 1000), clock: store.clock))"
        case .failed(let f, _): f.isTransient ? "Offline" : "Chyba synchronizace"
        }
        return store.isConnected && store.sync.mode == .readOnly ? base + " · jen čtení" : base
    }

    private var help: String {
        switch store.sync.status {
        case .off: "Data jsou jen na tomto Macu. Zálohu na GitHub zapneš v Nastavení."
        case .failed(let f, _): f.localizedDescription
        default: store.sync.mode == .readOnly ? "Data z GitHubu se jen načítají, Mac nic nezapisuje. Kliknutím synchronizuješ hned." : "Kliknutím synchronizuješ hned."
        }
    }
}

/// Upozornění na přehledu: záloha nefunguje (token, přístup, novější data) nebo brzy vyprší token.
struct SyncBanner: View {
    @Environment(AppStore.self) private var store
    @AppStorage("st.dismiss.sync") private var dismissedDay = ""
    let openSettings: () -> Void

    var body: some View {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let today = store.clock.dayKey(now)
        if let text = message(now: now), dismissedDay != today {
            Banner(text, systemImage: "exclamationmark.triangle", tone: .warn) {
                Button("Nastavení", action: openSettings).controlSize(.small)
                Button { dismissedDay = today } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Skrýt")
            }
            .accessibilityIdentifier("dash.syncBanner")
        }
    }

    private func message(now: Int) -> String? {
        let warnings = store.document.settings.tokenWarning
        if case .failed(let f, _) = store.sync.status, !f.isTransient {
            // Problém s tokenem nebo přístupem (401/403/404) hlídá nastavení „upozornit na token“ jako na webu;
            // data, která Mac nesmí zapsat (novější verze, nečitelný soubor), se ukážou vždy.
            if case .github(let e) = f, [401, 403, 404].contains(e.status), !warnings { return nil }
            return "Synchronizace s GitHubem teď nefunguje: \(f.localizedDescription) Data jsou zatím jen na tomto Macu."
        }
        guard warnings, store.sync.status != .off,
              let days = store.backup?.tokenDaysLeft(now: now, clock: store.clock), days <= 7 else { return nil }
        return days <= 0
            ? "Token pro zálohu na GitHub vypršel – vytvoř nový, ať se synchronizace nezastaví."
            : "Token pro zálohu na GitHub vyprší za \(days) \(Format.plural(days, "den", "dny", "dní")) – vytvoř nový, ať se synchronizace nezastaví."
    }
}

/// Nastavení → Synchronizace s GitHubem: vložení tokenu, stav, odpojení.
public struct SyncSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var token = ""
    @State private var location = RepoLocation(owner: "")
    @State private var showsAdvanced = false
    @State private var knowsExpiry = false
    @State private var expiry = Date().addingTimeInterval(365 * 86_400)
    @State private var connecting = false
    @State private var error: String?
    @State private var confirmsDisconnect = false

    public init() {}

    public var body: some View {
        PageSection("Synchronizace s GitHubem", accessory: { statusChip }) {
            VStack(alignment: .leading, spacing: 16) {
                if case .failed(let f, _) = store.sync.status {
                    Banner(f.localizedDescription, systemImage: "exclamationmark.triangle", tone: f.isTransient ? .neutral : .bad)
                }
                if let backup = store.backup {
                    connected(backup)
                } else {
                    connectForm
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .accessibilityIdentifier("settings.sync")
    }

    @ViewBuilder private var statusChip: some View {
        switch store.sync.status {
        case .off: Chip("Vypnuto – data jsou jen na tomto Macu", tone: .warn)
        case .syncing: Chip("Synchronizuji…")
        case .synced(let at): Chip("Synchronizováno \(Format.time(Int(at.timeIntervalSince1970 * 1000), clock: store.clock))", systemImage: "checkmark.circle", tone: .ok)
        case .failed: Chip("Chyba", systemImage: "exclamationmark.triangle", tone: .bad)
        case .idle: Chip("Připraveno")
        }
    }

    // MARK: Připojeno

    private func connected(_ backup: BackupConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Data se ukládají do **\(backup.location.owner)/\(backup.location.repo)** → `\(backup.location.path)` (větev \(backup.location.branch)). Každá změna je commit, takže je vidět celá historie.")
                .foregroundStyle(Palette.text2)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(
                get: { store.sync.mode == .readOnly },
                set: { readOnly in Task { await store.setSyncMode(readOnly ? .readOnly : .readWrite) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jen čtení")
                    Text("Mac data z GitHubu jen načítá a nic nezapisuje; úpravy na Macu jsou vypnuté.")
                        .font(Typo.small).foregroundStyle(Palette.text3)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.readOnly")
            expiryRow(backup)
            HStack(spacing: 10) {
                Button {
                    Task { await store.syncNow() }
                } label: {
                    Label("Synchronizovat teď", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.sync.status == .syncing)
                if let url = backup.location.commitsURL {
                    Link("Historie změn", destination: url)
                }
                Spacer()
                Button("Odpojit…", role: .destructive) { confirmsDisconnect = true }
            }
        }
        .confirmationDialog("Odpojit GitHub?", isPresented: $confirmsDisconnect) {
            Button("Odpojit", role: .destructive) { Task { await store.disconnect() } }
        } message: {
            Text("Data v repu i na Macu zůstanou, jen se přestanou synchronizovat. Token se smaže z Klíčenky.")
        }
    }

    private func expiryRow(_ backup: BackupConfig) -> some View {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let days = backup.tokenDaysLeft(now: now, clock: store.clock)
        return HStack(spacing: 10) {
            Text("Token platí do").foregroundStyle(Palette.text2)
            DatePicker("Platnost tokenu", selection: Binding(
                get: { backup.expires.flatMap(store.clock.parseDayKey).map(store.clock.date) ?? Date() },
                set: { store.setTokenExpiry(store.clock.dayKey(store.clock.ms($0))) }
            ), displayedComponents: .date)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "cs_CZ"))
            if let days {
                Chip(days <= 0 ? "vypršel" : "zbývá \(days) \(Format.plural(days, "den", "dny", "dní"))", tone: days <= 14 ? .warn : .neutral)
                Button("Nevím") { store.setTokenExpiry(nil) }.buttonStyle(.link)
            } else {
                Text("nepovinné – aplikace pak připomene výměnu").font(Typo.small).foregroundStyle(Palette.text3)
            }
        }
        .font(Typo.body)
    }

    // MARK: Připojení

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            instructions
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Token").foregroundStyle(Palette.text2)
                    SecureField("github_pat_…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .accessibilityIdentifier("settings.token")
                        .onSubmit(connect)
                }
                GridRow {
                    Toggle("Znám datum vypršení", isOn: $knowsExpiry).toggleStyle(.checkbox).gridCellColumns(1)
                    HStack {
                        DatePicker("Platnost tokenu do", selection: $expiry, displayedComponents: .date)
                            .labelsHidden()
                            .disabled(!knowsExpiry)
                            .environment(\.locale, Locale(identifier: "cs_CZ"))
                        Text("GitHub ho ukáže při vytvoření tokenu – aplikace pak včas připomene výměnu.")
                            .font(Typo.small).foregroundStyle(Palette.text3)
                    }
                }
            }
            DisclosureGroup("Jiné repo, větev nebo soubor", isExpanded: $showsAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    field("GitHub jméno", $location.owner, prompt: "zjistí se z tokenu")
                    field("Repo s daty", $location.repo)
                    field("Větev", $location.branch)
                    field("Soubor", $location.path)
                }
                .padding(.top, 8)
            }
            .foregroundStyle(Palette.text2)
            if let error {
                Banner(error, systemImage: "exclamationmark.triangle", tone: .bad).accessibilityIdentifier("settings.error")
            }
            Button(action: connect) {
                Label(connecting ? "Ověřuji…" : "Připojit a synchronizovat", systemImage: "icloud.and.arrow.down")
            }
            .buttonStyle(.primary)
            .disabled(connecting || token.trimmingCharacters(in: .whitespaces).isEmpty || location.repo.isEmpty || location.branch.isEmpty || location.path.isEmpty)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("settings.connect")
        }
    }

    private func field(_ label: String, _ value: Binding<String>, prompt: String = "") -> some View {
        GridRow {
            Text(label)
            TextField(label, text: value, prompt: Text(prompt)).textFieldStyle(.roundedBorder).frame(maxWidth: 320).labelsHidden()
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Jak připojit data (asi 3 minuty):").fontWeight(.semibold)
            Text("0. Pokud ještě nemáš soukromé repo na data, [založ ho tady](https://github.com/new?name=study-tracker-data&visibility=private&description=Data+pro+Study+Tracker) (Private, zaškrtni „Add a README“). Když už web zálohuje, použij stejné repo.")
            Text("1. Otevři [GitHub → Fine-grained tokens → Generate new token](https://github.com/settings/personal-access-tokens/new).")
            Text("2. *Repository access* → *Only select repositories* → vyber `\(location.repo.isEmpty ? RepoLocation.defaultRepo : location.repo)`.")
            Text("3. *Permissions* → *Contents* → **Read and write**.")
            Text("4. Pojmenuj ho třeba „Study Tracker – Mac“, expiraci nastav na rok, token zkopíruj a vlož sem. Každé zařízení má vlastní token.")
            Text("Token se uloží do Klíčenky macOS a má přístup jen k datovému repu.").foregroundStyle(Palette.text3)
        }
        .font(Typo.body)
        .foregroundStyle(Palette.text2)
        .tint(Palette.text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.lineStrong))
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        error = nil
        let expires = knowsExpiry ? store.clock.dayKey(store.clock.ms(expiry)) : nil
        Task {
            do {
                try await store.connect(token: token, location: location, expires: expires)
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

/// Stránka Nastavení (v M1 jen synchronizace; zbytek v M6).
public struct SettingsPage: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                PageHeader("Nastavení", subtitle: "Ostatní nastavení přibude v milníku M6.")
                SyncSettingsView()
                TimerSoundSettings()
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageBackground()
        .navigationTitle("Nastavení")
    }
}
