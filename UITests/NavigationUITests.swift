import XCTest

/// Hlavní tok: aplikace se spustí a navigace přepíná stránky.
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSidebarSwitchesPages() {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["page.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Přehled")

        app.staticTexts["nav.planovac"].click()
        XCTAssertEqual(app.staticTexts["page.title"].label, "Kalendář")
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
