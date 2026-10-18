import AppIntents
import AppKit
import SwiftUI
import WidgetData
import WidgetKit
import WidgetUI

// Rozšíření widgetů: jen registrace widgetů a akce tlačítek. Obsah, časová osa a vzhled jsou
// v balíčku (WidgetUI) s testy a náhledy; data jsou souhrn, který zapisuje aplikace.

@main
struct StudyTrackerWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        TimerWidget()
        PlanWidget()
        ExamsWidget()
        OverviewWidget()
    }
}

/// Tlačítka: když aplikace běží, pošlou příkaz rovnou (bez otevření okna); jinak aplikaci otevřou
/// odkazem a příkaz se provede po načtení dat.
private func actions(_ entry: StudyEntry) -> WidgetActions {
    let running = entry.snapshot?.appRunning ?? false
    return WidgetActions { command, label in
        if running {
            AnyView(Button(intent: WidgetCommandIntent(command)) { label }.buttonStyle(.plain))
        } else {
            AnyView(Link(destination: command.url) { label })
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFiles.kinds[0], provider: StudyProvider()) { entry in
            TodayWidgetView(entry: entry).environment(\.widgetActions, actions(entry))
        }
        .configurationDisplayName("Dnešek")
        .description("Kolik je dnes odučeno, denní cíl, série a co je v plánu dál.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFiles.kinds[1], provider: StudyProvider()) { entry in
            TimerWidgetView(entry: entry).environment(\.widgetActions, actions(entry))
        }
        .configurationDisplayName("Časovač")
        .description("Živý odpočet bloku s pauzou a uložením; v klidu doporučení „Co teď?“ se spuštěním.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PlanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFiles.kinds[2], provider: StudyProvider()) { entry in
            PlanWidgetView(entry: entry).environment(\.widgetActions, actions(entry))
        }
        .configurationDisplayName("Plán")
        .description("Dnešní bloky plánu – co je hotové, co běží a co přijde; velký i zítřek a zkouška.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ExamsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFiles.kinds[3], provider: StudyProvider()) { entry in
            ExamsWidgetView(entry: entry).environment(\.widgetActions, actions(entry))
        }
        .configurationDisplayName("Zkoušky")
        .description("Kolik dní zbývá do nejbližších zkoušek.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetFiles.kinds[4], provider: StudyProvider()) { entry in
            OverviewWidgetView(entry: entry).environment(\.widgetActions, actions(entry))
        }
        .configurationDisplayName("Přehled")
        .description("Dnešek a týden, plán, časovač nebo „Co teď?“ a zkoušky – pro velkou plochu.")
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}

/// Tlačítko ve widgetu: příkaz do sdíleného kontejneru pro aplikaci. Widget hned ukáže očekávaný
/// stav a chvíli počká, než aplikace pošle skutečný.
struct WidgetCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Ovládání časovače ve widgetu"
    static let isDiscoverable = false

    @Parameter(title: "Akce") var action: String
    @Parameter(title: "Předmět") var subjectId: String?
    @Parameter(title: "Téma") var topic: String?
    @Parameter(title: "Režim") var modeId: String?

    init() {}

    init(_ command: WidgetCommand) {
        action = command.action.rawValue
        subjectId = command.subjectId
        topic = command.topic
        modeId = command.modeId
    }

    func perform() async throws -> some IntentResult {
        guard let files = WidgetFiles.shared(), let action = WidgetCommand.Action(rawValue: action) else { return .result() }
        let now = Int((Date().timeIntervalSince1970 * 1000).rounded())
        let command = WidgetCommand(action: action, subjectId: subjectId, topic: topic, modeId: modeId, at: now)
        let appId = Bundle.main.object(forInfoDictionaryKey: "STAppBundleId") as? String ?? ""
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: appId).isEmpty
        if var snapshot = files.readSnapshot() {
            // Odhad stavu se zapíše dřív než příkaz – skutečný souhrn od aplikace ho pak nepřepíše.
            // Aplikace mezitím skončila → tlačítka ji příště otevřou (příkaz provede po spuštění).
            snapshot.appRunning = running
            try? files.write(running ? snapshot.applying(action, at: now) : snapshot)
        }
        try files.send(command)
        if running { _ = await files.waitForSnapshot(newerThan: now) }
        return .result()
    }
}
