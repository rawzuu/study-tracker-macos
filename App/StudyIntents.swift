import AppIntents
import AppModel

// Akce pro Zkratky, Spotlight a Siri. Logika je v `StudyActions` (AppModel, s testy) – tady jen popis
// pro systém. Běží v aplikaci; když neběží, systém ji spustí a akce počká na načtení dat.

/// Předmět jako parametr zkratky.
struct SubjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Předmět"
    static let defaultQuery = SubjectQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SubjectQuery: EntityStringQuery {
    @Dependency private var actions: StudyActionsProvider

    @MainActor func entities(for identifiers: [String]) async throws -> [SubjectEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor func entities(matching string: String) async throws -> [SubjectEntity] {
        let wanted = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return try await all().filter { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(wanted) }
    }

    @MainActor func suggestedEntities() async throws -> [SubjectEntity] { try await all() }

    @MainActor private func all() async throws -> [SubjectEntity] {
        let actions = actions.make()
        try await actions.ready()
        return actions.subjects.map { SubjectEntity(id: $0.id, name: $0.name) }
    }
}

/// Režim časovače jako parametr zkratky.
struct TimerModeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Režim časovače"
    static let defaultQuery = TimerModeQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct TimerModeQuery: EntityQuery {
    @Dependency private var actions: StudyActionsProvider

    @MainActor func entities(for identifiers: [String]) async throws -> [TimerModeEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor func suggestedEntities() async throws -> [TimerModeEntity] {
        let actions = actions.make()
        try await actions.ready()
        return actions.modes.map { TimerModeEntity(id: $0.id, name: $0.name) }
    }
}

/// Přístup k akcím z AppIntents (`AppDependencyManager`).
@MainActor
final class StudyActionsProvider: Sendable {
    private let build: @MainActor () -> StudyActions

    init(_ build: @escaping @MainActor () -> StudyActions) {
        self.build = build
    }

    func make() -> StudyActions { build() }
}

struct StartStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "Začít učení"
    static let description = IntentDescription("Spustí blok učení. Bez předmětu podle doporučení „Co teď?“; během pauzy pokračuje dalším blokem.")

    @Parameter(title: "Předmět") var subject: SubjectEntity?
    @Parameter(title: "Téma") var topic: String?
    @Parameter(title: "Režim") var mode: TimerModeEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Začít učení \(\.$subject)") {
            \.$topic
            \.$mode
        }
    }

    @Dependency private var actions: StudyActionsProvider

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let actions = actions.make()
        try await actions.ready()
        let text = try actions.start(subjectId: subject?.id, topic: topic, modeId: mode?.id)
        return .result(value: text, dialog: "\(text)")
    }
}

struct PauseStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "Pozastavit učení"
    static let description = IntentDescription("Pozastaví běžící blok nebo pauzu.")
    @Dependency private var actions: StudyActionsProvider

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = actions.make()
        try await actions.ready()
        return .result(dialog: "\(try actions.pause())")
    }
}

struct ResumeStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "Pokračovat v učení"
    static let description = IntentDescription("Rozběhne pozastavený blok nebo pauzu.")
    @Dependency private var actions: StudyActionsProvider

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = actions.make()
        try await actions.ready()
        return .result(dialog: "\(try actions.resume())")
    }
}

struct FinishBlockIntent: AppIntent {
    static let title: LocalizedStringResource = "Hotovo – uložit blok"
    static let description = IntentDescription("Uloží běžící blok učení a začne pauzu.")
    @Dependency private var actions: StudyActionsProvider

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = actions.make()
        try await actions.ready()
        return .result(dialog: "\(try actions.finish())")
    }
}

struct StopStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "Ukončit učení"
    static let description = IntentDescription("Uloží rozpracovaný blok a ukončí sérii.")
    @Dependency private var actions: StudyActionsProvider

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = actions.make()
        try await actions.ready()
        return .result(dialog: "\(try actions.stop())")
    }
}

struct WhatNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Co se mám teď učit?"
    static let description = IntentDescription("Doporučení „Co teď?“: předmět, co dělat, jak dlouho a proč.")
    @Dependency private var actions: StudyActionsProvider

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let actions = actions.make()
        try await actions.ready()
        let text = actions.whatNow()
        return .result(value: text, dialog: "\(text)")
    }
}

struct TodayStudyIntent: AppIntent {
    static let title: LocalizedStringResource = "Dnešní učení"
    static let description = IntentDescription("Kolik je dnes odučeno a kolik zbývá do denního cíle. Vrací minuty.")
    @Dependency private var actions: StudyActionsProvider

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let actions = actions.make()
        try await actions.ready()
        let today = actions.today()
        return .result(value: today.minutes, dialog: "\(today.text)")
    }
}

/// Zkratky, které jsou hned k dispozici (Spotlight, aplikace Zkratky, Siri). Siri česky neumí –
/// anglické věty fungují se Siri v angličtině, české jsou pro hledání.
struct StudyTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartStudyIntent(), phrases: [
            "Start studying in \(.applicationName)",
            "Start \(\.$subject) in \(.applicationName)",
            "Začít učení v \(.applicationName)",
        ], shortTitle: "Začít učení", systemImageName: "play.fill")
        AppShortcut(intent: WhatNowIntent(), phrases: [
            "What should I study in \(.applicationName)",
            "Co se mám učit v \(.applicationName)",
        ], shortTitle: "Co teď?", systemImageName: "sparkles")
        AppShortcut(intent: TodayStudyIntent(), phrases: [
            "How much did I study today in \(.applicationName)",
            "Dnešní učení v \(.applicationName)",
        ], shortTitle: "Dnešní učení", systemImageName: "clock")
        AppShortcut(intent: PauseStudyIntent(), phrases: [
            "Pause studying in \(.applicationName)",
            "Pozastavit učení v \(.applicationName)",
        ], shortTitle: "Pozastavit", systemImageName: "pause.fill")
        AppShortcut(intent: StopStudyIntent(), phrases: [
            "Stop studying in \(.applicationName)",
            "Ukončit učení v \(.applicationName)",
        ], shortTitle: "Ukončit", systemImageName: "stop.fill")
    }
}
