import Foundation
import Darwin

struct CodexAccountSwitcher {
    enum SwitchError: LocalizedError {
        case incomplete, unsupported, changed, invalid, writeFailed
        var errorDescription: String? {
            switch self {
            case .incomplete: return "账号缺少完整登录信息，请重新登录后切换"
            case .unsupported: return "无法确认默认文件认证设置；不支持钥匙串、受管理配置或其他认证方式的切换"
            case .changed: return "Codex 登录或配置已被其他程序更新，请重试切换"
            case .invalid: return "登录文件无法验证，未切换账号"
            case .writeFailed: return "切换写入失败，请检查目录权限后重试"
            }
        }
    }

    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) {
        self.home = home
    }

    // Fail closed for configuration forms we cannot establish without a TOML evaluator.
    static func supportsFileAuthentication(_ data: Data?) -> Bool {
        guard let data else { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let sensitive = ["cli_auth_credentials_store", "forced_login_method", "forced_chatgpt_workspace_id", "chatgpt_base_url"]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            for key in sensitive where line.contains(key) {
                let parts = line.components(separatedBy: "=")
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { return false }
                let value = parts[1].components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
                guard (key == "cli_auth_credentials_store" && ["\"file\"", "'file'"].contains(value))
                    || (key == "forced_login_method" && ["\"chatgpt\"", "'chatgpt'"].contains(value)) else { return false }
            }
        }
        return true
    }

    func switchAccount(to target: CredentialStore.CodexCreds,
                       savePrevious: (CredentialStore.CodexCreds) throws -> Void,
                       beforeCommit: () throws -> Void = {}) throws {
        guard target.canLoginToCLI else { throw SwitchError.incomplete }
        let fm = FileManager.default
        for url in [home.appendingPathComponent("managed_config.toml"), home.appendingPathComponent("requirements.toml"),
                    URL(fileURLWithPath: "/etc/codex/managed_config.toml"), URL(fileURLWithPath: "/etc/codex/requirements.toml")] {
            if fm.fileExists(atPath: url.path) { throw SwitchError.unsupported }
        }
        let configURL = home.appendingPathComponent("config.toml")
        func readOptional(_ url: URL) throws -> Data? {
            if !fm.fileExists(atPath: url.path) { return nil }
            return try Data(contentsOf: url)
        }
        let config = try readOptional(configURL)
        guard Self.supportsFileAuthentication(config) else { throw SwitchError.unsupported }
        let auth = home.appendingPathComponent("auth.json")
        guard (try? auth.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SwitchError.unsupported }
        let original = try readOptional(auth)
        if let original {
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  (object["OPENAI_API_KEY"] is NSNull || object["OPENAI_API_KEY"] == nil),
                  (object["auth_mode"] == nil || object["auth_mode"] as? String == "chatgpt"),
                  case .ok(let previous) = CredentialStore.parseCodexCredentials(original), previous.canLoginToCLI else {
                throw SwitchError.unsupported
            }
            try savePrevious(previous)
        }
        let data = try target.cliAuthData()
        guard case .ok(let decoded) = CredentialStore.parseCodexCredentials(data), decoded.identity == target.identity else { throw SwitchError.invalid }
        let staged = home.appendingPathComponent(".tokendeck-auth-" + UUID().uuidString)
        guard fm.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw SwitchError.writeFailed }
        defer { try? fm.removeItem(at: staged) }
        try beforeCommit()
        guard try readOptional(auth) == original, try readOptional(configURL) == config else { throw SwitchError.changed }
        guard rename(staged.path, auth.path) == 0 else { throw SwitchError.writeFailed }
        let actual = try readOptional(auth)
        // Never roll back a newer external write. Atomic rename publishes the complete validated file.
        guard actual == data, let actual,
              case .ok(let checked) = CredentialStore.parseCodexCredentials(actual), checked.identity == target.identity else {
            throw SwitchError.changed
        }
    }
}
