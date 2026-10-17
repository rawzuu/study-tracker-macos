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
        XCTAssertEqual(text(of: title), "Přehled")

        app.staticTexts["nav.planovac"].click()
        XCTAssertEqual(text(of: app.staticTexts["page.title"]), "Kalendář")
    }

    @MainActor
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// Na macOS nese text popisku SwiftUI `value`, ne `label`.
    @MainActor private func text(of element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }
}
