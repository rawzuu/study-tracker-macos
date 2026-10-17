import Foundation

/// Chyby GitHub API rozlišené stejně jako na webu (`describe()` v `github.ts`) a navíc
/// výpadek sítě a vyčerpaný limit požadavků, které se mají jen zkusit znovu později.
public enum GitHubError: Error, Sendable, Hashable {
    /// 401 – neplatný nebo vypršelý token.
    case unauthorized
    /// 403 – token nemá potřebné oprávnění.
    case forbidden
    /// 403/429 s vyčerpaným limitem požadavků.
    case rateLimited(retryAt: Date?)
    /// 404 – repo nebo větev neexistuje, nebo k nim token nemá přístup.
    case notFound
    /// 409/422 – soubor se mezitím změnil (jiný `sha`). Synchronizace to zkusí znovu.
    case conflict(status: Int)
    /// Jiná odpověď mimo 2xx.
    case http(status: Int)
    /// Síť nedostupná, vypršel čas, DNS… (`URLError.Code.rawValue`).
    case network(code: Int)
    /// Odpověď nemá očekávaný tvar.
    case invalidResponse
    case cancelled

    public var status: Int? {
        switch self {
        case .unauthorized: 401
        case .forbidden: 403
        case .notFound: 404
        case .conflict(let s), .http(let s): s
        case .rateLimited, .network, .invalidResponse, .cancelled: nil
        }
    }

    public var isConflict: Bool {
        if case .conflict = self { true } else { false }
    }

    /// Dočasná chyba – stačí počkat na další synchronizaci, uživatel nemusí nic měnit.
    public var isTransient: Bool {
        switch self {
        case .network, .rateLimited, .cancelled: true
        case .http(let s): s >= 500
        default: false
        }
    }

    static func from(status: Int, headers: [AnyHashable: Any]) -> GitHubError {
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String
        }
        if status == 429 || (status == 403 && (header("x-ratelimit-remaining") == "0" || header("retry-after") != nil)) {
            let retryAt = header("retry-after").flatMap(TimeInterval.init).map { Date(timeIntervalSinceNow: $0) }
                ?? header("x-ratelimit-reset").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            return .rateLimited(retryAt: retryAt)
        }
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409, 422: return .conflict(status: status)
        default: return .http(status: status)
        }
    }
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Neplatný token."
        case .forbidden: "Token nemá oprávnění (potřebuje Contents: Read and write)."
        case .notFound: "Repo nebo větev nenalezena (nebo k nim token nemá přístup)."
        case .conflict: "Konflikt verzí."
        case .rateLimited: "GitHub dočasně omezil počet požadavků. Zkusím to znovu později."
        case .http(let s): "GitHub vrátil chybu \(s)."
        case .network: "GitHub není dostupný – zkontroluj připojení k internetu."
        case .invalidResponse: "GitHub vrátil neočekávanou odpověď."
        case .cancelled: "Přerušeno."
        }
    }
}
