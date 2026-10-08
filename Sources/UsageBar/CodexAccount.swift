import Foundation

struct CodexAccount: Codable, Identifiable, Equatable {
    let id: String
    var name: String
}

// Inject storage and IO so account transitions can be tested without touching real logins.
@MainActor
struct UsageDependencies {
    var currentCredentials: () -> CredentialStore.CodexCredResult = CredentialStore.codexCreds
    var importCredentials: (URL) -> CredentialStore.CodexCredResult = CredentialStore.codexCreds(at:)
    var savedCredentials: (String) -> CredentialStore.CodexCreds? = CredentialStore.savedCodexCredentials
    var saveCredentials: (CredentialStore.CodexCreds) throws -> Void = CredentialStore.saveCodexCredentials
    var switchCredentials: (CredentialStore.CodexCreds) throws -> Void = { target in
        try CodexAccountSwitcher().switchAccount(to: target, savePrevious: CredentialStore.saveCodexCredentials)
    }
    var removeCredentials: (String) throws -> Void = CredentialStore.removeCodexCredentials
    var saveAPIKey: (String, String) throws -> Void = CredentialStore.saveAPIKey
    var saveConfig: (AppConfig) throws -> Void = AppConfigStore.save
    var readCache: (String) -> UsageCache.Cached? = UsageCache.read
    var writeCache: (Usage, String) -> Void = { UsageCache.write($0, service: $1) }
    var requestNotificationAuthorization: () -> Void = AlertNotifier.requestAuthorizationIfNeeded
    var notify: (String, String) -> Void = { AlertNotifier.send(title: $0, body: $1) }
    var fetch: @Sendable (ServiceConfig, CredentialStore.CodexCreds?) async -> FetchOutcome = { config, creds in
        if config.fetcher == .codexWham {
            guard let creds else { return .failure("未能读取登录凭证，请在设置中授权钥匙串访问并查看验证结果") }
            return await CodexFetcher(credentials: creds).fetch()
        }
        guard let fetcher = makeFetcher(for: config) else { return .failure("未支持的取数类型") }
        return await fetcher.fetch()
    }
}
