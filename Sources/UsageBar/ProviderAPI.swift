import Foundation

struct APIBalance: Codable {
    let currency: String
    let total: Double
    let toppedUp: Double
    let granted: Double
}

struct OpenRouterInfo: Codable {
    enum Scope: String, Codable { case account, key }
    let scope: Scope
    let used: Double
    let remaining: Double?
    let limit: Double?
    let reset: String?
}

struct APIInfo: Codable {
    let balances: [APIBalance]?
    let isAvailable: Bool?
    let models: [String]?
    var openRouter: OpenRouterInfo? = nil
}

struct ProviderAPIFetcher: UsageFetcher {
    let serviceID: String
    let kind: FetcherKind
    var readKey: (String) throws -> String? = CredentialStore.apiKey
    var request: (String, [String: String]) async throws -> (Any, Int) = {
        try await Http.getJSON($0, headers: $1)
    }

    func fetch() async -> FetchOutcome {
        let key: String
        do {
            guard let saved = try readKey(serviceID), !saved.isEmpty else {
                return .failure("未找到 API Key，请重新导入")
            }
            key = saved
        } catch { return .failure("无法读取钥匙串，请允许访问后刷新") }
        // 固定已验证的来源，避免配置变化把 Key 发往其他站点。
        let url: String
        switch kind {
        case .deepseek: url = "https://api.deepseek.com/user/balance"
        case .yicloud: url = "https://token-api.yicloud.com/v1/models"
        case .openRouter: url = "https://openrouter.ai/api/v1/key"
        default: return .failure("不支持的 API 渠道")
        }
        do {
            let (json, status) = try await request(url, ["Authorization": "Bearer \(key)", "Accept": "application/json"])
            if status == 401 || status == 403 { return .failure("API Key 无效或无查询权限，请检查后重新导入") }
            guard (200..<300).contains(status) else { return .failure("查询失败（HTTP \(status)），请稍后刷新") }
            if kind == .openRouter,
               let data = (json as? [String: Any])?["data"] as? [String: Any],
               data["is_management_key"] as? Bool == true {
                let (credits, code) = try await request("https://openrouter.ai/api/v1/credits",
                    ["Authorization": "Bearer \(key)", "Accept": "application/json"])
                guard (200..<300).contains(code) else {
                    return .failure("OpenRouter 账户余额查询失败（HTTP \(code)）")
                }
                return parseOpenRouter(credits, account: true)
            }
            return parse(json)
        } catch Http.HttpError.badPayload { return .failure("接口返回无法解析") }
        catch { return .failure("网络查询失败，请稍后刷新") }
    }

    func parse(_ json: Any) -> FetchOutcome {
        guard let obj = json as? [String: Any] else { return .failure("接口返回结构异常") }
        if kind == .openRouter { return parseOpenRouter(json, account: false) }
        if kind == .deepseek {
            guard let available = obj["is_available"] as? Bool,
                  let raw = obj["balance_infos"] as? [[String: Any]], !raw.isEmpty else {
                return .failure("未解析到余额数据")
            }
            var balances: [APIBalance] = []
            for row in raw {
                guard let currency = row["currency"] as? String, ["CNY", "USD"].contains(currency),
                      let total = number(row["total_balance"]),
                      let topped = number(row["topped_up_balance"]),
                      let granted = number(row["granted_balance"]) else { return .failure("余额数据格式异常") }
                balances.append(APIBalance(currency: currency, total: total, toppedUp: topped, granted: granted))
            }
            return .success(Usage(apiInfo: APIInfo(balances: balances, isAvailable: available, models: nil)))
        }
        guard kind == .yicloud, let rows = obj["data"] as? [[String: Any]] else {
            return .failure("未解析到授权模型列表")
        }
        var models: [String] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else { return .failure("授权模型数据格式异常") }
            models.append(id)
        }
        return .success(Usage(apiInfo: APIInfo(balances: nil, isAvailable: nil, models: Array(Set(models)).sorted())))
    }

    func parseOpenRouter(_ json: Any, account: Bool) -> FetchOutcome {
        guard let obj = json as? [String: Any], let data = obj["data"] as? [String: Any],
              let used = number(data[account ? "total_usage" : "usage"]), used >= 0 else {
            return .failure("OpenRouter 用量数据格式异常")
        }
        let info: OpenRouterInfo
        if account {
            guard let total = number(data["total_credits"]), total >= 0 else {
                return .failure("OpenRouter 账户额度数据格式异常")
            }
            info = OpenRouterInfo(scope: .account, used: used, remaining: total - used, limit: nil, reset: nil)
        } else {
            guard data["limit"] != nil, data["limit_remaining"] != nil else {
                return .failure("OpenRouter Key 限额字段缺失")
            }
            let limit = number(data["limit"])
            let remaining = number(data["limit_remaining"])
            for name in ["limit", "limit_remaining"] {
                if let value = data[name], !(value is NSNull), number(value) == nil {
                    return .failure("OpenRouter Key 限额格式异常")
                }
            }
            if let limit, limit < 0 { return .failure("OpenRouter Key 限额格式异常") }
            info = OpenRouterInfo(scope: .key, used: used, remaining: remaining,
                                  limit: limit, reset: data["limit_reset"] as? String)
        }
        return .success(Usage(apiInfo: APIInfo(balances: nil, isAvailable: nil, models: nil, openRouter: info)))
    }

    private func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let n = (value as? String).flatMap(Double.init) ?? (value as? NSNumber)?.doubleValue
        return n.flatMap { $0.isFinite ? $0 : nil }
    }
}

// 管理用一次性导入；Key 只经标准输入进入进程，不出现在参数、日志或配置中。
enum ProviderAPIImport {
    static func apply(_ keys: [String: String], config: inout AppConfig,
                      saveKey: (String, String) throws -> Void) throws {
        let definitions: [(String, String, String, FetcherKind)] = [
            ("deepseek", "DeepSeek", "#4D6BFE", .deepseek),
            ("yicloud", "易云 TokenFactory", "#8B5CF6", .yicloud),
            ("openrouter", "OpenRouter", "#A78BFA", .openRouter)
        ]
        guard !keys.isEmpty, keys.keys.allSatisfy({ ["deepseek", "yicloud", "openrouter"].contains($0) }),
              keys.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NSError(domain: "APIImport", code: 1)
        }
        // 先校验全部目标，避免同名的用户自定义渠道被覆盖。
        for (id, _, _, kind) in definitions where keys[id] != nil {
            guard config.services.filter({ $0.id == id }).count <= 1,
                  config.services.first(where: { $0.id == id }).map({ $0.fetcher == kind }) ?? true else {
                throw NSError(domain: "APIImport", code: 2)
            }
        }
        var next = config
        for (id, title, accent, kind) in definitions {
            guard let key = keys[id] else { continue }
            try saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines), id)
            if !next.services.contains(where: { $0.id == id }) {
                next.services.append(ServiceConfig(id: id, title: title, accent: accent,
                                                   category: .apiUsage, fetcher: kind))
            }
        }
        config = next
    }
}
