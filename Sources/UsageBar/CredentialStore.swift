import Foundation
import CryptoKit
import Security

// 只负责读凭证,不打印 token。
enum CredentialStore {

    // ─── Claude ───────────────────────────────────────────────
    // 1) 钥匙串 "Claude Code-credentials" → claudeAiOauth.accessToken
    // 2) 回退 ~/.claude/.credentials.json
    static func claudeToken() -> String? {
        if let raw = runSecurity(service: "Claude Code-credentials"),
           let tok = parseClaudeOAuth(raw) {
            return tok
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: path),
           let str = String(data: data, encoding: .utf8),
           let tok = parseClaudeOAuth(str) {
            return tok
        }
        return nil
    }

    private static func parseClaudeOAuth(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
        return tok
    }

    private static func runSecurity(service: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        } catch {
            return nil
        }
    }

    // ─── Codex / GPT ──────────────────────────────────────────
    struct CodexCreds: Codable, Sendable, Equatable {
        let accessToken: String
        let accountId: String
        var userId: String = ""
        var name: String? = nil
        var email: String? = nil
        var idToken: String? = nil
        var refreshToken: String? = nil
        var lastRefresh: String? = nil

        var canLoginToCLI: Bool {
            guard let idToken, !idToken.isEmpty, let refreshToken, !refreshToken.isEmpty else { return false }
            return !accessToken.isEmpty && !accountId.isEmpty && !userId.isEmpty
        }

        func cliAuthData() throws -> Data {
            guard canLoginToCLI else { throw CodexAccountSwitcher.SwitchError.incomplete }
            var object: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
                "tokens": ["access_token": accessToken, "account_id": accountId,
                           "id_token": idToken!, "refresh_token": refreshToken!]]
            if let lastRefresh { object["last_refresh"] = lastRefresh }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        var displayName: String {
            let profile = CredentialStore.jwtClaims(accessToken)["https://api.openai.com/profile"] as? [String: Any]
            for value in [name, profile?["name"] as? String, email, profile?["email"] as? String] {
                if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            }
            return "Codex 账号 " + identity.suffix(6)
        }

        var identity: String {
            let data = try! JSONEncoder().encode([accountId, userId])
            return "codex-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum CodexCredResult: Sendable {
        case ok(CodexCreds)
        case missingFile          // 未找到 auth.json
        case parseError           // 解析失败
        case incomplete           // 字段不全
    }

    static func codexCreds() -> CodexCredResult {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        return codexCreds(at: path)
    }

    static func codexCreds(at selectedURL: URL) -> CodexCredResult {
        guard selectedURL.isFileURL else { return .parseError }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory) else {
            return .missingFile
        }
        let path = isDirectory.boolValue ? selectedURL.appendingPathComponent("auth.json") : selectedURL
        guard FileManager.default.fileExists(atPath: path.path) else { return .missingFile }
        guard let data = try? Data(contentsOf: path) else { return .parseError }
        return parseCodexCredentials(data)
    }

    static func parseCodexCredentials(_ data: Data) -> CodexCredResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .parseError }
        let tokens = obj["tokens"] as? [String: Any]
        let access = (tokens?["access_token"] as? String) ?? (obj["access_token"] as? String)
        let account = (tokens?["account_id"] as? String) ?? (obj["account_id"] as? String)
        guard let a = access, let acc = account, !a.isEmpty, !acc.isEmpty else { return .incomplete }
        let claims = jwtClaims(a)
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let idClaims = jwtClaims((tokens?["id_token"] as? String) ?? (obj["id_token"] as? String) ?? "")
        let user = (auth?["chatgpt_user_id"] as? String)
            ?? (idClaims["sub"] as? String) ?? (claims["sub"] as? String) ?? ""
        // Without a user identity, a shared workspace ID could merge different people.
        guard !user.isEmpty else { return .incomplete }
        return .ok(CodexCreds(accessToken: a, accountId: acc, userId: user, name: idClaims["name"] as? String, email: idClaims["email"] as? String,
            idToken: (tokens?["id_token"] as? String) ?? (obj["id_token"] as? String),
            refreshToken: (tokens?["refresh_token"] as? String) ?? (obj["refresh_token"] as? String),
            lastRefresh: obj["last_refresh"] as? String))
    }

    private static func jwtClaims(_ token: String) -> [String: Any] {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return [:] }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return claims
    }

    private static func codexKeychainQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.tokenusagedashboard.codex",
         kSecAttrAccount as String: id]
    }

    static func savedCodexCredentials(_ id: String) -> CodexCreds? {
        var query = codexKeychainQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(CodexCreds.self, from: data),
              creds.identity == id else { return nil }
        return creds
    }

    static func saveCodexCredentials(_ creds: CodexCreds) throws {
        let query = codexKeychainQuery(creds.identity)
        let data = try JSONEncoder().encode(creds)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try checkKeychain(SecItemAdd(item as CFDictionary, nil))
        } else {
            try checkKeychain(status)
        }
    }

    static func removeCodexCredentials(_ id: String) throws {
        let status = SecItemDelete(codexKeychainQuery(id) as CFDictionary)
        if status != errSecItemNotFound { try checkKeychain(status) }
    }

    private static func checkKeychain(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "钥匙串操作失败（\(status)）"])
        }
    }

    private static func apiKeyQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.tokenusagedashboard.api",
         kSecAttrAccount as String: id]
    }

    static func apiKey(_ id: String) throws -> String? {
        var query = apiKeyQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try checkKeychain(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw NSError(domain: "APIKey", code: 1)
        }
        return key
    }

    static func saveAPIKey(_ key: String, id: String) throws {
        let query = apiKeyQuery(id)
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try checkKeychain(SecItemAdd(item as CFDictionary, nil))
        } else { try checkKeychain(status) }
    }

    // ─── New-API 兼容网关 ─────────────────────────────────────
    // 凭证文件默认放在 ~/.config/usage-bar/<service-id>.json:
    // {"baseUrl","accessToken","userId","quotaPerUnit","currency"}
    struct NewAPICreds {
        let baseURL: String
        let accessToken: String
        let userId: Int
        let quotaPerUnit: Double
        let currency: String
    }

    enum NewAPICredResult {
        case ok(NewAPICreds)
        case missingFile(String)
        case invalidPath
        case incomplete
    }

    static func newAPICreds(fileName: String) -> NewAPICredResult {
        guard let path = newAPICredURL(fileName: fileName) else { return .invalidPath }
        guard FileManager.default.fileExists(atPath: path.path) else { return .missingFile(path.path) }
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .incomplete }

        guard let base = (obj["baseUrl"] as? String)?.trimmingCharacters(in: .whitespaces), !base.isEmpty,
              let token = (obj["accessToken"] as? String), !token.isEmpty
        else { return .incomplete }
        let userId = (obj["userId"] as? Int) ?? Int(obj["userId"] as? String ?? "") ?? 0
        let qpu = (obj["quotaPerUnit"] as? Double)
            ?? (obj["quotaPerUnit"] as? Int).map(Double.init)
            ?? 500000
        let currency = (obj["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "$"
        return .ok(NewAPICreds(baseURL: base, accessToken: token, userId: userId,
                               quotaPerUnit: qpu, currency: currency))
    }

    private static func newAPICredURL(fileName: String) -> URL? {
        let clean = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("/"), !clean.contains("..") else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar", isDirectory: true)
            .appendingPathComponent(clean)
    }
}
