import Focus
import Foundation
import Testing
@testable import AppModel

@Suite("Soustředění – export a import seznamů")
struct FocusListsExportTests {
    @Test func roundTripWithoutPasswords() throws {
        var list = FocusList(id: "a", name: "Sociální sítě", apps: [FocusApp(bundleId: "com.hnc.Discord", name: "Discord")], sites: ["youtube.com"])
        list.strictness = Strictness(password: Unlock.makePassword("tajne"))
        let data = try FocusController.exportLists([list])
        #expect(!String(decoding: data, as: UTF8.self).contains("salt"))
        let back = FocusController.importLists(data, name: "soubor")
        #expect(back.count == 1)
        #expect(back[0].name == "Sociální sítě" && back[0].sites == ["youtube.com"] && back[0].apps == list.apps)
        #expect(back[0].id != "a" && back[0].strictness.password == nil)
    }

    @Test func plainTextBecomesOneList() {
        let text = "https://www.reddit.com/r/all\nyoutube.com, youtube.com;  ne-web\n9gag.com"
        let lists = FocusController.importLists(Data(text.utf8), name: "Weby")
        #expect(lists.count == 1)
        #expect(lists[0].name == "Weby")
        #expect(lists[0].sites == ["reddit.com/r/all", "youtube.com", "9gag.com"])
        #expect(FocusController.importLists(Data("nic tu není".utf8), name: "x").isEmpty)
    }
}
