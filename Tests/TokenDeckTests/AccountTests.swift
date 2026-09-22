import XCTest
import SwiftUI
@testable import TokenDeck

private func credentials(_ number: Int, token: String = "token") -> CredentialStore.CodexCreds {
    .init(accessToken: token, accountId: "workspace", userId: "user-\(number)")
}

private func usage(_ pct: Double) -> Usage {
    Usage(plan: "Plus", windows: [UsageWindow(label: "5 小时", pct: pct,
                                              resetAt: Date(timeIntervalSince1970: 2_000_000_000))])
}

private actor Requests {
    var active = 0
    var maximum = 0
    var calls = 0
    var delay: UInt64 = 0
    var values: [String: Double] = [:]
    var failures = Set<String>()

    func configure(delay: UInt64 = 0, values: [String: Double] = [:], failures: Set<String> = []) {
        self.delay = delay
        self.values = values
        self.failures = failures
    }

    func fetch(_ cfg: ServiceConfig, _ creds: CredentialStore.CodexCreds?) async -> FetchOutcome {
        active += 1
        calls += 1
        maximum = max(maximum, active)
        let value = values[cfg.id] ?? 10
        let failed = failures.contains(cfg.id)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        active -= 1
        if failed || (cfg.fetcher == .codexWham && creds == nil) { return .failure("登录已过期，请重新登录后添加／更新") }
        return .success(usage(value))
    }
}

@MainActor
private final class Fixture {
    var current: CredentialStore.CodexCreds?
    var saved: [String: CredentialStore.CodexCreds] = [:]
    var cache: [String: UsageCache.Cached] = [:]
    var notifications: [String] = []
    var persisted: AppConfig?
    var failSave = false
    let requests = Requests()

    func dependencies() -> UsageDependencies {
        var result = UsageDependencies()
        result.currentCredentials = { self.current.map(CredentialStore.CodexCredResult.ok) ?? .missingFile }
        result.savedCredentials = { self.saved[$0] }
        result.saveCredentials = { self.saved[$0.identity] = $0 }
        result.removeCredentials = { self.saved[$0] = nil }
        result.saveConfig = {
            if self.failSave { throw NSError(domain: "test", code: 1) }
            self.persisted = $0
        }
        result.readCache = { self.cache[$0] }
        result.writeCache = { self.cache[$1] = .init(usage: $0, ts: Date()) }
        result.requestNotificationAuthorization = {}
        result.notify = { self.notifications.append($0 + $1) }
        let requests = requests
        result.fetch = { await requests.fetch($0, $1) }
        return result
    }

    func config(count: Int, claude: Bool = false) -> AppConfig {
        var config = AppConfig.default
        config.services = config.services.filter { $0.id == "codex" || (claude && $0.id == "claude") }
        config.alerts.fiveHour.rule = .usageExceedsThresholdOnly
        config.alerts.fiveHour.threshold = 60
        config.codexAccounts = (0..<count).map {
            let creds = credentials($0)
            saved[creds.identity] = creds
            return CodexAccount(id: creds.identity, name: "Account \($0)")
        }
        return config
    }
}

final class AccountTests: XCTestCase {
    @MainActor func testRotatingAPIKeyDiscardsInflightResultAndRefreshes() async throws {
        let fixture = Fixture()
        var config = fixture.config(count: 0)
        config.services = [ServiceConfig(id: "openrouter", title: "OpenRouter", accent: "#A78BFA", category: .apiUsage, fetcher: .openRouter)]
        var dependencies = fixture.dependencies()
        var savedKey = ""
        dependencies.saveAPIKey = { key, id in
            XCTAssertEqual(id, "openrouter")
            savedKey = key
        }
        let store = UsageStore(config: config, dependencies: dependencies)
        await fixture.requests.configure(delay: 80_000_000, values: ["openrouter": 11])
        let first = Task { await store.refreshService("openrouter") }
        while !store.refreshingServiceIDs.contains("openrouter") { await Task.yield() }
        while await fixture.requests.calls == 0 { await Task.yield() }
        XCTAssertTrue(store.configureOpenRouter(" synthetic "))
        XCTAssertEqual(savedKey, "synthetic")
        await fixture.requests.configure(delay: 80_000_000, values: ["openrouter": 22])
        await first.value
        XCTAssertNil(fixture.cache["openrouter"])
        for _ in 0..<100 {
            if fixture.cache["openrouter"] != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fixture.cache["openrouter"]?.usage.windows.first?.pct, 22)
        XCTAssertEqual(store.config.services.count, 1)
    }

    @MainActor func testSingleRefreshDeduplicatesAndQueuesGlobalRefresh() async throws {
        let fixture = Fixture()
        let store = UsageStore(config: fixture.config(count: 2), dependencies: fixture.dependencies())
        let id = try XCTUnwrap(store.states.first?.id)
        await fixture.requests.configure(delay: 80_000_000)
        let first = Task { await store.refreshService(id) }
        while !store.refreshingServiceIDs.contains(id) { await Task.yield() }
        await store.refreshService(id)
        XCTAssertFalse(store.canRefreshService(id))
        await first.value
        let calls = await fixture.requests.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.cache.count, 1)
        let second = Task { await store.refreshService(id) }
        while !store.refreshingServiceIDs.contains(id) { await Task.yield() }
        await store.refresh()
        await second.value
        for _ in 0..<100 {
            if await fixture.requests.calls >= 2 + store.states.count, !store.isRefreshing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let total = await fixture.requests.calls
        XCTAssertEqual(total, 2 + store.states.count)
        XCTAssertTrue(store.refreshingServiceIDs.isEmpty)
    }

    func testOldConfigDefaultsToEmptyAccountList() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(config.codexAccounts.isEmpty)
    }

    func testIdentitySeparatesUsersAndSurvivesTokenRotation() {
        XCTAssertNotEqual(credentials(0).identity, credentials(1).identity)
        XCTAssertEqual(credentials(0).identity, credentials(0, token: "rotated").identity)
        XCTAssertFalse(credentials(0).identity.contains("workspace"))
    }

    func testNestedAndFlatCredentialsAndInvalidPayloads() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_user_id": "user"]])
        let token = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        for nested in [true, false] {
            let tokens = ["access_token": token, "account_id": "workspace"]
            let object: [String: Any] = nested ? ["tokens": tokens] : tokens
            let result = CredentialStore.parseCodexCredentials(try JSONSerialization.data(withJSONObject: object))
            guard case .ok(let parsed) = result else { return XCTFail("Valid credentials rejected") }
            XCTAssertEqual(parsed.userId, "user")
        }
        for text in ["{}", "{\"access_token\":\"opaque\",\"account_id\":\"shared\"}", "invalid"] {
            if case .ok = CredentialStore.parseCodexCredentials(Data(text.utf8)) { XCTFail("Ambiguous identity accepted") }
        }
    }

    @MainActor func testImportDirectoryAndFilePreservesCurrentLoginAndDeduplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        let payload = try JSONSerialization.data(withJSONObject: ["sub": "imported-user"])
        let token = "header." + payload.base64EncodedString() + ".signature"
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token, "account_id": "imported-workspace"]])
        try data.write(to: file)
        let imported = CredentialStore.CodexCreds(accessToken: token, accountId: "imported-workspace", userId: "imported-user")
        let fixture = Fixture()
        fixture.current = credentials(0)
        let store = UsageStore(config: fixture.config(count: 1), dependencies: fixture.dependencies())
        await fixture.requests.configure(values: [imported.identity: 99])
        store.importAccount(from: directory)
        await store.refresh()
        XCTAssertEqual(store.config.codexAccounts.count, 2)
        XCTAssertEqual(store.currentAccountID, credentials(0).identity)
        XCTAssertEqual(store.states.first?.id, credentials(0).identity)
        XCTAssertEqual(store.activeAlertCount, 0)
        XCTAssertTrue(fixture.notifications.isEmpty)
        XCTAssertEqual(fixture.current, credentials(0))
        XCTAssertEqual(fixture.saved[imported.identity], imported)
        XCTAssertNotNil(store.accountNotice)
        XCTAssertNil(store.accountError)
        store.importAccount(from: file)
        XCTAssertEqual(store.config.codexAccounts.count, 2)
        XCTAssertEqual(store.config.codexAccounts.last?.name, imported.displayName)
        XCTAssertEqual(try Data(contentsOf: file), data)

        fixture.failSave = true
        let rotatedData = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": token + "-rotated", "account_id": "imported-workspace"]])
        try rotatedData.write(to: file)
        store.importAccount(from: file)
        XCTAssertEqual(fixture.saved[imported.identity], imported)
        XCTAssertNotNil(store.accountError)
        XCTAssertNil(store.accountNotice)
        XCTAssertEqual(try Data(contentsOf: file), rotatedData)
    }

    @MainActor func testInvalidImportsDoNotPersistAccountsOrCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture()
        let store = UsageStore(config: fixture.config(count: 0), dependencies: fixture.dependencies())
        store.importAccount(from: directory)
        XCTAssertNotNil(store.accountError)
        for contents in ["not json", "{}", "{\"OPENAI_API_KEY\":\"synthetic\"}"] {
            try Data(contents.utf8).write(to: directory.appendingPathComponent("auth.json"))
            store.importAccount(from: directory)
            XCTAssertNotNil(store.accountError)
            XCTAssertNil(store.accountNotice)
            XCTAssertTrue(store.config.codexAccounts.isEmpty)
            XCTAssertTrue(fixture.saved.isEmpty)
            XCTAssertNil(fixture.persisted)
        }
    }

    @MainActor func testZeroOneThreeAndTenAccountsAndCurrentFirst() async {
        for count in [0, 1, 3, 10] {
            let fixture = Fixture()
            let config = fixture.config(count: count)
            if count > 0 { fixture.current = credentials(count - 1) }
            let store = UsageStore(config: config, dependencies: fixture.dependencies())
            await store.refresh()
            XCTAssertEqual(store.states.count, max(1, count))
            XCTAssertEqual(Set(store.states.map(\.id)).count, store.states.count)
            if count > 0 {
                XCTAssertEqual(store.states.first?.id, fixture.current?.identity)
                XCTAssertEqual(store.states.filter(\.isCurrentAccount).count, 1)
            }
        }
    }

    @MainActor func testAddDeduplicatesUpdatesAndPersistsMetadataOnly() async throws {
        let fixture = Fixture()
        fixture.current = credentials(0)
        let store = UsageStore(config: fixture.config(count: 0), dependencies: fixture.dependencies())
        store.addCurrentAccount()
        fixture.current = credentials(0, token: "SECRET-ROTATED")
        store.addCurrentAccount()
        XCTAssertEqual(store.config.codexAccounts.count, 1)
        XCTAssertEqual(store.config.codexAccounts.first?.name, credentials(0).displayName)
        XCTAssertEqual(fixture.saved[credentials(0).identity]?.accessToken, "SECRET-ROTATED")
        let encoded = String(decoding: try JSONEncoder().encode(store.config), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SECRET-ROTATED"))
        XCTAssertFalse(encoded.contains("workspace"))
        await store.refresh()
    }

    @MainActor func testCurrentAndClaudeAlertsOnlyAndCooldownIsPerAccount() async {
        let fixture = Fixture()
        fixture.current = credentials(0)
        let config = fixture.config(count: 3, claude: true)
        await fixture.requests.configure(values: [credentials(0).identity: 10, credentials(1).identity: 95,
                                                 credentials(2).identity: 95, "claude": 95])
        let store = UsageStore(config: config, dependencies: fixture.dependencies())
        await store.refresh()
        XCTAssertEqual(store.activeAlertCount, 1)
        XCTAssertEqual(fixture.notifications.count, 1)
        fixture.current = credentials(1)
        store.synchronizeCurrentAccount()
        XCTAssertEqual(store.activeAlertCount, 2)
        await store.refresh()
        XCTAssertEqual(fixture.notifications.count, 2)
        fixture.current = credentials(2)
        await store.refresh()
        XCTAssertEqual(fixture.notifications.count, 3)
        fixture.current = credentials(0)
        store.synchronizeCurrentAccount()
        XCTAssertEqual(store.activeAlertCount, 1)
    }

    @MainActor func testFailureUsesOnlyOwnCacheAndIgnoresLegacyCache() async {
        let fixture = Fixture()
        fixture.current = credentials(1)
        fixture.cache["codex"] = .init(usage: usage(99), ts: Date())
        fixture.cache[credentials(0).identity] = .init(usage: usage(25), ts: Date())
        await fixture.requests.configure(failures: [credentials(0).identity, credentials(1).identity])
        let store = UsageStore(config: fixture.config(count: 2), dependencies: fixture.dependencies())
        await store.refresh()
        guard case .error = store.states.first?.status else { return XCTFail("Used another account's cache") }
        guard case .stale(let cached, _, let error) = store.states.last?.status else { return XCTFail("Lost own cache") }
        XCTAssertEqual(cached.windows.first?.pct, 25)
        XCTAssertTrue(error.contains("重新登录"))
    }

    @MainActor func testConcurrencyBoundAndAllAccountsRefreshed() async {
        let fixture = Fixture()
        let config = fixture.config(count: 10)
        await fixture.requests.configure(delay: 20_000_000)
        let store = UsageStore(config: config, dependencies: fixture.dependencies())
        await store.refresh()
        let maximum = await fixture.requests.maximum
        let calls = await fixture.requests.calls
        XCTAssertEqual(maximum, 4)
        XCTAssertEqual(calls, 10)
        XCTAssertEqual(fixture.cache.count, 10)
    }

    @MainActor func testRemovalDuringRefreshCannotRestoreAccountOrWriteCache() async {
        let fixture = Fixture()
        let config = fixture.config(count: 3)
        await fixture.requests.configure(delay: 80_000_000)
        let store = UsageStore(config: config, dependencies: fixture.dependencies())
        let task = Task { await store.refresh() }
        while await fixture.requests.calls == 0 { await Task.yield() }
        let id = credentials(1).identity
        store.removeAccount(id)
        await task.value
        XCTAssertFalse(store.states.contains { $0.id == id })
        XCTAssertNil(fixture.saved[id])
        XCTAssertNil(fixture.cache[id])
    }

    @MainActor func testSwitchDuringRefreshDoesNotLeakOldAlertOrData() async {
        let fixture = Fixture()
        fixture.current = credentials(0)
        await fixture.requests.configure(delay: 40_000_000, values: [credentials(0).identity: 95, credentials(1).identity: 5])
        let store = UsageStore(config: fixture.config(count: 0), dependencies: fixture.dependencies())
        let task = Task { await store.refresh() }
        while await fixture.requests.calls == 0 { await Task.yield() }
        fixture.current = credentials(1)
        await task.value
        XCTAssertEqual(store.states.first?.id, credentials(1).identity)
        XCTAssertEqual(store.activeAlertCount, 0)
        XCTAssertTrue(fixture.notifications.isEmpty)
        XCTAssertNil(fixture.cache[credentials(0).identity])
        XCTAssertEqual(fixture.cache[credentials(1).identity]?.usage.windows.first?.pct, 5)
    }

    @MainActor func testReloginRejectsDifferentIdentityWithoutPersisting() {
        let fixture = Fixture()
        fixture.current = credentials(0)
        let store = UsageStore(config: fixture.config(count: 1), dependencies: fixture.dependencies())
        XCTAssertFalse(store.saveAccount(credentials(1), expectedID: credentials(0).identity))
        XCTAssertNil(fixture.persisted)
        XCTAssertNil(fixture.saved[credentials(1).identity])
        XCTAssertEqual(store.currentAccountID, credentials(0).identity)
        XCTAssertNotNil(store.accountError)
    }

    @MainActor func testFailedConfigSavePreservesPublishedConfiguration() {
        let fixture = Fixture()
        let store = UsageStore(config: fixture.config(count: 1), dependencies: fixture.dependencies())
        fixture.failSave = true
        XCTAssertFalse(store.saveAccount(credentials(0)))
        XCTAssertEqual(store.config.codexAccounts.first?.name, "Account 0")
        XCTAssertNotNil(store.configSaveError)
    }

    @MainActor func testFailedSaveDoesNotEraseOrRetainUnregisteredCredentials() {
        let fixture = Fixture()
        let store = UsageStore(config: fixture.config(count: 1), dependencies: fixture.dependencies())
        fixture.failSave = true
        store.removeAccount(credentials(0).identity)
        XCTAssertNotNil(fixture.saved[credentials(0).identity])
        XCTAssertEqual(store.config.codexAccounts.count, 1)
        fixture.current = credentials(1)
        store.addCurrentAccount()
        XCTAssertNil(fixture.saved[credentials(1).identity])
        XCTAssertEqual(store.config.codexAccounts.count, 1)
    }

    @MainActor func testLogoutClearsCodexAlertAndRemovingCurrentKeepsTransientCard() async {
        let fixture = Fixture()
        fixture.current = credentials(0)
        await fixture.requests.configure(values: [credentials(0).identity: 95])
        let store = UsageStore(config: fixture.config(count: 1), dependencies: fixture.dependencies())
        await store.refresh()
        XCTAssertEqual(store.activeAlertCount, 1)
        store.removeAccount(credentials(0).identity)
        XCTAssertTrue(store.config.codexAccounts.isEmpty)
        XCTAssertTrue(store.states.first?.isCurrentAccount == true)
        XCTAssertTrue(store.states.first?.config.title.contains("未保存") == true)
        fixture.current = nil
        store.synchronizeCurrentAccount()
        XCTAssertEqual(store.activeAlertCount, 0)
        XCTAssertNil(store.currentAccountID)
    }

    @MainActor func testSmallScreenViewsRenderWithinHeight() async throws {
        _ = NSApplication.shared
        let fixture = Fixture()
        fixture.current = credentials(2)
        let store = UsageStore(config: fixture.config(count: 10), dependencies: fixture.dependencies())
        await store.refresh()
        for settings in [false, true] {
            let view = PopoverRootView(availableHeight: 480, showsRelayPanel: false, initiallyShowingSettings: settings)
                .environmentObject(store)
                .background(Color(white: 0.12))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 360)
            XCTAssertEqual(host.fittingSize.height, 480)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/multi-account-validation")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(settings ? "settings-preview.png" : "dashboard-preview.png"))
        }
    }

    @MainActor func testRelayKeepsUniqueIDsWithoutCredentials() throws {
        let fixture = Fixture()
        fixture.current = credentials(1)
        let store = UsageStore(config: fixture.config(count: 3), dependencies: fixture.dependencies())
        let data = relayPayloadJSON(states: store.states, lastUpdated: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let services = try XCTUnwrap(json["services"] as? [[String: Any]])
        XCTAssertEqual(services.count, 3)
        XCTAssertEqual(services.first?["isCurrentAccount"] as? Bool, true)
        XCTAssertEqual(services.filter { $0["isCurrentAccount"] as? Bool == true }.count, 1)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("accessToken"))
        XCTAssertFalse(text.contains("workspace"))
        XCTAssertFalse(text.contains("credentialFile"))
    }
}
