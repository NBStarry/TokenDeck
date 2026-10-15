import XCTest
import SwiftUI
@testable import TokenDeck

final class CardCollapseTests: XCTestCase {
    @MainActor func testSummariesPreserveStatusAndBothQuotaPools() {
        let display = ServiceDisplayOptions()
        let info = APIInfo(balances: nil, isAvailable: nil, models: nil, quotas: [
            EnvironmentQuota(id: "cloud_desktop", name: "云桌面／服务器", used: 10, remaining: 90, total: 100, resetsAt: ""),
            EnvironmentQuota(id: "non_cloud", name: "非云端", used: 20, remaining: 0, total: 20, resetsAt: "")
        ])
        let usage = Usage(apiInfo: info)
        XCTAssertEqual(ServiceCardView.summary(.ok(usage, fetchedAt: Date()), display: display), "云余90 / 非云余0")
        XCTAssertEqual(ServiceCardView.summary(.stale(usage, cachedAt: nil, error: "offline"), display: display), "缓存 · 云余90 / 非云余0")
        XCTAssertEqual(ServiceCardView.summary(.loading, display: display), "加载中…")
        XCTAssertEqual(ServiceCardView.summary(.error("offline"), display: display), "加载失败")
        var hidden = display
        hidden.balance = false
        hidden.used = false
        XCTAssertEqual(ServiceCardView.summary(.ok(usage, fetchedAt: Date()), display: hidden), "额度已隐藏")
        let unavailable = Usage(apiInfo: APIInfo(balances: [APIBalance(currency: "USD", total: 0, toppedUp: 0, granted: 0)], isAvailable: false, models: nil))
        XCTAssertTrue(ServiceCardView.summary(.ok(unavailable, fetchedAt: Date()), display: display).contains("不可用"))
        let small = Usage(balance: BalanceInfo(balance: 0.04, used: 0, currency: "$", requestCount: nil, models: []))
        XCTAssertEqual(ServiceCardView.summary(.ok(small, fetchedAt: Date()), display: display), "余$0.04")
        let key = Usage(apiInfo: APIInfo(balances: nil, isAvailable: nil, models: nil, openRouter: OpenRouterInfo(scope: .key, used: 5, remaining: nil, limit: nil, reset: nil)))
        XCTAssertEqual(ServiceCardView.summary(.ok(key, fetchedAt: Date()), display: display), "Key未设限额")
    }

    @MainActor func testPersistentIDsAndCollapsedRendering() throws {
        _ = NSApplication.shared
        let id = "collapse-test-" + UUID().uuidString
        let secondID = id + "-other"
        defer {
            UserDefaults.standard.removeObject(forKey: "cardCollapsed." + id)
            UserDefaults.standard.removeObject(forKey: "cardCollapsed." + secondID)
        }
        let config = ServiceConfig(id: id, title: "同名长标题 ABCDEFGHIJKLMNOPQRSTUVWXYZ", accent: "#7C5CFC", category: .subscription, fetcher: .codexWham)
        let usage = Usage(apiInfo: APIInfo(balances: nil, isAvailable: nil, models: nil, quotas: [
            EnvironmentQuota(id: "cloud_desktop", name: "云桌面／服务器", used: 10, remaining: 29000, total: 30000, resetsAt: ""),
            EnvironmentQuota(id: "non_cloud", name: "非云端", used: 1, remaining: 4999, total: 5000, resetsAt: "")
        ]))
        let runtime = ServiceRuntime(config: config, status: .stale(usage, cachedAt: nil, error: "合成错误"))
        func host(_ runtime: ServiceRuntime) -> NSHostingView<some View> {
            NSHostingView(rootView: ServiceCardView(runtime: runtime, onRefresh: {}, dragProvider: { NSItemProvider() }).frame(width: 326).padding(12).background(Color(white: 0.12)))
        }
        let expanded = host(runtime)
        let expandedHeight = expanded.fittingSize.height
        UserDefaults.standard.set(true, forKey: "cardCollapsed." + id)
        let collapsed = host(runtime)
        let size = collapsed.fittingSize
        XCTAssertLessThan(size.height, expandedHeight)
        XCTAssertLessThan(size.height, 85)
        let other = ServiceConfig(id: secondID, title: config.title, accent: config.accent, category: config.category, fetcher: config.fetcher)
        XCTAssertEqual(host(ServiceRuntime(config: other, status: runtime.status)).fittingSize.height, expandedHeight, accuracy: 1)
        XCTAssertEqual(host(runtime).fittingSize.height, size.height, accuracy: 1)
        collapsed.frame = NSRect(origin: .zero, size: size)
        collapsed.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(collapsed.bitmapImageRepForCachingDisplay(in: collapsed.bounds))
        collapsed.cacheDisplay(in: collapsed.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/card-drag-reorder-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mac-collapsed-drag.png"))
    }
}
