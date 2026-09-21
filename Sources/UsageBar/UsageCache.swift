import Foundation

// 缓存到 ~/.cache/usage-dashboard/<service>.json。
// 用量窗口型:{"ts","plan","windows":[{"label","pct","resetAt"}]}(与旧 Python 版兼容)
// 余额型:    {"ts","balance":{"balance","used","currency","requestCount","models":[{"name","vendor"}]}}
enum UsageCache {
    struct Cached { let usage: Usage; let ts: Date? }

    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/usage-dashboard", isDirectory: true)
    }
    private static func path(_ service: String) -> URL {
        dir.appendingPathComponent("\(service).json")
    }

    private static var iso: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func write(_ usage: Usage, service: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = ["ts": iso.string(from: Date()), "windowSchema": 1]
        obj["plan"] = usage.plan ?? NSNull()
        obj["windows"] = usage.windows.map { w -> [String: Any] in
            ["label": w.label,
             "pct": w.pct,
             "resetAt": w.resetAt.map { iso.string(from: $0) } ?? NSNull()]
        }
        if let credits = usage.resetCredits, let encoded = try? JSONEncoder().encode(credits),
           let value = try? JSONSerialization.jsonObject(with: encoded) {
            obj["resetCredits"] = value
        }
        if let info = usage.apiInfo, let encoded = try? JSONEncoder().encode(info),
           let value = try? JSONSerialization.jsonObject(with: encoded) {
            obj["apiInfo"] = value
        }
        if let b = usage.balance {
            obj["balance"] = [
                "balance": b.balance,
                "used": b.used,
                "currency": b.currency,
                "requestCount": b.requestCount ?? NSNull(),
                "models": b.models.map { ["name": $0.name, "vendor": $0.vendor] },
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) {
            try? data.write(to: path(service))
        }
    }

    static func read(_ service: String) -> Cached? {
        guard let data = try? Data(contentsOf: path(service)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // 旧 Codex 缓存曾把周 primary 标为 5 小时，不能用于显示或告警。
        if (service == "codex" || service.hasPrefix("codex-")), obj["windowSchema"] as? Int != 1 {
            return nil
        }
        let ts = (obj["ts"] as? String).flatMap { iso.date(from: $0) }
        let plan = obj["plan"] as? String

        if let value = obj["apiInfo"],
           let encoded = try? JSONSerialization.data(withJSONObject: value),
           let info = try? JSONDecoder().decode(APIInfo.self, from: encoded) {
            return Cached(usage: Usage(apiInfo: info), ts: ts)
        }
        // 余额型
        if let b = obj["balance"] as? [String: Any], let bal = num(b["balance"]) {
            let models = (b["models"] as? [[String: Any]] ?? []).compactMap { m -> ModelEntry? in
                guard let name = m["name"] as? String else { return nil }
                return ModelEntry(name: name, vendor: (m["vendor"] as? String) ?? "其他")
            }
            let info = BalanceInfo(balance: bal, used: num(b["used"]) ?? 0,
                                   currency: (b["currency"] as? String) ?? "$",
                                   requestCount: b["requestCount"] as? Int, models: models)
            return Cached(usage: Usage(balance: info), ts: ts)
        }

        // 用量窗口型
        let rawWindows = obj["windows"] as? [[String: Any]] ?? []
        let windows = rawWindows.compactMap { w -> UsageWindow? in
            guard let label = w["label"] as? String, let pct = num(w["pct"]) else { return nil }
            let resetAt = (w["resetAt"] as? String).flatMap { iso.date(from: $0) }
            return UsageWindow(label: label, pct: pct, resetAt: resetAt)
        }
        guard !windows.isEmpty else { return nil }
        let credits = obj["resetCredits"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(ResetCredits.self, from: $0) }
        return Cached(usage: Usage(plan: plan, windows: windows, resetCredits: credits), ts: ts)
    }

    private static func num(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
