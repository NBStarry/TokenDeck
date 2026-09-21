import XCTest
@testable import TokenDeck

final class KeychainIntegrationTests: XCTestCase {
    func testSyntheticAccountsPersistRotateAndRemoveIndependently() throws {
        guard ProcessInfo.processInfo.environment["TOKENDECK_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("Opt in to disposable synthetic entries in the local keychain")
        }
        let namespace = "tokendeck-test-" + UUID().uuidString
        let accounts = (0..<3).map {
            CredentialStore.CodexCreds(accessToken: "synthetic-\($0)", accountId: namespace, userId: "user-\($0)")
        }
        defer {
            for account in accounts {
                do { try CredentialStore.removeCodexCredentials(account.identity) }
                catch { XCTFail("Could not clean up test-owned keychain entry: \(error)") }
            }
        }
        for account in accounts {
            XCTAssertNil(CredentialStore.savedCodexCredentials(account.identity))
            try CredentialStore.saveCodexCredentials(account)
        }
        for account in accounts {
            XCTAssertEqual(CredentialStore.savedCodexCredentials(account.identity), account)
        }
        let rotated = CredentialStore.CodexCreds(accessToken: "synthetic-rotated",
                                                accountId: namespace, userId: accounts[1].userId)
        try CredentialStore.saveCodexCredentials(rotated)
        XCTAssertEqual(CredentialStore.savedCodexCredentials(rotated.identity), rotated)
        try CredentialStore.removeCodexCredentials(accounts[0].identity)
        XCTAssertNil(CredentialStore.savedCodexCredentials(accounts[0].identity))
        XCTAssertEqual(CredentialStore.savedCodexCredentials(accounts[2].identity), accounts[2])
        for account in accounts { try CredentialStore.removeCodexCredentials(account.identity) }
        for account in accounts { XCTAssertNil(CredentialStore.savedCodexCredentials(account.identity)) }
    }
}
