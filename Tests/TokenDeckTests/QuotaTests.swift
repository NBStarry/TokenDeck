import XCTest
import SwiftUI
@testable import TokenDeck

final class QuotaTests: XCTestCase {
    private func parsed(_ data: [String: Any], detail: [String: Any]? = nil) throws -> Usage {
        guard case .success(let usage) = CodexFetcher().parseUsage(data, resetDetail: detail) else {
            throw NSError(domain: "QuotaTests", code: 1)
        }
        return usage
    }

    private var weekly: [String: Any] {
        ["rate_limit": ["primary_window": ["used_percent": 92, "limit_window_seconds": 604800,
                                           "reset_at": 2_000_000_000]]]
    }

    func testWeeklyPrimaryUsesWeeklyDisplayAndAlertKind() throws {
        let usage = try parsed(weekly)
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].label, "周")
        XCTAssertEqual(usage.windows[0].kind, .weekly)
        XCTAssertEqual(AlertSeverity.forWindow(usage.windows[0].kind), .warning)
        let dual = try parsed(["rate_limit": [
            "primary_window": ["used_percent": 25, "limit_window_seconds": 18000],
            "secondary_window": ["used_percent": 75, "limit_window_seconds": 604800]]])
        XCTAssertEqual(dual.windows.map(\.kind), [.fiveHour, .weekly])
        XCTAssertEqual(try parsed(["five_hour": ["remaining_percent": 80]]).windows[0].pct, 20)
        guard case .failure = CodexFetcher().parseUsage(["primary_window": [
            "used_percent": 50, "limit_window_seconds": 86400]]) else {
            return XCTFail("Unknown duration was misclassified")
        }
    }

    func testAvailableCreditsExcludeHistoryAndSortExpiry() throws {
        let detail: [String: Any] = ["available_count": 3, "credits": [
            ["status": "available", "is_supported_by_plan": true, "expires_at": "2030-10-05T04:20:36.905353Z"],
            ["status": "redeemed", "is_supported_by_plan": true, "expires_at": "2030-01-01T00:00:00Z"],
            ["status": "expired", "is_supported_by_plan": true],
            ["status": "available", "is_supported_by_plan": false, "expires_at": "2030-10-04T05:43:33Z"],
            ["status": "available", "is_supported_by_plan": true, "expires_at": "invalid"]
        ]]
        let credits = try XCTUnwrap(parsed(weekly, detail: detail).resetCredits)
        XCTAssertEqual(credits.availableCount, 3)
        XCTAssertEqual(credits.applicableCount, 2)
        let entries = try XCTUnwrap(credits.credits)
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(entries[0].applicable)
        XCTAssertNotNil(entries[1].expiresAt)
        XCTAssertNil(entries[2].expiresAt)
    }

    func testDetailFailurePreservesSummaryAndUsageAndZeroIsDistinct() throws {
        var data = weekly
        data["rate_limit_reset_credits"] = ["available_count": 2, "applicable_available_count": 1]
        for detail in [nil, ["error": "unavailable"]] as [[String: Any]?] {
            let usage = try parsed(data, detail: detail)
            XCTAssertEqual(usage.windows.first?.kind, .weekly)
            XCTAssertEqual(usage.resetCredits?.availableCount, 2)
            XCTAssertEqual(usage.resetCredits?.applicableCount, 1)
            XCTAssertNil(usage.resetCredits?.credits)
        }
        XCTAssertNil(try parsed(weekly).resetCredits)
        let zero = try parsed(weekly, detail: ["available_count": 0, "credits": [[String: Any]]()])
        XCTAssertEqual(zero.resetCredits?.availableCount, 0)
        XCTAssertEqual(zero.resetCredits?.credits?.count, 0)
    }

    func testCacheRoundTripAndRejectsMislabelledLegacyCodex() throws {
        let service = "codex-test-" + UUID().uuidString
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/usage-dashboard/\(service).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let usage = try parsed(weekly, detail: ["available_count": 1, "credits": [
            ["status": "available", "is_supported_by_plan": true, "expires_at": "2030-10-04T05:43:33Z"]]])
        UsageCache.write(usage, service: service)
        let cached = try XCTUnwrap(UsageCache.read(service)?.usage)
        XCTAssertEqual(cached.windows.first?.kind, .weekly)
        XCTAssertEqual(cached.resetCredits?.availableCount, 1)
        XCTAssertEqual(cached.resetCredits?.credits?.first?.expiresAt, usage.resetCredits?.credits?.first?.expiresAt)
        try Data("{\"windows\":[{\"label\":\"5 小时\",\"pct\":92}]}".utf8).write(to: path)
        XCTAssertNil(UsageCache.read(service))
    }

    @MainActor func testCreditCardRendersAndRelayUsesISOExpiry() throws {
        _ = NSApplication.shared
        let usage = try parsed(weekly, detail: ["available_count": 2, "credits": [
            ["status": "available", "is_supported_by_plan": true, "expires_at": "2030-10-04T05:43:33Z"],
            ["status": "available", "is_supported_by_plan": true, "expires_at": "2030-10-05T04:20:36Z"]]])
        let config = ServiceConfig(id: "synthetic", title: "Codex · 测试账号", accent: "#10A37F",
                                   category: .subscription, fetcher: .codexWham)
        let runtime = ServiceRuntime(config: config, status: .ok(usage, fetchedAt: Date()), isCurrentAccount: true)
        let relay = String(decoding: relayPayloadJSON(states: [runtime], lastUpdated: nil), as: UTF8.self)
        XCTAssertTrue(relay.contains("2030-10-04T05:43:33Z"))
        XCTAssertTrue(relay.contains("availableCount"))
        let host = NSHostingView(rootView: ServiceCardView(runtime: runtime).frame(width: 360).padding(12)
            .background(Color(white: 0.12)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/multi-account-validation/reset-credits-preview.png"))
    }
}
