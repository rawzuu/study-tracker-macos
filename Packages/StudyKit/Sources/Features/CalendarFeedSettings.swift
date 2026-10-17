import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Odebíraný kalendář v Nastavení (`CalendarFeedSection` na webu).
struct CalendarFeedSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(CalendarFeedSync.self) private var feedSync
    @Environment(Toasts.self) private var toasts
    @State private var includeExams = true
    @State private var alarm: Int? = 10
    @State private var error: String?
    @State private var confirmsDisable = false

    var body: some View {
        let feed = store.document.settings.calendarFeed
        PageSection("Odebíraný kalendář", accessory: { feed != nil ? Chip("zapnuto", tone: .ok) : Chip("vypnuto") }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Plán a zkoušky se publikují do tajného gistu na tvém GitHubu. Apple Kalendář si je pak sám pravidelně stahuje, takže nic neimportuješ ručně. Kdo zná odkaz, plán uvidí – nikde ale není vypsaný ani vyhledatelný.")
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let error { Banner(error, systemImage: "exclamationmark.triangle", tone: .bad) }
                if !store.isConnected {
                    Banner("Nejdřív připoj synchronizaci s GitHubem výše.", systemImage: "info.circle")
                } else if let feed {
                    enabled(feed)
                } else {
                    setup
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .accessibilityIdentifier("settings.feed")
    }

    private func enabled(_ feed: CalendarFeed) -> some View {
        let webcal = IcsExport.webcalURL(owner: feed.owner, gistId: feed.gistId)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(webcal?.absoluteString ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 6))
                Button { copy(webcal) } label: { Label("Kopírovat", systemImage: "doc.on.doc") }.buttonStyle(.denik(.normal, size: .small))
            }
            HStack(spacing: 8) {
                Button { webcal.map { _ = NSWorkspace.shared.open($0) } } label: { Label("Přidat do Apple Kalendáře", systemImage: "calendar.badge.plus") }
                    .buttonStyle(.primary)
                Button { Task { await feedSync.publishNow(); if let e = feedSync.status?.error { error = e } else { toasts.show("Kalendář aktualizován") } } } label: {
                    Label("Aktualizovat teď", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.denik(.normal))
                .disabled(feedSync.busy || store.syncMode == .readOnly)
                if let url = IcsExport.feedURL(owner: feed.owner, gistId: feed.gistId) {
                    Link("Zobrazit soubor", destination: url).buttonStyle(.denik(.ghost))
                }
            }
            Text(statusText).font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
            Toggle("Zahrnout zkoušky", isOn: Binding(get: { feed.includeExams }, set: { feedSync.setIncludeExams($0) })).toggleStyle(.switch)
            HStack {
                Text("Připomenutí před blokem").foregroundStyle(Palette.text2)
                AlarmPicker(minutes: Binding(get: { feed.alarmMin }, set: { feedSync.setAlarm($0) }))
            }
            Button("Vypnout") { confirmsDisable = true }.buttonStyle(.denik(.danger))
        }
        .confirmationDialog("Vypnout odebíraný kalendář?", isPresented: $confirmsDisable) {
            Button("Vypnout", role: .destructive) { feedSync.disable() }
        } message: {
            Text("Gist zůstane na GitHubu, jen se přestane aktualizovat.")
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                HStack {
                    Text("Připomenutí před blokem").foregroundStyle(Palette.text2)
                    AlarmPicker(minutes: $alarm)
                }
                Toggle("Zahrnout zkoušky", isOn: $includeExams).toggleStyle(.switch)
            }
            Button {
                error = nil
                Task {
                    do {
                        try await feedSync.enable(includeExams: includeExams, alarmMin: alarm)
                        toasts.show("Kalendář publikován")
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            } label: {
                Label(feedSync.busy ? "Publikuji…" : "Zapnout odebíraný kalendář", systemImage: "calendar.badge.clock")
            }
            .buttonStyle(.primary)
            .disabled(feedSync.busy || store.syncMode == .readOnly)
            Text("Token musí mít navíc oprávnění **Account permissions → Gists → Read and write**. Existující token jde upravit na GitHubu v Settings → Developer settings → Fine-grained tokens.")
                .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        var text = "Na iPhonu: Nastavení → Kalendář → Účty → Přidat účet → Jiné → Přidat odebíraný kalendář a vlož odkaz. Na Macu stačí tlačítko výše. Změny se v kalendáři objeví do ~1 hodiny (podle intervalu obnovy v Kalendáři)."
        if let status = feedSync.status {
            text += " Naposledy publikováno \(Format.time(status.at, clock: store.clock))\(status.error.map { " – chyba: \($0)" } ?? "")."
        }
        return text
    }

    private func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        toasts.show("Odkaz zkopírován")
    }
}
