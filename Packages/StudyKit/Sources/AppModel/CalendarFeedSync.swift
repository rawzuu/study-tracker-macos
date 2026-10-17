import Core
import Engine
import Foundation
import Networking
import Observation

/// Odebíraný kalendář (`calendarFeed.ts` na webu): plán a zkoušky se publikují do tajného gistu
/// a Apple Kalendář si je sám pravidelně stahuje. Po každé změně dat se s prodlevou 6 s obsah
/// sestaví znovu a nahraje, jen pokud se od posledního nahrání z tohoto Macu změnil.
///
/// V režimu „jen čtení“ Mac na GitHub nic nezapisuje – ani do gistu.
@MainActor
@Observable
public final class CalendarFeedSync {
    /// Poslední pokus o publikování z tohoto Macu (`st.feedStatus` na webu).
    public struct Status: Codable, Equatable, Sendable {
        public let at: Int
        public let error: String?
    }

    public private(set) var status: Status?
    public private(set) var busy = false

    @ObservationIgnored private let app: AppStore
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var observing = false

    static let hashKey = "st.feedHash"
    static let statusKey = "st.feedStatus"
    static let gistDescription = "Study Tracker – studijní plán (kalendář)"

    public init(app: AppStore, delay: Duration = .seconds(6)) {
        self.app = app
        self.delay = delay
        status = app.defaults.data(forKey: Self.statusKey).flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
    }

    /// Začne sledovat změny dat (po načtení dat při startu aplikace).
    public func start() {
        guard !observing else { return }
        observing = true
        observe()
        schedule()
    }

    /// Zapne odebíraný kalendář: vytvoří tajný gist s aktuálním plánem a uloží odkaz do nastavení
    /// (`{ gistId, owner, includeExams, alarmMin }` jako na webu).
    public func enable(includeExams: Bool, alarmMin: Int?) async throws {
        guard let gists = app.gistPublisher() else { throw FeedError.notConnected }
        busy = true
        defer { busy = false }
        let ics = IcsExport.feed(app.document, includeExams: includeExams, alarmMin: alarmMin, now: app.nowMs, clock: app.clock)
        let gist: CreatedGist
        do {
            gist = try await gists.createGist(file: IcsExport.feedFile, content: ics, description: Self.gistDescription)
        } catch {
            throw FeedError.github(error)
        }
        // Obsah je právě nahraný – další publikování až po skutečné změně.
        app.defaults.set("\(gist.id):\(IcsExport.hash(ics))", forKey: Self.hashKey)
        record(Status(at: app.nowMs, error: nil))
        app.updateSettings { s in
            s.calendarFeed = CalendarFeed(raw: [
                "gistId": .string(gist.id), "owner": .string(gist.owner), "includeExams": .bool(includeExams),
                "alarmMin": alarmMin.map { .number(Double($0)) } ?? .null,
            ])
        }
    }

    /// Zahrnout zkoušky; kalendář se pak sám aktualizuje.
    public func setIncludeExams(_ include: Bool) {
        changeFeed { $0.includeExams = include }
    }

    /// Připomenutí před blokem v minutách (`nil` = bez připomenutí).
    public func setAlarm(_ minutes: Int?) {
        changeFeed { $0.alarmMin = minutes }
    }

    /// Vypne publikování. Gist na GitHubu zůstane, jen se přestane aktualizovat.
    public func disable() {
        pending?.cancel()
        app.updateSettings { $0.calendarFeed = nil }
    }

    /// Publikuje hned (i když se obsah nezměnil) – „Aktualizovat teď“.
    public func publishNow() async {
        pending?.cancel()
        await publish(force: true)
    }

    // MARK: - Interní

    /// Sestaví obsah a nahraje ho, pokud se změnil (`publishFeed` na webu).
    @discardableResult
    func publish(force: Bool) async -> Bool {
        guard let feed = app.document.settings.calendarFeed, !feed.gistId.isEmpty, app.syncMode == .readWrite else { return false }
        guard let gists = app.gistPublisher() else {
            record(Status(at: app.nowMs, error: FeedError.notConnected.localizedDescription))
            return false
        }
        let ics = IcsExport.feed(app.document, includeExams: feed.includeExams, alarmMin: feed.alarmMin, now: app.nowMs, clock: app.clock)
        let hash = "\(feed.gistId):\(IcsExport.hash(ics))"
        if !force && app.defaults.string(forKey: Self.hashKey) == hash { return false }
        busy = true
        defer { busy = false }
        do {
            try await gists.updateGist(id: feed.gistId, file: IcsExport.feedFile, content: ics)
            app.defaults.set(hash, forKey: Self.hashKey)
            record(Status(at: app.nowMs, error: nil))
            return true
        } catch {
            record(Status(at: app.nowMs, error: FeedError.github(error).localizedDescription))
            return false
        }
    }

    /// Po změně dat publikovat s prodlevou – rychlé úpravy za sebou se nahrají najednou.
    private func schedule() {
        pending?.cancel()
        guard app.document.settings.calendarFeed != nil else { return }
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.publish(force: false)
        }
    }

    private func observe() {
        withObservationTracking {
            _ = app.document
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observe()
            }
        }
    }

    private func changeFeed(_ change: (inout CalendarFeed) -> Void) {
        app.updateSettings { s in
            guard var feed = s.calendarFeed else { return }
            change(&feed)
            s.calendarFeed = feed
        }
    }

    private func record(_ status: Status) {
        self.status = status
        if let data = try? JSONEncoder().encode(status) { app.defaults.set(data, forKey: Self.statusKey) }
    }
}

public enum FeedError: Error, LocalizedError, Equatable {
    case notConnected
    case github(GitHubError)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Nejdřív připoj synchronizaci s GitHubem."
        // Jako `gistError` na webu – token bez oprávnění ke gistům dostane 403 nebo 404.
        case .github(.unauthorized): "Neplatný token."
        case .github(.forbidden), .github(.notFound): "Token nemá oprávnění „Gists: Read and write“."
        case .github(let e): e.localizedDescription
        }
    }
}
