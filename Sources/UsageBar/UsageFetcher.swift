import Foundation

protocol UsageFetcher {
    var serviceID: String { get }
    func fetch() async -> FetchOutcome
}

// 解析辅助:epoch(秒或毫秒) → Date。
private func dateFromEpoch(_ value: Any?) -> Date? {
    let raw: Double
    switch value {
    case let d as Double: raw = d
    case let i as Int: raw = Double(i)
    case let s as String: guard let d = Double(s) else { return nil }; raw = d
    default: return nil
    }
    let secs = raw > 1e11 ? raw / 1000.0 : raw
    return Date(timeIntervalSince1970: secs)
}

private func dateFromISO(_ value: Any?) -> Date? {
    guard let s = value as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

private func capitalizedPlan(_ value: Any?) -> String? {
    guard let s = value as? String, !s.isEmpty else { return nil }
    return s.prefix(1).uppercased() + s.dropFirst()
}

// ─── Claude ───────────────────────────────────────────────────
struct ClaudeFetcher: UsageFetcher {
    let serviceID = "claude"

    func fetch() async -> FetchOutcome {
        guard let token = CredentialStore.claudeToken() else {
            return .failure("未找到 Claude 登录凭证,请运行 claude 登录")
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
        ]
        let json: Any, status: Int
        do {
            (json, status) = try await Http.getJSON("https://api.anthropic.com/api/oauth/usage", headers: headers)
        } catch Http.HttpError.network(let msg) {
            return .failure("网络错误:\(msg)")
        } catch {
            return .failure("接口返回无法解析")
        }
        guard let data = json as? [String: Any] else { return .failure("接口返回结构异常") }
        if status == 401 { return .failure("Claude 登录已过期,请重新登录") }
        if status < 200 || status >= 300 { return .failure("接口请求失败 (HTTP \(status))") }

        var windows: [UsageWindow] = []
        for (key, label) in [("five_hour", "5 小时"), ("seven_day", "周")] {
            guard let w = data[key] as? [String: Any], let util = w["utilization"] else { continue }
            let pct: Double
            switch util {
            case let d as Double: pct = d
            case let i as Int: pct = Double(i)
            case let s as String: guard let d = Double(s) else { continue }; pct = d
            default: continue
            }
            windows.append(UsageWindow(label: label,
                                       pct: (pct * 10).rounded() / 10,
                                       resetAt: dateFromISO(w["resets_at"])))
        }
        guard !windows.isEmpty else { return .failure("未解析到用量数据(接口结构可能已变)") }
        return .success(Usage(plan: capitalizedPlan(data["plan_type"]), windows: windows))
    }
}

// ─── Codex / GPT ──────────────────────────────────────────────
struct CodexFetcher: UsageFetcher {
    let serviceID = "codex"
    var credentials: CredentialStore.CodexCreds? = nil

    func fetch() async -> FetchOutcome {
        let creds: CredentialStore.CodexCreds
        switch credentials.map(CredentialStore.CodexCredResult.ok) ?? CredentialStore.codexCreds() {
        case .ok(let c): creds = c
        case .missingFile: return .failure("未找到 Codex 认证文件,请先运行 codex login")
        case .parseError:  return .failure("Codex 认证文件解析失败")
        case .incomplete:  return .failure("Codex 凭证不完整,请运行 codex login")
        }

        let headers = [
            "Authorization": "Bearer \(creds.accessToken)",
            "ChatGPT-Account-Id": creds.accountId,
            "Accept": "application/json",
            "Origin": "https://chatgpt.com",
            "Referer": "https://chatgpt.com/",
        ]
        let json: Any, status: Int
        do {
            (json, status) = try await Http.getJSON("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        } catch Http.HttpError.network(let msg) {
            return .failure("网络错误:\(msg)")
        } catch {
            return .failure("接口返回无法解析")
        }
        guard let data = json as? [String: Any] else { return .failure("接口返回结构异常") }
        if status == 401 { return .failure("Codex 登录已过期，请登录该账号后在设置中添加／更新") }
        if status < 200 || status >= 300 { return .failure("接口请求失败 (HTTP \(status))") }

        // 部分情况下接口以 200 返回错误信封。
        if let err = data["error"] as? [String: Any] {
            let code = (err["code"] as? String) ?? ""
            let msg = (err["message"] as? String) ?? ""
            if code.contains("expired") || msg.contains("expired") || (data["status"] as? Int) == 401 {
                return .failure("Codex 登录已过期，请登录该账号后在设置中添加／更新")
            }
            return .failure("Codex 接口返回错误，请稍后重试")
        }

        // 明细失败不影响用量；只调用 GET，绝不消费重置机会。
        var detail: [String: Any]?
        if let (json, code) = try? await Http.getJSON(
            "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", headers: headers),
           (200..<300).contains(code) {
            detail = json as? [String: Any]
        }
        return parseUsage(data, resetDetail: detail)
    }

    func parseUsage(_ data: [String: Any], resetDetail: [String: Any]? = nil) -> FetchOutcome {
        let rl = pickDict(data, "rate_limit", "rate_limits") ?? data
        let primary = pickDict(rl, "five_hour", "five_hour_limit", "five_hour_rate_limit", "primary", "primary_window")
        let secondary = pickDict(rl, "weekly", "weekly_limit", "weekly_rate_limit", "secondary", "secondary_window")
        var windows: [UsageWindow] = []
        for (raw, fallback) in [(primary, WindowKind.fiveHour), (secondary, WindowKind.weekly)] {
            guard let raw, let pct = usedPct(raw) else { continue }
            let kind: WindowKind
            if let seconds = numeric(raw["limit_window_seconds"]) {
                guard let match = WindowKind.allCases.first(where: { $0.durationSeconds == seconds }) else { continue }
                kind = match
            } else {
                kind = fallback
            }
            windows.append(UsageWindow(label: kind.displayLabel, pct: (pct * 10).rounded() / 10,
                                       resetAt: resetAt(raw), kind: kind))
        }
        guard !windows.isEmpty else { return .failure("未解析到支持的用量窗口(接口结构可能已变)") }
        return .success(Usage(plan: capitalizedPlan(data["plan_type"]), windows: windows,
                              resetCredits: parseResetCredits(data, detail: resetDetail)))
    }

    func parseResetCredits(_ data: [String: Any], detail: [String: Any]?) -> ResetCredits? {
        let summary = data["rate_limit_reset_credits"] as? [String: Any]
        let validDetail = detail.flatMap { d -> [String: Any]? in
            guard d["available_count"] is Int, d["credits"] is [[String: Any]] else { return nil }
            return d
        }
        guard let count = (validDetail?["available_count"] as? Int) ?? (summary?["available_count"] as? Int),
              count >= 0 else { return nil }
        let credits = (validDetail?["credits"] as? [[String: Any]])?.filter {
            $0["status"] as? String == "available"
        }.map {
            ResetCredit(expiresAt: dateFromISO($0["expires_at"]) ?? dateFromEpoch($0["expires_at"]),
                        applicable: $0["is_supported_by_plan"] as? Bool ?? false)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return ResetCredits(availableCount: count,
                            applicableCount: credits.map { $0.filter(\.applicable).count }
                                ?? (summary?["applicable_available_count"] as? Int), credits: credits)
    }

    private func pickDict(_ d: [String: Any], _ keys: String...) -> [String: Any]? {
        for k in keys { if let v = d[k] as? [String: Any] { return v } }
        return nil
    }

    // percent_left / remaining_percent 表示"剩余",换算成"已用";否则取 used_percent。
    private func usedPct(_ w: [String: Any]) -> Double? {
        for k in ["percent_left", "remaining_percent"] {
            if let v = numeric(w[k]) { return max(0.0, 100.0 - v) }
        }
        if let v = numeric(w["used_percent"]) { return v }
        return nil
    }

    private func resetAt(_ w: [String: Any]) -> Date? {
        for k in ["reset_time_ms", "reset_at"] {
            if let v = w[k] {
                if k == "reset_time_ms" { if let d = dateFromEpoch(v) { return d } }
                else { if let d = dateFromEpoch(v) ?? dateFromISO(v) { return d } }
            }
        }
        if let nested = w["primary_window"] as? [String: Any] { return resetAt(nested) }
        return nil
    }

    private func numeric(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

// ─── New-API 兼容网关 ──────────────────────────────────────────
// 余额 + 历史消耗(/api/user/self),模型广场(/api/pricing,公开)。
struct NewAPIFetcher: UsageFetcher {
    let serviceID: String
    let title: String
    let credentialFile: String

    init(config: ServiceConfig) {
        serviceID = config.id
        title = config.title
        credentialFile = config.credentialFile ?? "\(config.id).json"
    }

    func fetch() async -> FetchOutcome {
        let creds: CredentialStore.NewAPICreds
        switch CredentialStore.newAPICreds(fileName: credentialFile) {
        case .ok(let c): creds = c
        case .missingFile(let path): return .failure("未找到 \(title) 凭证,请配置 \(path)")
        case .invalidPath: return .failure("\(title) 凭证文件路径无效")
        case .incomplete:  return .failure("\(title) 凭证不完整(需 baseUrl + accessToken)")
        }
        let base = creds.baseURL.hasSuffix("/") ? String(creds.baseURL.dropLast()) : creds.baseURL

        // 1) 余额 + 历史消耗(需鉴权)
        let authHeaders = [
            "Authorization": "Bearer \(creds.accessToken)",
            "New-Api-User": String(creds.userId),
            "Accept": "application/json",
        ]
        let selfJSON: Any, selfStatus: Int
        do {
            (selfJSON, selfStatus) = try await Http.getJSON("\(base)/api/user/self", headers: authHeaders)
        } catch Http.HttpError.network(let msg) {
            return .failure("网络错误:\(msg)")
        } catch {
            return .failure("接口返回无法解析")
        }
        guard let selfObj = selfJSON as? [String: Any] else { return .failure("接口返回结构异常") }
        if selfStatus == 401 { return .failure("\(title) 访问令牌已失效,请重新生成") }
        if selfObj["success"] as? Bool == false {
            let msg = (selfObj["message"] as? String) ?? "未知错误"
            if msg.contains("access token") { return .failure("\(title) 访问令牌无效,请重新生成") }
            return .failure("接口返回错误:\(msg)")
        }
        guard let data = selfObj["data"] as? [String: Any],
              let quota = numeric(data["quota"]) else {
            return .failure("未解析到余额数据(接口结构可能已变)")
        }
        let unit = creds.quotaPerUnit > 0 ? creds.quotaPerUnit : 500000
        let balance = quota / unit
        let used = (numeric(data["used_quota"]) ?? 0) / unit
        let reqCount = (data["request_count"] as? Int) ?? numeric(data["request_count"]).map { Int($0) }

        // 2) 模型广场(公开接口,失败不致命)
        let models = await fetchModels(base: base, headers: authHeaders)

        let info = BalanceInfo(balance: balance, used: used, currency: creds.currency,
                               requestCount: reqCount, models: models)
        return .success(Usage(balance: info))
    }

    private func fetchModels(base: String, headers: [String: String]) async -> [ModelEntry] {
        guard let (json, status) = try? await Http.getJSON("\(base)/api/pricing", headers: headers),
              status >= 200, status < 300,
              let obj = json as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }

        // vendor_id → 厂商名
        var vendorName: [Int: String] = [:]
        if let vendors = obj["vendors"] as? [[String: Any]] {
            for v in vendors {
                if let id = v["id"] as? Int, let name = v["name"] as? String { vendorName[id] = name }
            }
        }
        return list.compactMap { m in
            guard let name = m["model_name"] as? String else { return nil }
            let vid = m["vendor_id"] as? Int
            // 优先用接口的 vendor_id 映射;缺失时按模型名前缀推断来源。
            let vendor = vid.flatMap { vendorName[$0] } ?? inferVendor(from: name)
            return ModelEntry(name: name, vendor: vendor)
        }
    }

    // 按模型名推断厂商(接口 vendor_id 缺失时的兜底)。
    private func inferVendor(from model: String) -> String {
        let n = model.lowercased()
        // PhanRouter 自有改名:前缀 PR-<字母>- 即厂商代码(注意 pr-ge 要在 pr-g 之前判断)。
        let prefixes: [(String, String)] = [
            ("pr-a-", "Anthropic"), ("pr-ge", "Google"), ("pr-g-", "Google"),
            ("pr-o-", "OpenAI"), ("pr-x-", "xAI"), ("pr-v-", "视频生成"),
        ]
        for (p, v) in prefixes where n.hasPrefix(p) { return v }

        let rules: [(keys: [String], vendor: String)] = [
            (["gpt", "o1", "o3", "o4", "chatgpt", "davinci", "text-embedding", "dall-e", "whisper", "tts", "sora", "codex"], "OpenAI"),
            (["claude"], "Anthropic"),
            (["gemini", "gemma", "imagen", "veo"], "Google"),
            (["deepseek"], "DeepSeek"),
            (["qwen", "qwq", "tongyi", "wan", "wanx"], "阿里巴巴"),
            (["doubao", "seed", "ui-tars"], "字节跳动"),
            (["moonshot", "kimi"], "Moonshot"),
            (["glm", "chatglm", "cogview", "cogvideo"], "智谱"),
            (["grok"], "xAI"),
            (["kling"], "快手"),
            (["ernie", "wenxin"], "百度"),
            (["llama"], "Meta"),
            (["hunyuan"], "腾讯"),
            (["minimax", "abab"], "MiniMax"),
            (["step-"], "阶跃星辰"),
            (["spark"], "讯飞"),
            (["jina"], "Jina"),
            (["flux"], "Black Forest"),
            (["midjourney", "mj_", "mj-"], "Midjourney"),
            (["suno"], "Suno"),
            (["xiaomi", "mimo"], "小米"),
            (["speech-"], "MiniMax"),
            (["sd1", "sd2", "sd3", "sdxl", "stable"], "Stability"),
            (["kat-", "kwai"], "快手"),
        ]
        for r in rules where r.keys.contains(where: { n.contains($0) }) {
            return r.vendor
        }
        return "其他"
    }

    private func numeric(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

func makeFetcher(for config: ServiceConfig) -> UsageFetcher? {
    switch config.fetcher {
    case .claudeOAuth:
        return ClaudeFetcher()
    case .codexWham:
        return CodexFetcher()
    case .newAPI:
        return NewAPIFetcher(config: config)
    case .deepseek, .yicloud, .openRouter:
        return ProviderAPIFetcher(serviceID: config.id, kind: config.fetcher)
    case .unsupported:
        return nil
    }
}

func makeFetcher(for serviceID: String) -> UsageFetcher? {
    let configured = AppConfigStore.load().services.first { $0.id == serviceID }
        ?? AppConfig.default.services.first { $0.id == serviceID }
    guard let configured else {
        return nil
    }
    return makeFetcher(for: configured)
}
