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
        XCTAssertEqual(text(of: title), "Dnes")
        attachScreenshot(app, "Dnes")
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
        attachScreenshot(app, "Kalendář")

        app.staticTexts["nav.casovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Časovač")
        attachScreenshot(app, "Časovač")

        app.staticTexts["nav.statistiky"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Statistiky")
        XCTAssertTrue(app.descendants(matching: .any)["stats.facts"].waitForExistence(timeout: 3), "souhrn z ukázkových dat")
        attachScreenshot(app, "Statistiky")

        app.staticTexts["nav.report"].click()
        XCTAssertTrue(app.buttons["report.prev"].waitForExistence(timeout: 3))
        attachScreenshot(app, "Měsíční report")

        app.staticTexts["nav.reflexe"].click()
        XCTAssertTrue(app.buttons["reflection.save"].waitForExistence(timeout: 3))
        attachScreenshot(app, "Reflexe")

        app.staticTexts["nav.uspechy"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Úspěchy")
        XCTAssertTrue(app.descendants(matching: .any)["achievements.summary"].waitForExistence(timeout: 3))
        attachScreenshot(app, "Úspěchy")

        app.staticTexts["nav.nastaveni"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Nastavení")
        attachScreenshot(app, "Nastavení")
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
        attachScreenshot(app, "Dnes s časovačem")

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

        // Hotovo u bloku bez zapsaného času nabídne zápis odučeného. Večer je blok „teď“ v mřížce
        // pod okrajem malé obrazovky CI – nejdřív se k němu posunout.
        reveal(block, app)
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
        // Hlavní řádek je předmět, ne téma, kde jsi skončil.
        let subject = text(of: app.descendants(matching: .any)["next.subject"])
        XCTAssertFalse(subject.isEmpty)
        XCTAssertFalse(subject.contains("Pokračovat"))

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

    /// Ranní plán dopředu: příští týden se naplánuje po dnech a uloží najednou.
    @MainActor
    func testDayPlanNextWeek() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.buttons["dash.planDay"].click()
        let save = app.buttons["dayplan.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        let nextWeek = app.radioButtons["Příští týden"]
        XCTAssertTrue(nextWeek.waitForExistence(timeout: 2))
        nextWeek.click()
        XCTAssertTrue(app.descendants(matching: .any)["dayplan.day.6"].waitForExistence(timeout: 3), "sedm dní příštího týdne")
        XCTAssertFalse(app.buttons["dayplan.more"].exists, "„Další blok“ jen u plánu jednoho dne")
        attachScreenshot(app, "Ranní plán – příští týden")
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 2))
        let toast = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", " na ", " na ")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "hláška o blocích na víc dní")
    }

    /// Anki (v paměti, nikdy skutečná Anki): zapnutí v Nastavení načte balíčky a na stránce Dnes je souhrn karet.
    @MainActor
    func testAnkiSummary() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["dash.anki"].exists, "bez propojení a bez stavu Anki se souhrn neukazuje")
        app.staticTexts["nav.nastaveni"].click()
        // Přepínač (.switch) se v macOS hlásí jako zaškrtávací políčko.
        let toggle = app.checkBoxes["settings.anki.enabled"]
        reveal(toggle, app)
        toggle.click()
        attachScreenshot(app, "Anki v Nastavení")
        app.staticTexts["nav.prehled"].click()
        let due = app.descendants(matching: .any)["dash.anki.due"]
        XCTAssertTrue(due.waitForExistence(timeout: 5))
        let count = due.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", "85", "85")).firstMatch
        XCTAssertTrue(count.exists || (due.value as? String ?? "").contains("85") || due.label.contains("85"), "85 karet zbývá")
        attachScreenshot(app, "Anki na stránce Dnes")
    }

    /// Apple Kalendář v Nastavení (kalendáře v paměti): zapnutí zapíše plán a ukáže stav, ostatní kalendáře
    /// jsou obsazený čas – odebírané (svátky) ve výchozím stavu ne.
    @MainActor
    func testAppleCalendarInSettings() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.nastaveni"].click()
        let enable = app.buttons["appleCalendar.enable"]
        reveal(enable, app)
        enable.click()
        let status = app.staticTexts["appleCalendar.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "po zapnutí je vidět stav synchronizace")
        XCTAssertTrue(text(of: status).hasPrefix("Naposledy srovnáno"))
        let work = app.checkBoxes["appleCalendar.busy.demo-prace"]
        let holidays = app.checkBoxes["appleCalendar.busy.demo-svatky"]
        reveal(work, app)
        XCTAssertEqual(work.value as? Int, 1)
        XCTAssertEqual(holidays.value as? Int, 0)
        attachScreenshot(app, "Apple Kalendář")
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

    /// Soustředění: seznam ze šablony a plán „během učení“ (dočasná složka, Strážce neběží).
    @MainActor
    func testFocusListAndPlan() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.soustredeni"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Soustředění")
        let add = app.descendants(matching: .any)["focus.addList"].firstMatch
        reveal(add, app)
        choose("Sociální sítě", in: add, app)
        let saveList = app.buttons["focusList.save"]
        XCTAssertTrue(saveList.waitForExistence(timeout: 3))
        attachScreenshot(app, "Soustředění – seznam")
        saveList.click()
        XCTAssertTrue(app.buttons["focus.list.Sociální sítě"].waitForExistence(timeout: 3))
        let addPlan = app.descendants(matching: .any)["focus.addPlan"].firstMatch
        reveal(addPlan, app)
        addPlan.click()
        let savePlan = app.buttons["focusPlan.save"]
        XCTAssertTrue(savePlan.waitForExistence(timeout: 3))
        attachScreenshot(app, "Soustředění – plán")
        savePlan.click()
        XCTAssertTrue(app.buttons["focus.plan.Během učení"].waitForExistence(timeout: 3))
        attachScreenshot(app, "Soustředění")
    }

    /// Zmrazení z UI: po potvrzení je v nastavení zámek a Kalendář ukazuje, kdy Soustředění blokuje.
    /// (Strážce v UI testech neběží – skutečné blokování zkouší Tools/ci/guard-e2e.sh.)
    @MainActor
    func testFocusFreezeShowsInCalendar() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["page.title"].waitForExistence(timeout: 5))
        app.staticTexts["nav.planovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Kalendář")
        XCTAssertFalse(app.staticTexts["Soustředění blokuje"].exists, "bez zámků pruh není")
        app.staticTexts["nav.soustredeni"].click()
        let freeze = app.buttons["focus.freeze"]
        reveal(freeze, app)
        freeze.click()
        // Jen v okně – stejné tlačítko má i Touch Bar (na CI by se kliklo tam).
        let confirm = app.windows.buttons["Zmrazit"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        attachScreenshot(app, "Soustředění – zmrazit")
        confirm.click()
        app.staticTexts["nav.planovac"].click()
        XCTAssertTrue(app.staticTexts["Soustředění blokuje"].waitForExistence(timeout: 3), "zmrazení je v kalendáři")
        attachScreenshot(app, "Kalendář – zmrazení")
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
        // Nejdřív vnitřní posuvná oblast (mřížka kalendáře), pak stránka, nakonec okno.
        let areas = app.scrollViews.containing(.any, identifier: element.identifier).allElementsBoundByIndex.reversed()
            + [app.windows.firstMatch]
        for area in areas where !element.isHittable {
            // Nastavení je na malé obrazovce dlouhé (všechny sekce pod sebou) – posouvá se až 40 kroků.
            for delta in [-300.0, 300.0] {
                for _ in 0..<40 where !element.isHittable {
                    area.scroll(byDeltaX: 0, deltaY: delta)
                }
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
