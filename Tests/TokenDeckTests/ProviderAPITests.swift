import XCTest
import SwiftUI
@testable import TokenDeck

final class ProviderAPITests: XCTestCase {
    func testOpenRouterKeyAndAccountScopes() async throws {
        let ordinary = ProviderAPIFetcher(serviceID: "openrouter", kind: .openRouter,
            readKey: { _ in "synthetic" }, request: { url, _ in
                XCTAssertEqual(url, "https://openrouter.ai/api/v1/key")
                return (["data": ["usage": 2.5, "limit": 10, "limit_remaining": 7.5,
                                   "is_management_key": false, "limit_reset": "monthly"]], 200)
            })
        let keyOutcome = await ordinary.fetch()
        let key = try XCTUnwrap(try info(keyOutcome).openRouter)
        XCTAssertEqual(key.scope, .key)
        XCTAssertEqual(key.remaining, 7.5)
        XCTAssertEqual(key.reset, "monthly")
        let management = ProviderAPIFetcher(serviceID: "openrouter", kind: .openRouter,
            readKey: { _ in "synthetic" }, request: { url, _ in
                if url.hasSuffix("/key") { return (["data": ["is_management_key": true]], 200) }
                XCTAssertEqual(url, "https://openrouter.ai/api/v1/credits")
                return (["data": ["total_credits": 20, "total_usage": 4.25]], 200)
            })
        let accountOutcome = await management.fetch()
        let account = try XCTUnwrap(try info(accountOutcome).openRouter)
        XCTAssertEqual(account.scope, .account)
        XCTAssertEqual(account.remaining, 15.75)
        XCTAssertEqual(account.used, 4.25)
        let unlimited = try info(ordinary.parse(["data": ["usage": 0, "limit": NSNull(), "limit_remaining": NSNull()]])).openRouter
        XCTAssertNil(unlimited?.remaining)
        XCTAssertNil(unlimited?.limit)
        for bad: Any in [true, "NaN", -1] {
            guard case .failure = ordinary.parse(["data": ["usage": bad]]) else { return XCTFail("Invalid usage accepted") }
        }
        let old = try JSONDecoder().decode(APIInfo.self, from: Data("{}".utf8))
        XCTAssertNil(old.openRouter)
    }

    private let balance: [String: Any] = ["is_available": false, "balance_infos": [
        ["currency": "CNY", "total_balance": "0.00", "topped_up_balance": "0", "granted_balance": "0"],
        ["currency": "USD", "total_balance": "12.34", "topped_up_balance": "10.00", "granted_balance": "2.34"]]]

    private func info(_ outcome: FetchOutcome) throws -> APIInfo {
        guard case .success(let usage) = outcome else { throw NSError(domain: "test", code: 1) }
        return try XCTUnwrap(usage.apiInfo)
    }

    func testBalanceZeroMultipleCurrenciesAndInvalidValues() throws {
        let fetcher = ProviderAPIFetcher(serviceID: "deepseek", kind: .deepseek)
        let parsed = try info(fetcher.parse(balance))
        XCTAssertEqual(parsed.balances?.map(\.currency), ["CNY", "USD"])
        XCTAssertEqual(parsed.balances?[0].total, 0)
        XCTAssertEqual(parsed.balances?[1].granted, 2.34)
        XCTAssertEqual(parsed.isAvailable, false)
        for invalid in ["NaN", "inf", "oops"] {
            let row = ["currency": "CNY", "total_balance": invalid, "topped_up_balance": "0", "granted_balance": "0"]
            guard case .failure = fetcher.parse(["is_available": true, "balance_infos": [row]]) else {
                return XCTFail("Invalid number accepted")
            }
        }
        guard case .failure = fetcher.parse(["error": "private response"]) else { return XCTFail() }
    }

    func testYicloudEmptyModelsAndDeduplication() throws {
        let fetcher = ProviderAPIFetcher(serviceID: "yicloud", kind: .yicloud)
        XCTAssertEqual(try info(fetcher.parse(["data": [[String: Any]]()])).models, [])
        let parsed = try info(fetcher.parse(["data": [["id": "Kimi-K3"], ["id": "Kimi-K3"], ["id": "GLM"]]]))
        XCTAssertEqual(parsed.models, ["GLM", "Kimi-K3"])
        XCTAssertNil(parsed.balances)
        XCTAssertNil(parsed.isAvailable)
        guard case .failure = fetcher.parse(["data": [["oops": "bad"]]]) else { return XCTFail() }
    }

    func testFetchAuthenticationNetworkAndKeyErrorsAreSanitized() async throws {
        for code in [401, 403, 429, 500] {
            let fetcher = ProviderAPIFetcher(serviceID: "yicloud", kind: .yicloud,
                readKey: { _ in "synthetic-secret" }, request: { url, headers in
                    XCTAssertEqual(url, "https://token-api.yicloud.com/v1/models")
                    XCTAssertEqual(headers["Authorization"], "Bearer synthetic-secret")
                    return (["message": "synthetic-secret"], code)
                })
            guard case .failure(let message) = await fetcher.fetch() else { return XCTFail() }
            XCTAssertFalse(message.contains("synthetic-secret"))
        }
        let network = ProviderAPIFetcher(serviceID: "deepseek", kind: .deepseek,
            readKey: { _ in "key" }, request: { _, _ in throw Http.HttpError.network("synthetic-secret") })
        guard case .failure(let message) = await network.fetch() else { return XCTFail() }
        XCTAssertFalse(message.contains("synthetic-secret"))
        let missing = ProviderAPIFetcher(serviceID: "deepseek", kind: .deepseek, readKey: { _ in nil },
            request: { _, _ in XCTFail("Requested without key"); return ([:], 500) })
        guard case .failure = await missing.fetch() else { return XCTFail() }
    }

    func testImportAppendsOncePreservesOptionsAndRejectsCollision() throws {
        var config = AppConfig.default
        let original = config.services.map(\.id)
        var saved: [String: String] = [:]
        try ProviderAPIImport.apply(["deepseek": "one", "yicloud": "two"], config: &config) { saved[$1] = $0 }
        XCTAssertEqual(config.services.map(\.id), original + ["deepseek", "yicloud"])
        config.services[config.services.count - 1].enabled = false
        try ProviderAPIImport.apply(["yicloud": "rotated"], config: &config) { saved[$1] = $0 }
        XCTAssertEqual(config.services.count, original.count + 2)
        XCTAssertFalse(config.services.last!.enabled)
        XCTAssertEqual(saved["yicloud"], "rotated")
        XCTAssertEqual(DisplayContent.options(for: config.services.last!), [.models, .updatedAt])
        config.services[config.services.count - 1].fetcher = .newAPI
        XCTAssertThrowsError(try ProviderAPIImport.apply(["yicloud": "key"], config: &config) { _, _ in XCTFail() })
        XCTAssertThrowsError(try ProviderAPIImport.apply(["deepseek": " "], config: &config) { _, _ in XCTFail() })
        var fresh = AppConfig.default
        XCTAssertThrowsError(try ProviderAPIImport.apply(["deepseek": "key"], config: &fresh) { _, _ in throw NSError(domain: "test", code: 1) })
        XCTAssertEqual(fresh.services.map(\.id), original)
    }

    @MainActor func testCacheRelayAndCardRendering() throws {
        _ = NSApplication.shared
        for (name, parsed) in [
            ("deepseek", try info(ProviderAPIFetcher(serviceID: "deepseek", kind: .deepseek).parse(balance))),
            ("yicloud", APIInfo(balances: nil, isAvailable: nil, models: ["Kimi-K3"])),
            ("openrouter", APIInfo(balances: nil, isAvailable: nil, models: nil,
                openRouter: OpenRouterInfo(scope: .key, used: 2.5, remaining: 7.5, limit: 10, reset: "monthly")))] {
            let service = "api-test-" + UUID().uuidString
            let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/usage-dashboard/\(service).json")
            defer { try? FileManager.default.removeItem(at: path) }
            UsageCache.write(Usage(apiInfo: parsed), service: service)
            let cached = try XCTUnwrap(UsageCache.read(service)?.usage.apiInfo)
            XCTAssertEqual(cached.models, parsed.models)
            XCTAssertEqual(cached.balances?.first?.total, parsed.balances?.first?.total)
            XCTAssertEqual(cached.openRouter?.remaining, parsed.openRouter?.remaining)
            let config = ServiceConfig(id: name, title: name, accent: "#4D6BFE", category: .apiUsage,
                                       fetcher: name == "deepseek" ? .deepseek : (name == "openrouter" ? .openRouter : .yicloud))
            let runtime = ServiceRuntime(config: config, status: .ok(Usage(apiInfo: parsed), fetchedAt: Date()))
            let relay = String(decoding: relayPayloadJSON(states: [runtime], lastUpdated: nil), as: UTF8.self)
            XCTAssertTrue(relay.contains("apiInfo"))
            XCTAssertFalse(relay.contains("apiKey"))
            let host = NSHostingView(rootView: ServiceCardView(runtime: runtime, onRefresh: {}).frame(width: 360).padding(12).background(Color(white: 0.12)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/multi-account-validation/\(name)-preview.png"))
        }
    }
}
