import XCTest
@testable import TokenDeck

final class LoginTests: XCTestCase {
    func testOfficialNameAndLegacyCredentials() throws {
        let profile = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/profile": ["name": "Profile Name", "email": "test@example.invalid"]])
        let token = "h." + profile.base64EncodedString() + ".s"
        let legacy = try JSONSerialization.data(withJSONObject: ["accessToken": token, "accountId": "workspace", "userId": "user"])
        let creds = try JSONDecoder().decode(CredentialStore.CodexCreds.self, from: legacy)
        XCTAssertEqual(creds.displayName, "Profile Name")
        var named = creds
        named.name = "Official Name"
        XCTAssertEqual(named.displayName, "Official Name")
        XCTAssertEqual(named.identity, creds.identity)
    }

    @MainActor func testLoginProcessSuccessAndCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex")
        let payload = Data("{\"sub\":\"user\"}".utf8).base64EncodedString()
        let marker = directory.appendingPathComponent("home")
        let text = """
        #!/bin/sh
        printf '%s' "$CODEX_HOME" > '\(marker.path)'
        printf '%s' '{"tokens":{"account_id":"workspace","access_token":"h.\(payload).s"}}' > "$CODEX_HOME/auth.json"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var dependencies = UsageDependencies()
        dependencies.currentCredentials = { .missingFile }
        dependencies.savedCredentials = { _ in nil }
        dependencies.saveCredentials = { _ in }
        dependencies.removeCredentials = { _ in }
        dependencies.saveConfig = { _ in }
        dependencies.readCache = { _ in nil }
        dependencies.writeCache = { _, _ in }
        dependencies.fetch = { _, _ in .failure("test") }
        var config = AppConfig.default
        config.services = []
        let store = UsageStore(config: config, dependencies: dependencies)
        let login = CodexLoginController(executable: script, store: store)
        login.start(timeout: 3)
        for _ in 0..<100 where login.running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(login.running)
        XCTAssertEqual(store.config.codexAccounts.count, 1)
        XCTAssertTrue(login.message.contains("已添加"))
        let home = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertNotEqual(home, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home))
    }

    @MainActor func testLoginCancellationTimeoutAndMissingExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        for cancel in [false, true] {
            let login = CodexLoginController(executable: script)
            login.start(timeout: 0.15)
            if cancel { login.cancel() }
            for _ in 0..<100 where login.running { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertFalse(login.running)
            XCTAssertTrue(login.message.contains(cancel ? "取消" : "超时"))
        }
        let missing = CodexLoginController(executable: directory.appendingPathComponent("missing"))
        missing.start()
        for _ in 0..<50 where missing.running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(missing.message.contains("无法启动"))
    }
}
