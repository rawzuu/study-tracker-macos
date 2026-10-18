import AppKit
import AppModel
import Core
import DesignSystem
import Engine
import SwiftUI

/// Apple Kalendář v Nastavení (jen Mac): zápis plánu přímo do kalendáře a obsazený čas z ostatních kalendářů.
struct AppleCalendarSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(AppleCalendarSync.self) private var sync
    @Environment(Toasts.self) private var toasts
    @State private var confirmsDisable = false
    @State private var movingTo: CalendarAccount?

    var body: some View {
        let prefs = sync.preferences
        PageSection("Apple Kalendář", accessory: { prefs.enabled && sync.access == .granted ? Chip("zapnuto", tone: .ok) : Chip("vypnuto") }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Bloky plánu a zkoušky se zapíšou přímo do kalendáře „\(CalendarMirror.calendarTitle)“ – v iCloudu je hned uvidíš v iPhonu, iPadu i hodinkách. Data zůstávají ve Study Trackeru; kalendář je jejich kopie, Mac ho po každé změně srovná. Ostatní kalendáře se jen čtou.")
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                switch sync.access {
                case .denied, .writeOnly:
                    Banner(sync.access == .writeOnly
                           ? "Study Tracker má ke kalendářům jen zápis – na úpravy a mazání bloků potřebuje plný přístup."
                           : "Study Tracker nemá přístup ke kalendářům.",
                           systemImage: "lock", tone: .warn) {
                        Button("Otevřít Nastavení systému") { openPrivacySettings() }.buttonStyle(.denik(.normal, size: .small))
                    }
                case .notDetermined, .granted:
                    if prefs.enabled && sync.access == .granted { enabled(prefs) } else { setup }
                }
                if sync.access == .granted { BusyCalendars() }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .accessibilityIdentifier("settings.appleCalendar")
        .confirmationDialog("Vypnout zápis do Apple Kalendáře?", isPresented: $confirmsDisable) {
            Button("Vypnout a kalendář ponechat") { Task { await sync.disable(removeCalendar: false) } }
            Button("Vypnout a smazat kalendář \(CalendarMirror.calendarTitle)", role: .destructive) {
                Task { await sync.disable(removeCalendar: true) }
            }
        } message: {
            Text("Smaže se jen kalendář „\(CalendarMirror.calendarTitle)“, který Study Tracker založil. Data ve Study Trackeru zůstanou beze změny.")
        }
        .confirmationDialog("Přesunout kalendář do účtu \(movingTo?.title ?? "")?", isPresented: Binding(get: { movingTo != nil }, set: { if !$0 { movingTo = nil } }),
                            presenting: movingTo) { account in
            Button("Přesunout") { Task { await sync.setAccount(account.id) } }
        } message: { _ in
            Text("V původním účtu se kalendář „\(CalendarMirror.calendarTitle)“ smaže a v novém se založí znovu z dat.")
        }
    }

    // MARK: - Vypnuto

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task {
                    if await sync.enable() {
                        toasts.show("Plán je v Apple Kalendáři")
                    }
                }
            } label: {
                Label(sync.syncing ? "Zapisuji…" : "Zapisovat plán do Apple Kalendáře", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.primary)
            .disabled(sync.syncing)
            .accessibilityIdentifier("appleCalendar.enable")
            if sync.access == .notDetermined {
                Button("Jen brát události z kalendářů jako obsazený čas") { Task { await sync.requestAccess() } }
                    .buttonStyle(.denik(.ghost, size: .small))
                    .accessibilityIdentifier("appleCalendar.busyOnly")
            }
            Text(sync.access == .notDetermined ? "macOS se jednou zeptá na plný přístup ke kalendářům." : "Kalendář se založí v iCloudu (když ho na Macu používáš).")
                .font(Typo.small).foregroundStyle(Palette.text3)
        }
    }

    // MARK: - Zapnuto

    private func enabled(_ prefs: AppleCalendarSync.Preferences) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = sync.status?.error {
                Banner(error, systemImage: "exclamationmark.triangle", tone: .bad)
            }
            if sync.hasFeedSubscription {
                Banner("V Kalendáři máš i odebíraný „\(CalendarMirror.calendarTitle)“ z gistu – bloky tam uvidíš dvakrát. Odebíraný kalendář si v Kalendáři skryj (odškrtni); dál se aktualizuje jako záloha pro dobu, kdy Mac neběží.",
                       systemImage: "square.on.square")
            }
            HStack(spacing: 10) {
                Circle().fill(Palette.subject(sync.ownCalendar?.color ?? "#6F86C9")).frame(width: 9, height: 9)
                Text(CalendarMirror.calendarTitle).fontWeight(.medium)
                Text("v účtu").foregroundStyle(Palette.text3)
                Picker("Účet", selection: Binding(get: { currentAccountId(prefs) }, set: { id in movingTo = sync.accounts.first { $0.id == id } })) {
                    ForEach(sync.accounts) { Text($0.title).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(sync.accounts.count < 2)
                .accessibilityIdentifier("appleCalendar.account")
            }
            Text(statusText).font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("appleCalendar.status")
            HStack(spacing: 24) {
                HStack {
                    Text("Připomenutí před blokem").foregroundStyle(Palette.text2)
                    AlarmPicker(minutes: Binding(get: { prefs.alarmMin }, set: { sync.setAlarm($0) }))
                }
                Toggle("Zahrnout zkoušky", isOn: Binding(get: { prefs.includeExams }, set: { sync.setIncludeExams($0) })).toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                Button { Task { await sync.syncNow() } } label: { Label("Synchronizovat teď", systemImage: "arrow.clockwise") }
                    .buttonStyle(.denik(.normal))
                    .disabled(sync.syncing)
                    .accessibilityIdentifier("appleCalendar.syncNow")
                Button { openCalendarApp() } label: { Label("Otevřít Kalendář", systemImage: "calendar") }
                    .buttonStyle(.denik(.ghost))
                Spacer()
                Button("Vypnout") { confirmsDisable = true }
                    .buttonStyle(.denik(.danger))
                    .accessibilityIdentifier("appleCalendar.disable")
            }
        }
    }

    private func currentAccountId(_ prefs: AppleCalendarSync.Preferences) -> String? {
        prefs.accountId ?? sync.accounts.first { $0.title == sync.ownCalendar?.account }?.id ?? sync.accounts.first?.id
    }

    private var statusText: String {
        guard let status = sync.status else { return "Zatím nesynchronizováno." }
        let count = Format.plural(status.events, "událost", "události", "událostí")
        return "Naposledy srovnáno \(Format.time(status.at, clock: store.clock)) · \(status.events) \(count) (bloky od dvou týdnů zpět\(sync.preferences.includeExams ? " a zkoušky" : "")). Změny v Kalendáři se přepíšou podle dat – plán upravuj ve Study Trackeru nebo na webu."
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") { NSWorkspace.shared.open(url) }
    }

    private func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Které kalendáře jsou obsazený čas pro ranní plán.
private struct BusyCalendars: View {
    @Environment(AppleCalendarSync.self) private var sync

    var body: some View {
        let on = sync.preferences.busyEnabled
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { on }, set: { sync.setBusyEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Události z ostatních kalendářů jsou obsazený čas")
                    Text("Ranní plán se jim vyhne a v Kalendáři jsou šedě šrafované. Celodenní a volné události se nepočítají.")
                        .font(Typo.small).foregroundStyle(Palette.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("appleCalendar.busy")
            if on {
                let groups = Dictionary(grouping: sync.otherCalendars, by: \.account).sorted { $0.key < $1.key }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.key) { account, calendars in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.isEmpty ? "Ostatní" : account).font(Typo.small).foregroundStyle(Palette.text3)
                            ForEach(calendars) { c in
                                Toggle(isOn: Binding(get: { sync.isBusyCalendar(c.id) }, set: { sync.setBusyCalendar(c.id, $0) })) {
                                    HStack(spacing: 7) {
                                        RoundedRectangle(cornerRadius: 3).fill(Palette.subject(c.color)).frame(width: 10, height: 10)
                                        Text(c.title)
                                        if c.kind == .subscription { Text("odebíraný").font(Typo.small).foregroundStyle(Palette.text3) }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("appleCalendar.busy.\(c.id)")
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.top, 4)
    }
}
