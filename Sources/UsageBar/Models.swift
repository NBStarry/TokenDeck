import Foundation

// 用量窗口的稳定种类标识(逻辑判断用,不依赖显示文案)。
enum WindowKind: String, Codable, CaseIterable, Identifiable {
    case fiveHour
    case weekly

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .weekly:   return "周"
        }
    }

    // 设置 UI 里的完整名称。
    var settingsTitle: String {
        switch self {
        case .fiveHour: return "5 小时"
        case .weekly:   return "周额度"
        }
    }

    var durationSeconds: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 60 * 60
        case .weekly:   return 7 * 24 * 60 * 60
        }
    }

    // 从显示文案推断种类(兼容旧缓存/历史 label)。
    static func infer(fromLabel label: String) -> WindowKind {
        label.contains("周") ? .weekly : .fiveHour
    }
}

// 告警严重度:5h 紧急(红)、周 预警(橙)。角标取当前最高严重度。
enum AlertSeverity: Int, Comparable, Codable {
    case warning = 0    // 橙 — 周额度
    case critical = 1   // 红 — 5 小时

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func forWindow(_ kind: WindowKind) -> AlertSeverity {
        switch kind {
        case .fiveHour: return .critical
        case .weekly:   return .warning
        }
    }
}

// 归一化后的单个用量窗口(5 小时 / 周)。
struct UsageWindow: Identifiable {
    let id = UUID()
    let label: String      // "5 小时" / "周",仅用于显示
    let pct: Double         // 已用百分比 0–100
    let resetAt: Date?      // 重置时间
    let kind: WindowKind    // 逻辑判断用的稳定种类

    init(label: String, pct: Double, resetAt: Date?, kind: WindowKind? = nil) {
        self.label = label
        self.pct = pct
        self.resetAt = resetAt
        self.kind = kind ?? WindowKind.infer(fromLabel: label)
    }
}

// 模型广场里的一个模型(用于按来源/厂商分类展示)。
struct ModelEntry: Identifiable {
    var id: String { name }
    let name: String
    let vendor: String   // 来源/厂商名,如 OpenAI / Anthropic;未知归 "其他"
}

// 余额型服务(PhanRouter 等 New-API 网关)的归一化数据。
struct BalanceInfo {
    let balance: Double       // 当前余额(已按 quotaPerUnit 换算成货币)
    let used: Double          // 历史消耗
    let currency: String      // 货币符号,如 "$"
    let requestCount: Int?    // 累计请求次数
    let models: [ModelEntry]  // 模型广场列表

    // 按来源分组,组内按名称排序,组按模型数降序。
    var groupedModels: [(vendor: String, models: [ModelEntry])] {
        let groups = Dictionary(grouping: models, by: { $0.vendor })
        return groups
            .map { (vendor: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
            .sorted { ($0.models.count, $1.vendor) > ($1.models.count, $0.vendor) }
    }
}

struct ResetCredit: Codable {
    let expiresAt: Date?
    let applicable: Bool
}

struct ResetCredits: Codable {
    let availableCount: Int
    let applicableCount: Int?
    // nil 表示明细获取失败，不等于没有重置机会。
    let credits: [ResetCredit]?
}

// 一个服务的归一化用量。windows 用于用量窗口型(Claude/Codex),balance 用于余额型(PhanRouter)。
struct Usage {
    let plan: String?
    let windows: [UsageWindow]
    let balance: BalanceInfo?
    let resetCredits: ResetCredits?
    let apiInfo: APIInfo?

    init(plan: String? = nil, windows: [UsageWindow] = [], balance: BalanceInfo? = nil, resetCredits: ResetCredits? = nil, apiInfo: APIInfo? = nil) {
        self.plan = plan
        self.windows = windows
        self.balance = balance
        self.resetCredits = resetCredits
        self.apiInfo = apiInfo
    }
}

// 取数结果:成功带数据,失败带可读中文原因。
enum FetchOutcome {
    case success(Usage)
    case failure(String)
}

// UI 用的运行态。
enum ServiceStatus {
    case loading
    case ok(Usage, fetchedAt: Date)
    case stale(Usage, cachedAt: Date?, error: String)
    case error(String)
}

// 计费展示大类:订阅窗口型 vs API 余额/用量型。
enum BillingCategory: String, Codable, CaseIterable, Identifiable {
    case subscription
    case apiUsage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscription: return "订阅号"
        case .apiUsage: return "API 用量"
        }
    }
}

// 取数协议。新增渠道时优先复用 newAPI;特殊订阅号再新增具体 fetcher。
enum FetcherKind: String, Codable {
    case claudeOAuth
    case codexWham
    case newAPI
    case deepseek
    case yicloud
    case openRouter
    case unsupported
}

enum UsageAlertRule: String, Codable, CaseIterable, Identifiable {
    case usageExceedsElapsedWindowPercent
    case usageExceedsThresholdOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usageExceedsElapsedWindowPercent: return "跑赢时间进度"
        case .usageExceedsThresholdOnly: return "仅超过阈值"
        }
    }
}

// 单个窗口的告警配置(阈值 + 规则各自独立)。
struct WindowAlertConfig: Codable, Equatable {
    var enabled: Bool
    var threshold: Double          // 触发阈值(已用百分比)
    var rule: UsageAlertRule
    var paceMultiplier: Double

    init(enabled: Bool = true,
         threshold: Double = 60,
         rule: UsageAlertRule = .usageExceedsElapsedWindowPercent,
         paceMultiplier: Double = 1) {
        self.enabled = enabled
        self.threshold = threshold
        self.rule = rule
        self.paceMultiplier = paceMultiplier
    }

    enum CodingKeys: String, CodingKey { case enabled, threshold, rule, paceMultiplier }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? 60
        let ruleRaw = try c.decodeIfPresent(String.self, forKey: .rule)
        rule = ruleRaw.flatMap(UsageAlertRule.init(rawValue:)) ?? .usageExceedsElapsedWindowPercent
        paceMultiplier = try c.decodeIfPresent(Double.self, forKey: .paceMultiplier) ?? 1
    }
}

struct UsageAlertConfig: Codable, Equatable {
    var enabled: Bool
    var fiveHour: WindowAlertConfig
    var weekly: WindowAlertConfig
    var cooldownSeconds: Int
    var serviceIDs: [String]?

    // 默认:5h 沿用「跑赢时间进度 @60%」;周「仅超过阈值 @80%」。
    static let `default` = UsageAlertConfig()

    init(enabled: Bool = true,
         fiveHour: WindowAlertConfig = WindowAlertConfig(threshold: 60,
                                                         rule: .usageExceedsElapsedWindowPercent),
         weekly: WindowAlertConfig = WindowAlertConfig(threshold: 80,
                                                       rule: .usageExceedsThresholdOnly),
         cooldownSeconds: Int = 1800,
         serviceIDs: [String]? = nil) {
        self.enabled = enabled
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.cooldownSeconds = cooldownSeconds
        self.serviceIDs = serviceIDs
    }

    func config(for kind: WindowKind) -> WindowAlertConfig {
        switch kind {
        case .fiveHour: return fiveHour
        case .weekly:   return weekly
        }
    }

    mutating func setConfig(_ cfg: WindowAlertConfig, for kind: WindowKind) {
        switch kind {
        case .fiveHour: fiveHour = cfg
        case .weekly:   weekly = cfg
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, fiveHour, weekly, cooldownSeconds, serviceIDs
        // 旧字段(仅用于向后兼容解码):
        case minimumUsagePercent, rule, paceMultiplier, windows
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(fiveHour, forKey: .fiveHour)
        try c.encode(weekly, forKey: .weekly)
        try c.encode(cooldownSeconds, forKey: .cooldownSeconds)
        try c.encodeIfPresent(serviceIDs, forKey: .serviceIDs)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        cooldownSeconds = try c.decodeIfPresent(Int.self, forKey: .cooldownSeconds) ?? 1800
        serviceIDs = try c.decodeIfPresent([String].self, forKey: .serviceIDs)

        if let five = try c.decodeIfPresent(WindowAlertConfig.self, forKey: .fiveHour),
           let week = try c.decodeIfPresent(WindowAlertConfig.self, forKey: .weekly) {
            // 新格式
            fiveHour = five
            weekly = week
        } else {
            // 旧格式迁移:单一 minimumUsagePercent/rule/paceMultiplier/windows。
            // 5h 完整沿用旧值;周套用新默认(80% / 仅超过阈值),仅 enabled 跟随旧 windows。
            let oldThreshold = try c.decodeIfPresent(Double.self, forKey: .minimumUsagePercent) ?? 60
            let oldRuleRaw = try c.decodeIfPresent(String.self, forKey: .rule)
            let oldRule = oldRuleRaw.flatMap(UsageAlertRule.init(rawValue:)) ?? .usageExceedsElapsedWindowPercent
            let oldPace = try c.decodeIfPresent(Double.self, forKey: .paceMultiplier) ?? 1
            let oldWindows = try c.decodeIfPresent([String].self, forKey: .windows)
            let fiveEnabled = oldWindows.map { $0.contains(WindowKind.fiveHour.displayLabel) } ?? true
            let weekEnabled = oldWindows.map { $0.contains(WindowKind.weekly.displayLabel) } ?? true
            fiveHour = WindowAlertConfig(enabled: fiveEnabled, threshold: oldThreshold,
                                         rule: oldRule, paceMultiplier: oldPace)
            weekly = WindowAlertConfig(enabled: weekEnabled, threshold: 80,
                                       rule: .usageExceedsThresholdOnly, paceMultiplier: 1)
        }
    }
}

// 卡片可单独控制的展示内容。
enum DisplayContent: String, CaseIterable, Identifiable {
    case plan
    case fiveHour
    case weekly
    case resetCountdown
    case updatedAt
    case balance
    case used
    case requestCount
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plan: return "套餐"
        case .fiveHour: return "5 小时"
        case .weekly: return "周额度"
        case .resetCountdown: return "重置倒计时"
        case .updatedAt: return "更新时间"
        case .balance: return "当前余额"
        case .used: return "历史消耗"
        case .requestCount: return "请求次数"
        case .models: return "模型列表"
        }
    }

    static func options(for category: BillingCategory) -> [DisplayContent] {
        switch category {
        case .apiUsage:
            return [.balance, .used, .requestCount, .models, .updatedAt]
        case .subscription:
            return [.plan, .fiveHour, .weekly, .resetCountdown, .updatedAt]
        }
    }

    static func options(for config: ServiceConfig) -> [DisplayContent] {
        switch config.fetcher {
        case .deepseek: return [.balance, .updatedAt]
        case .openRouter: return [.balance, .used, .updatedAt]
        case .yicloud: return [.models, .updatedAt]
        default: return options(for: config.category)
        }
    }
}

struct ServiceDisplayOptions: Codable, Equatable {
    var plan: Bool
    var fiveHour: Bool
    var weekly: Bool
    var resetCountdown: Bool
    var updatedAt: Bool
    var balance: Bool
    var used: Bool
    var requestCount: Bool
    var models: Bool

    static let all = ServiceDisplayOptions()

    init(plan: Bool = true,
         fiveHour: Bool = true,
         weekly: Bool = true,
         resetCountdown: Bool = true,
         updatedAt: Bool = true,
         balance: Bool = true,
         used: Bool = true,
         requestCount: Bool = true,
         models: Bool = true) {
        self.plan = plan
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.resetCountdown = resetCountdown
        self.updatedAt = updatedAt
        self.balance = balance
        self.used = used
        self.requestCount = requestCount
        self.models = models
    }

    enum CodingKeys: String, CodingKey {
        case plan, fiveHour, weekly, resetCountdown, updatedAt
        case balance, used, requestCount, models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = try c.decodeIfPresent(Bool.self, forKey: .plan) ?? true
        fiveHour = try c.decodeIfPresent(Bool.self, forKey: .fiveHour) ?? true
        weekly = try c.decodeIfPresent(Bool.self, forKey: .weekly) ?? true
        resetCountdown = try c.decodeIfPresent(Bool.self, forKey: .resetCountdown) ?? true
        updatedAt = try c.decodeIfPresent(Bool.self, forKey: .updatedAt) ?? true
        balance = try c.decodeIfPresent(Bool.self, forKey: .balance) ?? true
        used = try c.decodeIfPresent(Bool.self, forKey: .used) ?? true
        requestCount = try c.decodeIfPresent(Bool.self, forKey: .requestCount) ?? true
        models = try c.decodeIfPresent(Bool.self, forKey: .models) ?? true
    }

    func isEnabled(_ item: DisplayContent) -> Bool {
        switch item {
        case .plan: return plan
        case .fiveHour: return fiveHour
        case .weekly: return weekly
        case .resetCountdown: return resetCountdown
        case .updatedAt: return updatedAt
        case .balance: return balance
        case .used: return used
        case .requestCount: return requestCount
        case .models: return models
        }
    }

    mutating func set(_ item: DisplayContent, enabled: Bool) {
        switch item {
        case .plan: plan = enabled
        case .fiveHour: fiveHour = enabled
        case .weekly: weekly = enabled
        case .resetCountdown: resetCountdown = enabled
        case .updatedAt: updatedAt = enabled
        case .balance: balance = enabled
        case .used: used = enabled
        case .requestCount: requestCount = enabled
        case .models: models = enabled
        }
    }
}

// 单个服务的配置(由 config.json 控制显示/顺序/颜色/内容项)。
struct ServiceConfig: Codable, Identifiable {
    let id: String          // "claude" | "codex"
    let title: String       // "Claude" / "Codex"
    let accent: String      // "#RRGGBB"
    var category: BillingCategory
    var fetcher: FetcherKind
    var credentialFile: String?
    var enabled: Bool
    var display: ServiceDisplayOptions

    enum CodingKeys: String, CodingKey {
        case id, title, accent, category, fetcher, credentialFile, enabled, display
    }

    init(id: String, title: String, accent: String, enabled: Bool = true,
         category: BillingCategory? = nil, fetcher: FetcherKind? = nil,
         credentialFile: String? = nil,
         display: ServiceDisplayOptions = .all) {
        self.id = id
        self.title = title
        self.accent = accent
        let resolvedCategory = category ?? Self.defaultCategory(for: id)
        self.category = resolvedCategory
        self.fetcher = fetcher ?? Self.defaultFetcher(for: id, category: resolvedCategory)
        self.credentialFile = credentialFile
        self.enabled = enabled
        self.display = display
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? "#8E8E93"
        let categoryRaw = try c.decodeIfPresent(String.self, forKey: .category)
        let resolvedCategory = categoryRaw.flatMap(BillingCategory.init(rawValue:))
            ?? Self.defaultCategory(for: id)
        category = resolvedCategory
        let fetcherRaw = try c.decodeIfPresent(String.self, forKey: .fetcher)
        fetcher = fetcherRaw.flatMap(FetcherKind.init(rawValue:))
            ?? Self.defaultFetcher(for: id, category: resolvedCategory)
        credentialFile = try c.decodeIfPresent(String.self, forKey: .credentialFile)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        display = try c.decodeIfPresent(ServiceDisplayOptions.self, forKey: .display) ?? .all
    }

    private static func defaultCategory(for id: String) -> BillingCategory {
        switch id {
        case "claude", "codex": return .subscription
        default: return .apiUsage
        }
    }

    private static func defaultFetcher(for id: String, category: BillingCategory) -> FetcherKind {
        switch id {
        case "claude": return .claudeOAuth
        case "codex": return .codexWham
        default:
            return category == .apiUsage ? .newAPI : .unsupported
        }
    }
}

// 整体配置。
struct AppConfig: Codable {
    var refreshSeconds: Int
    var alerts: UsageAlertConfig
    var services: [ServiceConfig]
    var codexAccounts: [CodexAccount] = []

    enum CodingKeys: String, CodingKey { case refreshSeconds, alerts, services, codexAccounts }

    init(refreshSeconds: Int, alerts: UsageAlertConfig = .default, services: [ServiceConfig]) {
        self.refreshSeconds = refreshSeconds
        self.alerts = alerts
        self.services = services
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codexAccounts = try c.decodeIfPresent([CodexAccount].self, forKey: .codexAccounts) ?? []
        refreshSeconds = try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 300
        alerts = try c.decodeIfPresent(UsageAlertConfig.self, forKey: .alerts) ?? .default
        services = try c.decodeIfPresent([ServiceConfig].self, forKey: .services)
            ?? AppConfig.default.services
    }

    static let `default` = AppConfig(
        refreshSeconds: 300,
        alerts: .default,
        services: [
            ServiceConfig(id: "claude", title: "Claude", accent: "#D97757",
                          category: .subscription, fetcher: .claudeOAuth),
            ServiceConfig(id: "codex", title: "Codex", accent: "#10A37F",
                          category: .subscription, fetcher: .codexWham),
            ServiceConfig(id: "phanrouter", title: "PhanRouter", accent: "#7C5CFC",
                          category: .apiUsage, fetcher: .newAPI,
                          credentialFile: "phanrouter.json"),
        ]
    )
}

// 运行态条目(配置 + 当前状态),供 UI 列表渲染。
struct ServiceRuntime: Identifiable {
    let config: ServiceConfig
    var status: ServiceStatus
    var isCurrentAccount = false
    var id: String { config.id }
}
