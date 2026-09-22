import Foundation

// 契约镜像结构。字段名即 JSON 键(camelCase),与 Rust ServiceSnapshot / 手机 types.ts 对齐。
// 注意：直接编码 ServiceConfig 会得到 fetcher:"claudeOAuth"（Swift rawValue），
// 但契约要求 "claudeOauth"（手机 types.ts FetcherKind），因此这里使用 RelayConfig 镜像。

private struct RelayPayload: Encodable { let ts: String?; let services: [RelayService] }

private struct RelayConfig: Encodable {
    let id: String
    let title: String
    let accent: String
    let category: String   // "subscription" | "apiUsage"
    let fetcher: String    // "claudeOauth" | "codexWham" | "newAPI"
    let credentialFile: String?
    let enabled: Bool
    let display: ServiceDisplayOptions
}

private struct RelayService: Encodable { let config: RelayConfig; let status: RelayStatus }
private struct RelayWindow: Encodable { let label: String; let pct: Double; let resetAt: String? }
private struct RelayModel: Encodable { let name: String; let vendor: String }
private struct RelayBalance: Encodable {
    let balance: Double; let used: Double; let currency: String
    let requestCount: Int?; let models: [RelayModel]
}
private struct RelayResetCredit: Encodable { let expiresAt: String?; let applicable: Bool }
private struct RelayResetCredits: Encodable {
    let availableCount: Int; let applicableCount: Int?; let credits: [RelayResetCredit]?
}
private struct RelayUsage: Encodable {
    let plan: String?; let windows: [RelayWindow]; let balance: RelayBalance?
    let apiInfo: APIInfo?
    let resetCredits: RelayResetCredits?
}
// status: { kind, usage?, fetchedAt?, cachedAt?, error?, message? }
private struct RelayStatus: Encodable {
    let kind: String
    let usage: RelayUsage?
    let fetchedAt: String?
    let cachedAt: String?
    let error: String?
    let message: String?
}

nonisolated(unsafe) private let isoFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private func iso(_ d: Date?) -> String? { d.map { isoFmt.string(from: $0) } }

// 将 BillingCategory 转换为契约 JSON 字符串（与手机 types.ts 对齐）。
private func categoryString(_ c: BillingCategory) -> String {
    switch c {
    case .subscription: return "subscription"
    case .apiUsage: return "apiUsage"
    }
}

// 将 FetcherKind 转换为契约 JSON 字符串（与手机 types.ts 对齐）。
// Swift rawValue: "claudeOAuth"（大写 A），契约要求 "claudeOauth"（小写 a）。
private func fetcherString(_ f: FetcherKind) -> String {
    switch f {
    case .claudeOAuth: return "claudeOauth"
    case .codexWham:   return "codexWham"
    case .newAPI:      return "newAPI"
    case .deepseek: return "deepseek"
    case .yicloud: return "yicloud"
    case .openRouter: return "unsupported" // Older mobile decoders must still accept the snapshot.
    case .unsupported: return "unsupported"
    }
}

private func mapConfig(_ c: ServiceConfig) -> RelayConfig {
    let title = c.id == "codex" ? "Codex" : c.title
    return RelayConfig(
        id: c.id,
        title: title,
        accent: c.accent,
        category: categoryString(c.category),
        fetcher: fetcherString(c.fetcher),
        credentialFile: c.fetcher == .codexWham ? nil : c.credentialFile,
        enabled: c.enabled,
        display: c.display
    )
}

private func mapUsage(_ u: Usage) -> RelayUsage {
    RelayUsage(
        plan: u.plan,
        windows: u.windows.map { RelayWindow(label: $0.label, pct: $0.pct, resetAt: iso($0.resetAt)) },
        balance: u.balance.map { b in
            RelayBalance(balance: b.balance, used: b.used, currency: b.currency,
                         requestCount: b.requestCount,
                         models: b.models.map { RelayModel(name: $0.name, vendor: $0.vendor) })
        },
        apiInfo: u.apiInfo,
        resetCredits: u.resetCredits.map { r in
            RelayResetCredits(availableCount: r.availableCount, applicableCount: r.applicableCount,
                              credits: r.credits?.map { RelayResetCredit(expiresAt: iso($0.expiresAt), applicable: $0.applicable) })
        })
}

private func mapStatus(_ s: ServiceStatus) -> RelayStatus {
    switch s {
    case .loading:
        return RelayStatus(kind: "loading", usage: nil, fetchedAt: nil, cachedAt: nil, error: nil, message: nil)
    case .ok(let u, let at):
        return RelayStatus(kind: "ok", usage: mapUsage(u), fetchedAt: iso(at), cachedAt: nil, error: nil, message: nil)
    case .stale(let u, let cachedAt, let err):
        return RelayStatus(kind: "stale", usage: mapUsage(u), fetchedAt: nil, cachedAt: iso(cachedAt), error: err, message: nil)
    case .error(let msg):
        return RelayStatus(kind: "error", usage: nil, fetchedAt: nil, cachedAt: nil, error: nil, message: msg)
    }
}

func relayPayloadJSON(states: [ServiceRuntime], lastUpdated: Date?) -> Data {
    let payload = RelayPayload(
        ts: iso(lastUpdated),
        services: states.map { RelayService(config: mapConfig($0.config), status: mapStatus($0.status)) })
    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes]
    return (try? enc.encode(payload)) ?? Data("{\"services\":[]}".utf8)
}
