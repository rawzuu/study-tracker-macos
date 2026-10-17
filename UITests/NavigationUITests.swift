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
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTesting"]
            app.launch()
        }
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
