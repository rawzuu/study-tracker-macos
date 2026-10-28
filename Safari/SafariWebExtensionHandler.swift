import Focus
import Foundation
import SafariServices

/// Most mezi rozšířením Safari a Strážcem: rozšíření se ptá, jestli je adresa zablokovaná (podle stavu,
/// který zapisuje Strážce – stejná pravidla jako pro aplikace), a hlásí pokusy.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: Self.handle(message)]
        context.completeRequest(returningItems: [response])
    }

    static func handle(_ message: [String: Any]) -> [String: Any] {
        guard let files = FocusFiles.shared() else { return ["blocked": false, "guard": false] }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        files.markExtensionSeen(at: now)
        guard let report = files.readReport() else { return ["blocked": false, "guard": false] }
        let state = report.state(at: now)
        var out: [String: Any] = ["guard": now - report.generatedAt < 5 * 60_000, "rules": blockRules(state)]
        guard let text = message["url"] as? String, let url = URL(string: text), let target = SiteRule.target(of: url),
              let hit = state.check(host: target.host, path: target.path) else {
            out["blocked"] = false
            return out
        }
        var attempts = report.attemptsToday[hit.target.key] ?? 0
        switch message["type"] as? String {
        case "attempt":
            try? files.send(SafariAttempt(at: now, host: target.host, path: target.path))
            attempts += 1
        case "unlock":
            // Odemyká se na obrazovce Strážce (stejné překážky jako u aplikací).
            try? files.send(SafariAttempt(at: now, host: target.host, path: target.path, unlock: true, url: text))
        default:
            break
        }
        out["blocked"] = true
        out["name"] = hit.name
        out["lists"] = hit.listNames
        out["attempts"] = attempts
        out["locked"] = hit.strictness.locked
        out["canUnlock"] = hit.strictness.canUnlock
        if let until = hit.until { out["until"] = until }
        return out
    }

    /// Weby k zablokování ještě před načtením (declarativeNetRequest): domény a cesty ze seznamů „blokovat tyhle“
    /// bez platných odemknutí; výjimky v seznamech jako povolení. Slova a „jen tyhle weby“ hlídá kontrola při navigaci.
    static func blockRules(_ state: ActiveFocus) -> [String: [String]] {
        var block: [String] = []
        var allow: [String] = []
        for rule in state.rules where rule.list.mode == .block {
            for site in rule.list.siteRules where !state.exceptions.contains(where: { $0.until > state.now && $0.target == .site(site.host) }) || rule.strictness.locked {
                if !block.contains(site.text) { block.append(site.text) }
            }
            for site in rule.list.allowedRules where !allow.contains(site.text) { allow.append(site.text) }
        }
        return ["block": block, "allow": allow]
    }
}
