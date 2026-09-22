import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [ServiceRuntime]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshingServiceIDs: Set<String> = []
    @Published private(set) var config: AppConfig
    @Published private(set) var configSaveError: String?
    @Published private(set) var activeAlertCount = 0
    @Published private(set) var activeAlertSummary: String?
    @Published private(set) var highestActiveSeverity: AlertSeverity?

    private var timer: Timer?
    private var lastAlertAtByKey: [String: Date] = [:]
    // service id → (告警 key → 严重度)
    private var activeAlertsByService: [String: [String: AlertSeverity]] = [:]

    @Published private(set) var currentAccountID: String?
    @Published private(set) var accountError: String?
    @Published private(set) var accountNotice: String?
    private var currentCredentials: CredentialStore.CodexCreds?
    private var identityTimer: Timer?
    private let dependencies: UsageDependencies
    private var generations: [String: UUID] = [:]
    private var refreshAgain = false
    @Published private(set) var isSwitchingAccount = false

    func needsCLILogin(_ id: String) -> Bool {
        dependencies.savedCredentials(id)?.canLoginToCLI != true
    }

    @discardableResult
    func switchCLIAccount(_ id: String) -> Bool {
        guard !isSwitchingAccount, config.codexAccounts.contains(where: { $0.id == id }) else { return false }
        accountNotice = nil
        accountError = nil
        guard let creds = dependencies.savedCredentials(id), creds.canLoginToCLI else {
            accountError = "请先重新登录该账号以补齐 CLI 登录信息"
            return false
        }
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }
        do {
            try dependencies.switchCredentials(creds)
            synchronizeCurrentAccount()
            guard currentAccountID == id else { throw CodexAccountSwitcher.SwitchError.changed }
            accountNotice = "已切换。请新开或重新打开 Codex CLI 会话使用该账号。"
            Task { await refresh() }
            return true
        } catch {
            synchronizeCurrentAccount()
            accountError = error.localizedDescription
            return false
        }
    }

    init(config: AppConfig, dependencies: UsageDependencies = UsageDependencies()) {
        self.config = config
        self.dependencies = dependencies
        self.states = []
        synchronizeCurrentAccount()
        rebuildStates()
    }

    @discardableResult
    func synchronizeCurrentAccount() -> Bool {
        let next: CredentialStore.CodexCreds?
        if case .ok(let creds) = dependencies.currentCredentials() { next = creds } else { next = nil }
        guard next != currentCredentials else { return false }
        let previous = currentAccountID
        currentCredentials = next
        currentAccountID = next?.identity
        for id in [previous, currentAccountID].compactMap({ $0 }) { generations[id] = UUID() }
        rebuildStates()
        refreshActiveAlertsFromCurrentStates()
        return true
    }

    func addCurrentAccount() {
        accountNotice = nil
        synchronizeCurrentAccount()
        guard let creds = currentCredentials else {
            accountError = "未找到可识别的 Codex 登录，请先登录订阅账号"
            return
        }
        saveAccount(creds)
    }

    func importAccount(from url: URL) {
        accountNotice = nil
        accountError = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch dependencies.importCredentials(url) {
        case .ok(let creds): saveAccount(creds)
        case .missingFile: accountError = "所选目录未找到 auth.json，请先在该目录完成 Codex 登录"
        case .parseError: accountError = "无法读取登录文件，请选择 Codex 登录目录或有效的 auth.json"
        case .incomplete: accountError = "登录文件缺少订阅账号身份，请使用 ChatGPT 账号登录后重试"
        }
    }

    @discardableResult
    func saveAccount(_ creds: CredentialStore.CodexCreds, expectedID: String? = nil) -> Bool {
        accountNotice = nil
        if let expectedID, expectedID != creds.identity {
            accountError = "登录的账号不匹配，请选择原账号重新登录"
            return false
        }
        accountError = nil
        let previous = dependencies.savedCredentials(creds.identity)
        do {
            try dependencies.saveCredentials(creds)
            var next = config
            if !next.codexAccounts.contains(where: { $0.id == creds.identity }) {
                next.codexAccounts.append(CodexAccount(id: creds.identity, name: creds.displayName))
            }
            if let index = next.codexAccounts.firstIndex(where: { $0.id == creds.identity }) {
                next.codexAccounts[index].name = creds.displayName
            }
            guard applyConfig(next) else {
                if let previous { try dependencies.saveCredentials(previous) }
                else { try dependencies.removeCredentials(creds.identity) }
                accountError = configSaveError
                return false
            }
            generations[creds.identity] = UUID()
            accountError = nil
            accountNotice = "账号已添加／更新"
            Task { await refresh() }
            return true
        } catch { accountError = error.localizedDescription; return false }
    }

    func accountName(_ id: String) -> String {
        let creds = id == currentAccountID ? currentCredentials : dependencies.savedCredentials(id)
        return creds?.displayName ?? "Codex 账号 " + id.suffix(6)
    }

    func removeAccount(_ id: String) {
        accountNotice = nil
        guard config.codexAccounts.contains(where: { $0.id == id }) else { return }
        var next = config
        next.codexAccounts.removeAll { $0.id == id }
        do {
            // Persist first: a failed config write must never erase the saved login.
            try dependencies.saveConfig(next)
            do {
                try dependencies.removeCredentials(id)
            } catch {
                try dependencies.saveConfig(config)
                throw error
            }
            config = next
            generations[id] = UUID()
            rebuildStates()
            refreshActiveAlertsFromCurrentStates()
            configSaveError = nil
            accountError = nil
        } catch { accountError = error.localizedDescription }
    }

    func start() {
        if config.alerts.enabled { dependencies.requestNotificationAuthorization() }
        Task { await refresh() }
        scheduleTimer()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.synchronizeCurrentAccount() else { return }
                await self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        identityTimer = timer
    }

    func setServiceEnabled(_ id: String, enabled: Bool) {
        var next = config
        guard let idx = next.services.firstIndex(where: { $0.id == id }) else { return }
        next.services[idx].enabled = enabled
        applyConfig(next)
        if enabled { Task { await refresh() } }
    }

    func moveService(_ id: String, by delta: Int) {
        var next = config
        guard let idx = next.services.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = max(0, min(next.services.count - 1, idx + delta))
        guard newIndex != idx else { return }
        let item = next.services.remove(at: idx)
        next.services.insert(item, at: newIndex)
        applyConfig(next)
    }

    func setDisplayContent(_ item: DisplayContent, for id: String, enabled: Bool) {
        var next = config
        guard let idx = next.services.firstIndex(where: { $0.id == id }) else { return }
        next.services[idx].display.set(item, enabled: enabled)
        applyConfig(next)
    }

    func displayContentIsEnabled(_ item: DisplayContent, for id: String) -> Bool {
        config.services.first(where: { $0.id == id })?.display.isEnabled(item) ?? true
    }

    func setAlertsEnabled(_ enabled: Bool) {
        var next = config
        next.alerts.enabled = enabled
        guard applyConfig(next) else { return }
        if !enabled { clearActiveAlerts() }
        if enabled {
            dependencies.requestNotificationAuthorization()
            refreshActiveAlertsFromCurrentStates()
        }
    }

    func setWindowAlertEnabled(_ kind: WindowKind, enabled: Bool) {
        var next = config
        var wcfg = next.alerts.config(for: kind)
        wcfg.enabled = enabled
        next.alerts.setConfig(wcfg, for: kind)
        applyConfig(next)
        refreshActiveAlertsFromCurrentStates()
    }

    func setWindowAlertThreshold(_ kind: WindowKind, pct: Double) {
        var next = config
        var wcfg = next.alerts.config(for: kind)
        wcfg.threshold = min(100, max(0, pct))
        next.alerts.setConfig(wcfg, for: kind)
        applyConfig(next)
        refreshActiveAlertsFromCurrentStates()
    }

    func setWindowAlertRule(_ kind: WindowKind, rule: UsageAlertRule) {
        var next = config
        var wcfg = next.alerts.config(for: kind)
        wcfg.rule = rule
        next.alerts.setConfig(wcfg, for: kind)
        applyConfig(next)
        refreshActiveAlertsFromCurrentStates()
    }

    func setAlertCooldownMinutes(_ minutes: Int) {
        var next = config
        next.alerts.cooldownSeconds = max(60, minutes * 60)
        applyConfig(next)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(60, config.refreshSeconds))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @discardableResult
    private func applyConfig(_ next: AppConfig) -> Bool {
        do {
            try dependencies.saveConfig(next)
            config = next
            rebuildStates()
            refreshActiveAlertsFromCurrentStates()
            if timer != nil { scheduleTimer() }
            configSaveError = nil
            return true
        } catch {
            configSaveError = "配置保存失败:\(error.localizedDescription)"
            return false
        }
    }

    private func rebuildStates() {
        var existing: [String: ServiceStatus] = [:]
        for rt in states { existing[rt.id] = rt.status }
        var configs: [ServiceConfig] = []
        for cfg in config.services where cfg.enabled {
            guard cfg.fetcher == .codexWham else { configs.append(cfg); continue }
            // Codex is a channel template; account cards have identity-specific IDs.
            guard !configs.contains(where: { $0.fetcher == .codexWham }) else { continue }
            var accounts = config.codexAccounts
            if let id = currentAccountID, !accounts.contains(where: { $0.id == id }) {
                accounts.append(CodexAccount(id: id, name: accountName(id)))
            }
            if accounts.isEmpty {
                configs.append(ServiceConfig(id: "codex-unavailable", title: "Codex", accent: cfg.accent,
                                             category: .subscription, fetcher: .codexWham, display: cfg.display))
            }
            let names = Dictionary(uniqueKeysWithValues: Set(accounts.map(\.id)).map { ($0, accountName($0)) })
            var seen = Set<String>()
            for account in accounts where seen.insert(account.id).inserted {
                let name = names[account.id]!
                let duplicate = names.values.filter { $0 == name }.count > 1
                let suffix = duplicate ? " · " + account.id.suffix(6) : ""
                let unsaved = config.codexAccounts.contains { $0.id == account.id } ? "" : "（未保存）"
                configs.append(ServiceConfig(id: account.id, title: "Codex · " + name + suffix + unsaved, accent: cfg.accent,
                                             category: .subscription, fetcher: .codexWham, display: cfg.display))
            }
        }
        if let index = configs.firstIndex(where: { $0.id == currentAccountID }) {
            configs.insert(configs.remove(at: index), at: 0)
        }
        let ids = Set(configs.map(\.id))
        generations = generations.filter { ids.contains($0.key) }
        states = configs.map { cfg in
            if generations[cfg.id] == nil { generations[cfg.id] = UUID() }
            let status: ServiceStatus
            if let old = existing[cfg.id] { status = old }
            else if let cached = dependencies.readCache(cfg.id) {
                status = .stale(cached.usage, cachedAt: cached.ts, error: "加载中…")
            } else { status = .loading }
            return ServiceRuntime(config: cfg, status: status, isCurrentAccount: cfg.id == currentAccountID)
        }
        activeAlertsByService = activeAlertsByService.filter { ids.contains($0.key) }
        publishActiveAlerts()
    }

    func canRefreshService(_ id: String) -> Bool {
        !isRefreshing && !refreshingServiceIDs.contains(id) && refreshingServiceIDs.count < 4
            && states.contains { $0.id == id }
    }

    func refreshService(_ id: String) async {
        synchronizeCurrentAccount()
        guard canRefreshService(id), let runtime = states.first(where: { $0.id == id }),
              let generation = generations[id] else { return }
        refreshingServiceIDs.insert(id)
        defer {
            refreshingServiceIDs.remove(id)
            if refreshingServiceIDs.isEmpty && refreshAgain {
                Task { await refresh() }
            }
        }
        let credentials = runtime.config.fetcher == .codexWham
            ? (id == currentAccountID ? currentCredentials : dependencies.savedCredentials(id)) : nil
        let outcome = await dependencies.fetch(runtime.config, credentials)
        if synchronizeCurrentAccount() { refreshAgain = true }
        guard generations[id] == generation else { return }
        apply(outcome, to: id)
        lastUpdated = Date()
    }

    @discardableResult
    func configureOpenRouter(_ key: String) -> Bool {
        var next = config
        do {
            try ProviderAPIImport.apply(["openrouter": key], config: &next, saveKey: dependencies.saveAPIKey)
            guard applyConfig(next) else { return false }
            generations["openrouter"] = UUID()
            if isRefreshing || !refreshingServiceIDs.isEmpty {
                refreshAgain = true
            } else {
                Task { await refreshService("openrouter") }
            }
            return true
        } catch {
            configSaveError = "OpenRouter 保存失败，请检查 Key 或钥匙串权限后重试"
            return false
        }
    }

    func refresh() async {
        synchronizeCurrentAccount()
        guard !isRefreshing, refreshingServiceIDs.isEmpty else { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            let fetch = dependencies.fetch
            let jobs = states.map { rt in
                let credentials = rt.config.fetcher == .codexWham
                    ? (rt.id == currentAccountID ? currentCredentials : dependencies.savedCredentials(rt.id)) : nil
                return (rt.config, credentials, generations[rt.id]!)
            }
            refreshingServiceIDs = Set(jobs.map { $0.0.id })
            await withTaskGroup(of: (String, UUID, FetchOutcome).self) { group in
                var iterator = jobs.makeIterator()
                func enqueue() {
                    guard let (cfg, creds, generation) = iterator.next() else { return }
                    group.addTask { (cfg.id, generation, await fetch(cfg, creds)) }
                }
                for _ in 0..<min(4, jobs.count) { enqueue() }
                for await (id, generation, outcome) in group {
                    refreshingServiceIDs.remove(id)
                    if synchronizeCurrentAccount() { refreshAgain = true }
                    if generations[id] == generation { apply(outcome, to: id) }
                    enqueue()
                }
            }
            lastUpdated = Date()
        } while refreshAgain
    }

    private func apply(_ outcome: FetchOutcome, to id: String) {
        guard let idx = states.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let usage):
            dependencies.writeCache(usage, id)
            states[idx].status = .ok(usage, fetchedAt: Date())
            updateAlerts(for: states[idx].config, usage: usage, sendNotifications: true)
        case .failure(let msg):
            if let cached = dependencies.readCache(id) {
                states[idx].status = .stale(cached.usage, cachedAt: cached.ts, error: msg)
            } else {
                states[idx].status = .error(msg)
            }
            refreshActiveAlertsFromCurrentStates()
        }
    }

    private func updateAlerts(for service: ServiceConfig, usage: Usage, sendNotifications: Bool) {
        let alerts = config.alerts
        guard alerts.enabled, service.category == .subscription,
              service.fetcher != .codexWham || service.id == currentAccountID else {
            activeAlertsByService[service.id] = [:]
            publishActiveAlerts()
            return
        }
        if let serviceIDs = alerts.serviceIDs, !serviceIDs.contains(service.id),
           !(service.fetcher == .codexWham && serviceIDs.contains("codex")) {
            activeAlertsByService[service.id] = [:]
            publishActiveAlerts()
            return
        }

        let now = Date()
        var active: [String: AlertSeverity] = [:]
        for window in usage.windows {
            // 每个窗口用各自独立的阈值 / 规则 / 开关。
            let wcfg = alerts.config(for: window.kind)
            guard wcfg.enabled else { continue }
            let usagePct = min(100, max(0, window.pct))
            guard usagePct >= wcfg.threshold else { continue }

            let elapsedPct = elapsedWindowPercent(for: window, now: now)
            guard alertRuleMatches(wcfg.rule, usagePct: usagePct, elapsedPct: elapsedPct,
                                   paceMultiplier: wcfg.paceMultiplier) else { continue }

            let key = alertKey(serviceID: service.id, window: window, rule: wcfg.rule)
            active[key] = AlertSeverity.forWindow(window.kind)
            guard sendNotifications else { continue }
            if let last = lastAlertAtByKey[key],
               now.timeIntervalSince(last) < TimeInterval(max(60, alerts.cooldownSeconds)) {
                continue
            }
            lastAlertAtByKey[key] = now
            dependencies.notify("\(service.title) 用量提醒", alertBody(service: service, window: window,
                                               usagePct: usagePct, elapsedPct: elapsedPct,
                                               windowConfig: wcfg))
        }
        activeAlertsByService[service.id] = active
        publishActiveAlerts()
    }

    private func refreshActiveAlertsFromCurrentStates() {
        guard config.alerts.enabled else {
            clearActiveAlerts()
            return
        }
        for rt in states {
            switch rt.status {
            case .ok(let usage, _), .stale(let usage, _, _):
                updateAlerts(for: rt.config, usage: usage, sendNotifications: false)
            case .loading, .error:
                activeAlertsByService[rt.id] = [:]
            }
        }
        publishActiveAlerts()
    }

    private func clearActiveAlerts() {
        activeAlertsByService.removeAll()
        publishActiveAlerts()
    }

    private func publishActiveAlerts() {
        let severities = activeAlertsByService.values.flatMap { $0.values }
        activeAlertCount = severities.count
        activeAlertSummary = severities.isEmpty ? nil : "\(severities.count) 个用量告警"
        highestActiveSeverity = severities.max()
    }

    private func alertRuleMatches(_ rule: UsageAlertRule, usagePct: Double,
                                  elapsedPct: Double?, paceMultiplier: Double) -> Bool {
        switch rule {
        case .usageExceedsThresholdOnly:
            return true
        case .usageExceedsElapsedWindowPercent:
            guard let elapsedPct else { return false }
            let target = min(100, max(0, elapsedPct * max(0.1, paceMultiplier)))
            return usagePct > target
        }
    }

    private func elapsedWindowPercent(for window: UsageWindow, now: Date) -> Double? {
        guard let resetAt = window.resetAt else { return nil }
        let duration = window.kind.durationSeconds
        let remaining = resetAt.timeIntervalSince(now)
        let elapsed = duration - remaining
        return min(100, max(0, elapsed / duration * 100))
    }

    private func alertKey(serviceID: String, window: UsageWindow, rule: UsageAlertRule) -> String {
        let resetEpoch = Int(window.resetAt?.timeIntervalSince1970 ?? 0)
        return "\(serviceID):\(window.label):\(resetEpoch):\(rule.rawValue)"
    }

    private func alertBody(service: ServiceConfig, window: UsageWindow, usagePct: Double,
                           elapsedPct: Double?, windowConfig: WindowAlertConfig) -> String {
        let usageText = "\(Int(usagePct.rounded()))%"
        let thresholdText = "\(Int(windowConfig.threshold.rounded()))%"
        switch windowConfig.rule {
        case .usageExceedsThresholdOnly:
            return "\(service.title) \(window.label) 用量 \(usageText),已超过 \(thresholdText) 阈值。"
        case .usageExceedsElapsedWindowPercent:
            let elapsedText = elapsedPct.map { "\(Int($0.rounded()))%" } ?? "未知"
            return "\(service.title) \(window.label) 用量 \(usageText),窗口时间进度 \(elapsedText),已超过 \(thresholdText) 阈值。"
        }
    }
}
