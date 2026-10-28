import Foundation

/// Hotové seznamy, ze kterých si uživatel založí vlastní (a upraví je).
public enum FocusTemplates {
    public struct Template: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var apps: [FocusApp]
        public var sites: [String]

        /// Nový seznam podle šablony (vlastní id, výchozí přísnost).
        public func makeList(strictness: Strictness = .soft) -> FocusList {
            FocusList(name: name, apps: apps, sites: sites, strictness: strictness)
        }
    }

    public static let all: [Template] = [
        Template(id: "social", name: "Sociální sítě", apps: [], sites: [
            "facebook.com", "instagram.com", "tiktok.com", "x.com", "twitter.com", "reddit.com", "threads.com", "threads.net",
            "snapchat.com", "pinterest.com", "bsky.app", "9gag.com",
        ]),
        Template(id: "chat", name: "Chat", apps: [
            FocusApp(bundleId: "com.apple.MobileSMS", name: "Zprávy"),
            FocusApp(bundleId: "net.whatsapp.WhatsApp", name: "WhatsApp"),
            FocusApp(bundleId: "com.hnc.Discord", name: "Discord"),
            FocusApp(bundleId: "ru.keepcoder.Telegram", name: "Telegram"),
            FocusApp(bundleId: "org.telegram.desktop", name: "Telegram Desktop"),
        ], sites: ["messenger.com", "web.whatsapp.com", "discord.com", "web.telegram.org"]),
        Template(id: "video", name: "Video", apps: [
            FocusApp(bundleId: "com.apple.TV", name: "TV"),
        ], sites: [
            "youtube.com", "netflix.com", "twitch.tv", "max.com", "hbomax.com", "disneyplus.com", "primevideo.com",
            "voyo.nova.cz", "iprima.cz", "tv.apple.com",
        ]),
        Template(id: "news", name: "Zprávy", apps: [
            FocusApp(bundleId: "com.apple.news", name: "News"),
        ], sites: [
            "idnes.cz", "novinky.cz", "seznamzpravy.cz", "aktualne.cz", "irozhlas.cz", "denik.cz", "blesk.cz", "ct24.ceskatelevize.cz",
            "echo24.cz", "forum24.cz", "refresher.cz", "news.google.com", "bbc.com", "cnn.com",
        ]),
        Template(id: "games", name: "Hry", apps: [
            FocusApp(bundleId: "com.valvesoftware.steam", name: "Steam"),
            FocusApp(bundleId: "com.epicgames.EpicGamesLauncher", name: "Epic Games"),
            FocusApp(bundleId: "com.apple.Chess", name: "Šachy"),
        ], sites: [
            "store.steampowered.com", "chess.com", "lichess.org", "poki.com", "crazygames.com", "miniclip.com", "epicgames.com",
        ]),
        Template(id: "shopping", name: "Nakupování", apps: [], sites: [
            "alza.cz", "mall.cz", "aliexpress.com", "temu.com", "shein.com", "amazon.com", "amazon.de", "zalando.cz", "vinted.cz",
            "bazos.cz", "sbazar.cz", "heureka.cz",
        ]),
    ]
}
