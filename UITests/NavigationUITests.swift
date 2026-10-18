import XCTest

/// Hlavní toky s ukázkovými daty (`-uiTesting`: vše v paměti, bez sítě a Klíčenky).
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        // Na CI občas zůstane vpředu jiné okno – kliknutí by pak skončilo chybou „not foreground“.
        app.activate()
        return app
    }

    @MainActor
    func testSidebarSwitchesPages() {
        let app = launch()
        let title = app.staticTexts["page.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // Přehled má jako nadpis dnešní datum („Sobota 17. října“).
        XCTAssertFalse(text(of: title).isEmpty)
        attachScreenshot(app, "Přehled")
        // Opakování na Macu není (rozhodnutí uživatele).
        XCTAssertFalse(app.staticTexts["nav.opakovani"].exists)

        app.staticTexts["nav.historie"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Historie")
        attachScreenshot(app, "Historie")

        app.staticTexts["nav.predmety"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Předměty")
        attachScreenshot(app, "Předměty")

        app.staticTexts["nav.planovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Kalendář")

        app.staticTexts["nav.casovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Časovač")
    }

    @MainActor
    func testDashboardShowsDemoData() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["dash.today"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dash.week"].exists)
        XCTAssertTrue(app.staticTexts["Anatomie"].firstMatch.exists)
        // Bez zálohy ukazuje lišta, že data jsou jen na Macu.
        XCTAssertTrue(app.buttons["sync.status"].exists)
    }

    @MainActor
    func testHistoryFilterBySubject() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.historie"].click()
        let picker = app.popUpButtons["history.subject"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        picker.click()
        app.menuItems["Latina"].click()
        XCTAssertTrue(app.staticTexts["Žádná sezení"].waitForExistence(timeout: 2))
        picker.click()
        app.menuItems["Anatomie"].click()
        XCTAssertFalse(app.staticTexts["Žádná sezení"].exists)
    }

    @MainActor
    func testSettingsShowsConnectForm() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.nastaveni"].click()
        let token = app.secureTextFields["settings.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["settings.connect"].isEnabled, "bez tokenu nejde připojit")
        token.click()
        token.typeText("github_pat_UITEST")
        XCTAssertTrue(app.buttons["settings.connect"].isEnabled)
        // V UI testech není síť → připojení skončí srozumitelnou chybou a nic se neuloží.
        app.buttons["settings.connect"].click()
        XCTAssertTrue(app.descendants(matching: .any)["settings.error"].waitForExistence(timeout: 5))
        attachScreenshot(app, "Nastavení")
    }

    @MainActor
    func testCreateSubject() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.predmety"].click()
        app.buttons["subjects.new"].click()
        let name = app.textFields["subject.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.typeText("Anatomie")
        XCTAssertFalse(app.buttons["subject.save"].isEnabled, "stejný název už existuje")
        name.typeText(" II")
        XCTAssertTrue(app.buttons["subject.save"].isEnabled)
        attachScreenshot(app, "Nový předmět")
        app.buttons["subject.save"].click()
        XCTAssertTrue(app.staticTexts["Anatomie II"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testTimerBlockSavesSession() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.casovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Časovač")
        XCTAssertFalse(app.buttons["timer.start"].isEnabled, "bez předmětu nejde začít")

        let subject = app.popUpButtons["timer.subject"]
        subject.click()
        app.menuItems["Fyziologie"].click()
        let topic = app.textFields["timer.topic"]
        topic.click()
        topic.typeText("Ledviny UI")
        // Mezera v tématu blok nespustí (mezerník ovládá časovač jen mimo textová pole).
        XCTAssertEqual(topic.value as? String, "Ledviny UI")
        XCTAssertTrue(app.buttons["timer.start"].exists)
        // Vlastní režim z ukázkových dat: 3 s učení.
        app.descendants(matching: .any)["mode.demo-rychly"].firstMatch.click()
        attachScreenshot(app, "Časovač")

        app.buttons["timer.start"].click()
        XCTAssertTrue(app.buttons["timer.pause"].waitForExistence(timeout: 2))
        attachScreenshot(app, "Časovač běží")

        // Konec bloku → sezení se uloží a otevře se okno po bloku.
        let recall = app.textViews["rating.recall"]
        XCTAssertTrue(recall.waitForExistence(timeout: 15))
        attachScreenshot(app, "Blok dokončen")
        recall.click()
        recall.typeText("Nefron a glomerulus")
        app.descendants(matching: .any)["rating.focus.4"].firstMatch.click()
        app.buttons["rating.save"].click()
        XCTAssertTrue(recall.waitForNonExistence(timeout: 3))
        attachScreenshot(app, "Pauza")
        // Pauza (3 s) doběhne a časovač čeká na další blok – sérii ukončit, ať kruh netiká.
        let end = app.buttons["timer.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        end.click()
        XCTAssertTrue(end.waitForNonExistence(timeout: 2))

        app.staticTexts["nav.historie"].click()
        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.timer-")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "sezení z časovače je v historii")
        XCTAssertTrue(text(of: saved).contains("Ledviny UI"), text(of: saved))
        attachScreenshot(app, "Historie po bloku")
    }

    @MainActor
    func testDashboardTimerAndPlanBlock() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["dash.timer"].exists)
        XCTAssertEqual(text(of: app.staticTexts["dash.timer.time"]), "25:00")
        attachScreenshot(app, "Přehled s časovačem")

        // Blok z plánu „Opakování: Ledviny, Srdce“ připraví časovač s předmětem a tématem.
        let start = app.buttons["plan.start.demo-plan"]
        reveal(start, app)
        start.click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Časovač")
        XCTAssertEqual(app.textFields["timer.topic"].value as? String, "Ledviny")
        XCTAssertEqual(app.popUpButtons["timer.subject"].value as? String, "Fyziologie")
        XCTAssertTrue(app.buttons["timer.start"].isEnabled)
    }

    /// Nový blok v kalendáři a „Hotovo“, které k bloku zapíše odučený čas.
    @MainActor
    func testCalendarAddsBlockAndLogsTime() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.planovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Kalendář")
        XCTAssertTrue(app.descendants(matching: .any)["calendar.week"].exists)

        app.buttons["calendar.addBlock"].click()
        let save = app.buttons["block.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 2))
        XCTAssertFalse(save.isEnabled, "bez předmětu nejde uložit")
        choose("Biochemie", in: app.popUpButtons["block.subject"], app)
        let title = app.textFields["block.title"]
        title.click()
        title.typeText("UI blok")
        attachScreenshot(app, "Nový blok")
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 2))

        let block = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "cal.block.", "UI blok")).firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 3), "blok je v kalendáři")
        attachScreenshot(app, "Kalendář s blokem")

        // Hotovo u bloku bez zapsaného času nabídne zápis odučeného.
        block.click()
        app.buttons["block.done"].click()
        let logSave = app.buttons["session.save"]
        XCTAssertTrue(logSave.waitForExistence(timeout: 2))
        XCTAssertEqual(app.textFields["session.topic"].value as? String, "UI blok")
        logSave.click()
        let logged = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "cal.session.", "UI blok")).firstMatch
        XCTAssertTrue(logged.waitForExistence(timeout: 3), "odučený čas je v kalendáři")
    }

    /// „Co teď?“ ukáže důvody i signály a „Začít“ připraví časovač s doporučeným předmětem.
    @MainActor
    func testNextUpStartsTimer() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["dash.next"].waitForExistence(timeout: 3))
        XCTAssertFalse(text(of: app.staticTexts["next.title"]).isEmpty)
        let subject = text(of: app.descendants(matching: .any)["next.subject"])

        app.buttons["next.why"].click()
        XCTAssertTrue(app.descendants(matching: .any)["next.whyTable"].waitForExistence(timeout: 2))
        attachScreenshot(app, "Co teď?")

        let start = app.buttons["next.start"]
        reveal(start, app)
        start.click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Časovač")
        let picked = app.popUpButtons["timer.subject"].value as? String ?? ""
        XCTAssertFalse(picked.isEmpty)
        XCTAssertTrue(subject.hasPrefix(picked), "časovač má doporučený předmět (\(subject) → \(picked))")
        XCTAssertTrue(app.buttons["timer.start"].isEnabled)
        // Na stránce časovače je doporučení i s „Použít“ (časovač stojí).
        XCTAssertTrue(app.buttons["timer.useRecommendation"].exists)
    }

    /// Ranní plán z kalendáře: návrh, „Další blok“ a uložení do kalendáře.
    @MainActor
    func testDayPlanFromCalendar() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.planovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Kalendář")
        app.buttons["calendar.planDay"].click()
        let save = app.buttons["dayplan.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        app.buttons["dayplan.more"].click()
        attachScreenshot(app, "Ranní plán")
        if save.isEnabled {
            save.click()
            XCTAssertTrue(save.waitForNonExistence(timeout: 2))
            let toast = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "Do kalendáře", "Do kalendáře")).firstMatch
            XCTAssertTrue(toast.waitForExistence(timeout: 3), "hláška o uložených blocích")
        } else {
            // Pozdě večer se do dne nic nevejde – okno to řekne a jde zavřít.
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(save.waitForNonExistence(timeout: 2))
        }
    }

    /// Nová zkouška se objeví v seznamu s odpočtem; smazanou vrátí „Vrátit“ v hlášce.
    @MainActor
    func testExamAddDeleteUndo() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.planovac"].click()
        app.buttons["calendar.addExam"].click()
        choose("Latina", in: app.popUpButtons["exam.subject"], app)
        let name = app.textFields["exam.name"]
        name.click()
        name.typeText("UI zkouška")
        app.buttons["exam.save"].click()

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "exam.", "UI zkouška")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3), "zkouška je v seznamu")
        XCTAssertTrue(row.label.contains("za 14 dní"), row.label)

        row.click()
        app.buttons["exam.delete"].click()
        app.buttons["exam.confirmDelete"].firstMatch.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3), "smazaná zkouška zmizí")
        undoViaShortcut(app)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Vrátit zkoušku obnoví")
    }

    /// Hodina z rozvrhu: „Tento termín odpadá“ ji z kalendáře schová, „Vrátit“ ji vrátí.
    @MainActor
    func testLectureSkipAndUndo() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.planovac"].click()
        let lecture = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "cal.lecture.Anatomie")).firstMatch
        XCTAssertTrue(lecture.waitForExistence(timeout: 3), "přednáška z rozvrhu je v kalendáři")
        let id = lecture.identifier
        lecture.click()
        app.buttons["lecture.skip"].click()
        let same = app.descendants(matching: .any)[id]
        XCTAssertTrue(same.waitForNonExistence(timeout: 3), "odpadlý termín zmizí")
        undoViaShortcut(app)
        XCTAssertTrue(same.waitForExistence(timeout: 3), "Vrátit termín vrátí")
    }

    /// Spuštění aplikace odkazem ze Zkratek, když aplikace neběží (studený start). Že běžící blok
    /// odkaz nepřeruší, hlídají unit testy – XCUITest by odkaz do běžící aplikace otevřel v nové instanci.
    @MainActor
    func testLinkStartsBlock() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        // Stejný odkaz jako na webu: předmět podle začátku názvu bez diakritiky, téma předvyplněné.
        app.open(URL(string: "studytracker://casovac?start=1&predmet=fyziol&tema=Ledviny+a+mo%C4%8D")!)
        XCTAssertTrue(app.buttons["timer.pause"].waitForExistence(timeout: 10))
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Časovač")
        let studying = text(of: app.staticTexts["timer.studying"])
        XCTAssertTrue(studying.contains("Fyziologie") && studying.contains("Ledviny a moč"), studying)
        XCTAssertEqual(app.windows.count, 1)
        attachScreenshot(app, "Odkaz spustil blok")
        app.buttons["timer.stop"].click()
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTesting"]
            app.launch()
        }
    }

    /// Posune stránku, dokud prvek není vidět (na malé obrazovce CI je přehled pod sebou a delší než okno).
    /// Posouvá se oblast, ve které prvek je – první posuvná oblast okna je postranní panel.
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        let page = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
        let area = page.exists ? page : app.windows.firstMatch
        for delta in [-150.0, 150.0] {
            for _ in 0..<10 where !element.isHittable {
                area.scroll(byDeltaX: 0, deltaY: delta)
            }
        }
        XCTAssertTrue(element.isHittable, "prvek je vidět")
    }

    /// Výběr položky z rozbalovací nabídky – až když je nabídka (třeba v právě otevřeném okně) vidět.
    @MainActor private func choose(_ item: String, in popUp: XCUIElement, _ app: XCUIApplication) {
        XCTAssertTrue(popUp.waitForExistence(timeout: 3))
        popUp.click()
        let menuItem = app.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "v nabídce je \(item)")
        menuItem.click()
    }

    /// „Vrátit“ v hlášce přes ⌘Z. Klik by na CI netrefil: hláška je u spodního okraje malé obrazovky
    /// těsně nad Dockem a klik tam nedojde (ani na najetí myší nereaguje), lokálně funguje.
    @MainActor private func undoViaShortcut(_ app: XCUIApplication) {
        let undo = app.buttons["toast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(undo.waitForNonExistence(timeout: 2), "hláška po Vrátit zmizí")
    }

    /// Na macOS nese text popisku SwiftUI `value`, ne `label`.
    @MainActor private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// Snímky pro kontrolu vzhledu. `TEST_RUNNER_ST_NO_SCREENSHOTS=1` je vypne (vypnutý displej je neumí pořídit).
    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        guard ProcessInfo.processInfo.environment["ST_NO_SCREENSHOTS"] == nil else { return }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
