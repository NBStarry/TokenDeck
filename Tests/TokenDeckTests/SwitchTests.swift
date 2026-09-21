import XCTest
@testable import TokenDeck

final class SwitchTests: XCTestCase {
    private func creds(_ user: String, refresh: String = "refresh") -> CredentialStore.CodexCreds {
        let payload = Data("{\"sub\":\"\(user)\"}".utf8).base64EncodedString()
        return .init(accessToken: "h.\(payload).s", accountId: "workspace", userId: user,
                     idToken: "h.\(payload).s", refreshToken: refresh, lastRefresh: "2026-09-21T00:00:00Z")
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func testRoundTripSavesLatestRefreshAndRestrictsPermissions() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("auth.json")
        let a = creds("a", refresh: "latest"), b = creds("b")
        try a.cliAuthData().write(to: file)
        var saved: [String: CredentialStore.CodexCreds] = [:]
        let switcher = CodexAccountSwitcher(home: home)
        try switcher.switchAccount(to: b, savePrevious: { saved[$0.identity] = $0 })
        XCTAssertEqual(saved[a.identity]?.refreshToken, "latest")
        guard case .ok(let current) = CredentialStore.codexCreds(at: home) else { return XCTFail() }
        XCTAssertEqual(current.identity, b.identity)
        try switcher.switchAccount(to: XCTUnwrap(saved[a.identity]), savePrevious: { saved[$0.identity] = $0 })
        guard case .ok(let restored) = CredentialStore.codexCreds(at: home) else { return XCTFail() }
        XCTAssertEqual(restored.refreshToken, "latest")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["auth.json"])
    }
    func testExternalUpdateAndSaveFailureNeverOverwriteCurrentLogin() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("auth.json")
        let original = try creds("a").cliAuthData(), external = try creds("c").cliAuthData()
        try original.write(to: file)
        let switcher = CodexAccountSwitcher(home: home)
        XCTAssertThrowsError(try switcher.switchAccount(to: creds("b"), savePrevious: { _ in throw CodexAccountSwitcher.SwitchError.writeFailed }))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertThrowsError(try switcher.switchAccount(to: creds("b"), savePrevious: { _ in }, beforeCommit: { try external.write(to: file, options: .atomic) }))
        XCTAssertEqual(try Data(contentsOf: file), external)
    }
    @MainActor func testStoreSwitchUpdatesCurrentOrderAndAlerts() async throws {
        var current = creds("a")
        let target = creds("b")
        var dependencies = UsageDependencies()
        dependencies.currentCredentials = { .ok(current) }
        dependencies.savedCredentials = { $0 == target.identity ? target : current }
        dependencies.switchCredentials = { current = $0 }
        dependencies.readCache = { _ in nil }
        dependencies.writeCache = { _, _ in }
        dependencies.notify = { _, _ in }
        dependencies.fetch = { _, credentials in
            .success(Usage(windows: [UsageWindow(label: "5 小时", pct: credentials?.userId == "a" ? 95 : 5, resetAt: Date().addingTimeInterval(3600))]))
        }
        var config = AppConfig.default
        config.services = config.services.filter { $0.id == "codex" }
        config.codexAccounts = [CodexAccount(id: current.identity, name: "a"), CodexAccount(id: target.identity, name: "b")]
        config.alerts.enabled = true
        config.alerts.fiveHour.rule = .usageExceedsThresholdOnly
        let store = UsageStore(config: config, dependencies: dependencies)
        await store.refresh()
        XCTAssertGreaterThan(store.activeAlertCount, 0)
        XCTAssertTrue(store.switchCLIAccount(target.identity))
        XCTAssertEqual(store.currentAccountID, target.identity)
        XCTAssertEqual(store.states.first?.id, target.identity)
        XCTAssertEqual(store.activeAlertCount, 0)
        XCTAssertNotNil(store.accountNotice)
    }

    func testLegacyAndUnsupportedStorageRejected() throws {
        let legacy = CredentialStore.CodexCreds(accessToken: "old", accountId: "workspace", userId: "a")
        XCTAssertFalse(legacy.canLoginToCLI)
        XCTAssertThrowsError(try legacy.cliAuthData())
        XCTAssertTrue(CodexAccountSwitcher.supportsFileAuthentication(nil))
        XCTAssertTrue(CodexAccountSwitcher.supportsFileAuthentication(Data("cli_auth_credentials_store = \"file\"".utf8)))
        for value in ["keyring", "auto", "ephemeral"] {
            XCTAssertFalse(CodexAccountSwitcher.supportsFileAuthentication(Data("cli_auth_credentials_store = \"\(value)\"".utf8)))
        }
        XCTAssertFalse(CodexAccountSwitcher.supportsFileAuthentication(Data("forced_chatgpt_workspace_id = \"other\"".utf8)))
    }
}
