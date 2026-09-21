import AppKit
import SwiftUI

// Interactive QA uses the production views with isolated, synthetic IO.
@MainActor
enum AccountPreview {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let creds = (0..<10).map {
            CredentialStore.CodexCreds(accessToken: "preview", accountId: "preview", userId: "preview-\($0)")
        }
        var config = AppConfig.default
        config.alerts.enabled = false
        config.codexAccounts = creds.enumerated().map { CodexAccount(id: $0.element.identity, name: "演示账号 \($0.offset + 1)") }
        var saved = Dictionary(uniqueKeysWithValues: creds.map { ($0.identity, $0) })
        var cache: [String: UsageCache.Cached] = [:]
        var dependencies = UsageDependencies()
        var currentIndex = 2
        dependencies.currentCredentials = { .ok(creds[currentIndex]) }
        dependencies.savedCredentials = { saved[$0] }
        dependencies.saveCredentials = { saved[$0.identity] = $0 }
        dependencies.removeCredentials = { saved[$0] = nil }
        dependencies.saveConfig = { _ in }
        dependencies.readCache = { cache[$0] }
        dependencies.writeCache = { cache[$1] = .init(usage: $0, ts: Date()) }
        dependencies.notify = { _, _ in }
        dependencies.requestNotificationAuthorization = {}
        dependencies.fetch = { cfg, _ in
            if cfg.category == .apiUsage {
                return .success(Usage(balance: BalanceInfo(balance: 42, used: 12, currency: "$", requestCount: 100,
                    models: (0..<20).map { ModelEntry(name: "演示模型 \($0)", vendor: "演示") })))
            }
            return .success(Usage(plan: "Plus", windows: [
                UsageWindow(label: "5 小时", pct: 65, resetAt: Date().addingTimeInterval(3600)),
                UsageWindow(label: "周", pct: 35, resetAt: Date().addingTimeInterval(86400))]))
        }
        let store = UsageStore(config: config, dependencies: dependencies)
        let controller = MenuBarController(store: store, previewHeight: 480)
        store.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TokenDeck 隔离验收"
        window.contentView = NSHostingView(rootView: VStack(spacing: 16) {
            Text("十个模拟账号 · 480 点高度 · 不读取真实凭证")
            Button("打开／关闭菜单栏面板") { controller.togglePopover(relativeTo: window.contentView) }
            Button("切换模拟当前账号") {
                currentIndex = (currentIndex + 1) % creds.count
                store.synchronizeCurrentAccount()
                Task { await store.refresh() }
            }
            PopoverRootView(availableHeight: 480, showsRelayPanel: false).environmentObject(store)
        }.padding(10).frame(width: 380, height: 640))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((controller, window)) { app.run() }
    }
}
