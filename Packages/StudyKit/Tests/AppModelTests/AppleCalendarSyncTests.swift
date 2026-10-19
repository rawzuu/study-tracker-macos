import Core
import Engine
import Foundation
import Persistence
import Testing
@testable import AppModel

private let clock = StudyClock.current
private let hour = StudyClock.hour

@MainActor
private func store(_ seed: AppDocument, defaults: UserDefaults = UserDefaults(suiteName: "st-apple-\(UUID().uuidString)")!) async -> AppStore {
    let local = try! LocalStore.inMemory()
    let store = AppStore(environment: AppEnvironment(
        openStore: { local }, secrets: InMemorySecretStore(), defaults: defaults, backupService: OfflineBackupService(),
        clock: clock, network: { AsyncStream { $0.finish() } }, seed: seed
    ))
    await store.start()
    return store
}

private func block(_ id: String, inHours h: Int, title: String = "") -> PlanBlock {
    let start = Int(Date().timeIntervalSince1970 * 1000) / 60_000 * 60_000 + h * hour
    return PlanBlock(raw: ["id": .string(id), "subjectId": "a", "title": .string(title), "start": .number(Double(start)),
                           "durationMin": 50, "done": false, "note": ""])
}

private var seed: AppDocument {
    var d = AppDocument.empty
    d.upsert(Subject(raw: ["id": "a", "name": "Anatomie", "color": "#7b8cde", "weeklyGoalMin": 300, "archived": false]), now: 1)
    d.upsert([block("b1", inHours: 2, title: "Lebka"), block("b2", inHours: 26)], now: 1)
    return d
}

private let work = CalendarInfo(id: "work", title: "Práce", account: "iCloud", color: "#ff0000", kind: .cloud)
private let holidays = CalendarInfo(id: "holidays", title: "Svátky", account: "Jiné", color: "#00ff00", kind: .subscription)
private let feed = CalendarInfo(id: "feed", title: CalendarMirror.calendarTitle, account: "Jiné", color: "#0000ff", kind: .subscription)

/// Události v kalendáři aplikace podle bloku.
@MainActor
private func mirrored(_ service: InMemoryCalendarService, _ sync: AppleCalendarSync) async -> [String: CalendarMirror.Existing] {
    let calendarId = sync.preferences.calendarId
    let all = await service.stored.values.filter { $0.calendarId == calendarId }.map(\.event)
    return Dictionary(uniqueKeysWithValues: all.map { (CalendarMirror.Key(url: $0.url)!.id, $0) })
}

@MainActor
@Suite("Apple Kalendář – synchronizace", .serialized)
struct AppleCalendarSyncTests {
    @Test("Zapnutí: systém se zeptá, založí se kalendář a bloky; podruhé se nic nezapisuje")
    func enable() async {
        let service = InMemoryCalendarService(calendars: [work])
        let app = await store(seed)
        let sync = AppleCalendarSync(app: app, service: service)
        await sync.start()
        #expect(sync.access == .notDetermined && !sync.preferences.enabled)
        #expect(await service.applyCount == 0, "bez zapnutí se nic nezapisuje")

        #expect(await sync.enable())
        #expect(sync.access == .granted && sync.preferences.enabled)
        #expect(sync.ownCalendar?.title == CalendarMirror.calendarTitle)
        let events = await mirrored(service, sync)
        #expect(Set(events.keys) == ["b1", "b2"])
        #expect(events["b1"]?.title == "📚 Anatomie – Lebka")
        #expect(sync.status?.error == nil && sync.status?.events == 2)

        let applied = await service.applyCount
        await sync.sync()
        #expect(await service.applyCount == applied, "kalendář už odpovídá datům")
    }

    @Test("Bez přístupu se nic nezapíše")
    func denied() async {
        let service = InMemoryCalendarService(grants: false)
        let sync = AppleCalendarSync(app: await store(seed), service: service)
        await sync.start()
        #expect(await !sync.enable())
        #expect(sync.access == .denied && !sync.preferences.enabled)
        #expect(await service.calendarList.isEmpty)
        #expect(await service.applyCount == 0)
    }

    @Test("Změny dat se propíšou: přesun, smazání, nový blok")
    func followsData() async {
        let service = InMemoryCalendarService(access: .granted)
        let app = await store(seed)
        let sync = AppleCalendarSync(app: app, service: service, delay: .milliseconds(20))
        await sync.start()
        await sync.enable()

        var moved = app.document.record(PlanBlock.self, id: "b1")!
        moved.start += hour
        app.upsert(moved)
        app.remove(.planBlocks, id: "b2")
        app.upsert(block("b3", inHours: 5, title: "Svaly"))
        // po prodlevě se srovná samo
        for _ in 0..<100 where await mirrored(service, sync)["b3"] == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let events = await mirrored(service, sync)
        #expect(Set(events.keys) == ["b1", "b3"])
        #expect(events["b1"]?.start == moved.start)
    }

    @Test("Úpravy v Kalendáři se vrátí podle dat; cizí událost v kalendáři aplikace zmizí")
    func restores() async {
        let service = InMemoryCalendarService(access: .granted)
        let sync = AppleCalendarSync(app: await store(seed), service: service)
        await sync.start()
        await sync.enable()
        let events = await mirrored(service, sync)
        await service.edit(events["b1"]!.identifier) { $0.title = "Přejmenováno na iPhonu" }
        await service.delete(events["b2"]!.identifier)
        let now = Int(Date().timeIntervalSince1970 * 1000)
        await service.insertForeign(.init(identifier: "foreign", url: nil, title: "Moje", start: now, end: now + hour, allDay: false, notes: "", alarms: []),
                                    calendarId: sync.preferences.calendarId!)
        await sync.sync()
        let after = await mirrored(service, sync)
        #expect(Set(after.keys) == ["b1", "b2"])
        #expect(after["b1"]?.title == "📚 Anatomie – Lebka")
        #expect(await service.stored["foreign"] == nil)
    }

    @Test("Kalendář, který uloží událost pokaždé jinak, nezpůsobí nekonečný zápis")
    func noLoop() async {
        let service = InMemoryCalendarService(access: .granted)
        let sync = AppleCalendarSync(app: await store(seed), service: service)
        await sync.start()
        await sync.enable()
        let id = await mirrored(service, sync)["b1"]!.identifier
        var writes = 0
        for _ in 0..<6 {
            await service.edit(id) { $0.notes = "jinak" }
            let before = await service.applyCount
            await sync.sync()
            if await service.applyCount > before { writes += 1 }
        }
        #expect(writes == 3)
        // „Synchronizovat teď“ zkusí znovu
        await sync.syncNow()
        #expect(await mirrored(service, sync)["b1"]?.notes != "jinak")
    }

    @Test("Smazaný kalendář aplikace se založí znovu; jiný Mac najde stejný kalendář")
    func calendarLifecycle() async {
        let service = InMemoryCalendarService(access: .granted)
        let app = await store(seed)
        let sync = AppleCalendarSync(app: app, service: service)
        await sync.start()
        await sync.enable()
        let first = sync.preferences.calendarId!
        await service.deleteCalendar(id: first)
        await sync.syncNow()
        let second = try! #require(sync.preferences.calendarId)
        #expect(second != first)
        #expect(await mirrored(service, sync).count == 2)

        // druhý Mac (jiné UserDefaults) použije stejný kalendář a nic nezdvojí
        let other = AppleCalendarSync(app: await store(seed), service: service)
        await other.start()
        await other.enable()
        #expect(other.preferences.calendarId == second)
        #expect(await service.stored.values.filter { $0.calendarId == second }.count == 2)
    }

    @Test("Vypnutí: kalendář zůstane, nebo se smaže jen kalendář aplikace")
    func disable() async {
        let service = InMemoryCalendarService(access: .granted, calendars: [work])
        let sync = AppleCalendarSync(app: await store(seed), service: service)
        await sync.start()
        await sync.enable()
        await sync.disable(removeCalendar: false)
        #expect(!sync.preferences.enabled && sync.preferences.calendarId != nil)
        #expect(await mirrored(service, sync).count == 2)

        await sync.enable()
        await sync.disable(removeCalendar: true)
        #expect(sync.preferences.calendarId == nil)
        #expect(await service.calendarList == [work])
        #expect(await service.stored.isEmpty)
    }

    @Test("Obsazený čas: vlastní kalendáře ano, odebírané ne; výběr se pamatuje")
    func busy() async {
        let service = InMemoryCalendarService(access: .granted, calendars: [work, holidays, feed])
        let now = Int(Date().timeIntervalSince1970 * 1000)
        await service.addBusy(ExternalBusy(id: "w", title: "Porada", start: now + hour, end: now + 2 * hour, calendarId: "work", calendarTitle: "Práce", color: "#ff0000"))
        await service.addBusy(ExternalBusy(id: "h", title: "Svátek", start: now + hour, end: now + 3 * hour, calendarId: "holidays", calendarTitle: "Svátky", color: "#00ff00"))
        let defaults = UserDefaults(suiteName: "st-apple-\(UUID().uuidString)")!
        let app = await store(seed, defaults: defaults)
        let sync = AppleCalendarSync(app: app, service: service)
        await sync.start()
        #expect(sync.busyIntervals == [BusyInterval(start: now + hour, end: now + 2 * hour)])
        #expect(sync.isBusyCalendar("work") && !sync.isBusyCalendar("holidays") && !sync.isBusyCalendar("feed"))
        #expect(sync.hasFeedSubscription, "odebíraný plán z gistu by bloky zdvojil")

        sync.setBusyCalendar("work", false)
        sync.setBusyCalendar("holidays", true)
        for _ in 0..<100 where sync.external.first?.id != "h" { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(sync.external.map(\.id) == ["h"])
        // výběr přežije restart
        let again = AppleCalendarSync(app: app, service: service)
        await again.start()
        #expect(again.external.map(\.id) == ["h"])

        sync.setBusyEnabled(false)
        #expect(sync.busyIntervals.isEmpty)
    }

    @Test("Hodiny z rozvrhu, které jsou i v Apple Kalendáři, se ukážou jen jednou – i po importu rozvrhu")
    func lectureDuplicates() async {
        let service = InMemoryCalendarService(access: .granted, calendars: [work])
        let start = Int(Date().timeIntervalSince1970 * 1000) / 60_000 * 60_000 + hour
        await service.addBusy(ExternalBusy(id: "skola", title: "Anatomie", start: start, end: start + 90 * 60_000, calendarId: "work",
                                           calendarTitle: "Práce", color: "#ff0000"))
        await service.addBusy(ExternalBusy(id: "trenink", title: "Trénink", start: start + 3 * hour, end: start + 4 * hour, calendarId: "work",
                                           calendarTitle: "Práce", color: "#ff0000"))
        let app = await store(seed)
        let sync = AppleCalendarSync(app: app, service: service)
        await sync.start()
        #expect(sync.busyEvents.map(\.id) == ["skola", "trenink"])

        let event: JSONValue = .object(["key": "l1", "series": "Anatomie", "title": "Anatomie", "location": "",
                                        "start": .number(Double(start)), "end": .number(Double(start + 90 * 60_000))])
        app.upsert(Timetable(raw: ["id": "tt", "name": "Rozvrh", "importedAt": 1, "events": [event], "hiddenSeries": [], "skipped": []]))
        for _ in 0..<100 where sync.busyEvents.count != 1 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(sync.busyEvents.map(\.id) == ["trenink"])
        #expect(sync.busyIntervals == [BusyInterval(start: start + 3 * hour, end: start + 4 * hour)])
    }
}
