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

    @MainActor private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
