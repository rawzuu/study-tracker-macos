import SwiftUI

struct RootView: View {
    @State private var page: Page? = .prehled

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                ForEach(Page.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(Page.allCases.filter { $0.group == group }) { page in
                            Text(page.title)
                                .tag(page)
                                .accessibilityIdentifier("nav.\(page.rawValue)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            if let page {
                PlaceholderPage(page: page)
            }
        }
    }
}

/// Dočasná stránka, dokud daná část nevznikne.
private struct PlaceholderPage: View {
    let page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.title)
                .font(.largeTitle)
                .accessibilityIdentifier("page.title")
            Text("Připravuje se – milník \(page.milestone).")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(32)
        .navigationTitle(page.title)
    }
}
