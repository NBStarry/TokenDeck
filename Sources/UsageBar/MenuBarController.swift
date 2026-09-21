import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private let previewHeight: CGFloat?
    private var cancellables = Set<AnyCancellable>()

    // 手机中转服务
    private var relayServer: RelayServer?
    // 线程安全缓存：snapshotProvider 从后台线程调用，主线程负责写入。
    private let relayCache = NSLock()
    private var relayJSON: Data = Data("{\"services\":[]}".utf8)

    init(store: UsageStore, previewHeight: CGFloat? = nil) {
        self.store = store
        self.previewHeight = previewHeight
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            updateStatusIcon(alertCount: store.activeAlertCount,
                             severity: store.highestActiveSeverity)
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 角标颜色取当前最高严重度(5h 红 / 周 橙),数量进 tooltip。
        store.$activeAlertCount.combineLatest(store.$highestActiveSeverity)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] count, severity in
                self?.updateStatusIcon(alertCount: count, severity: severity)
            }
            .store(in: &cancellables)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverRootView().environmentObject(store))
        // 让 popover 随 SwiftUI 内容(如展开模型列表)自动调整大小,否则内容会被截断。
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        // 手机中转服务：启动 RelayServer，snapshotProvider 只读缓存（线程安全）。
        guard previewHeight == nil else { return }
        let relaySettings = RelayConfigStore.loadOrCreate()
        // 启动时先算一次初值（主线程，states 已就绪）。
        relayJSON = relayPayloadJSON(states: store.states, lastUpdated: store.lastUpdated)
        // 订阅 states 变化，在主线程更新缓存。
        store.$states
            .combineLatest(store.$lastUpdated)
            .sink { [weak self] states, lastUpdated in
                guard let self else { return }
                let data = relayPayloadJSON(states: states, lastUpdated: lastUpdated)
                self.relayCache.lock()
                self.relayJSON = data
                self.relayCache.unlock()
            }
            .store(in: &cancellables)
        relayServer = RelayServer(settings: relaySettings, snapshotProvider: { [weak self] in
            self?.currentRelayJSON() ?? Data("{\"services\":[]}".utf8)
        })
        relayServer?.start()
    }

    private func currentRelayJSON() -> Data {
        relayCache.lock()
        defer { relayCache.unlock() }
        return relayJSON
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover(relativeTo previewAnchor: NSView? = nil) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.synchronizeCurrentAccount()
            let height = previewHeight ?? max(160, (button.window?.screen?.visibleFrame.height ?? 720) - 32)
            let host = NSHostingController(rootView: PopoverRootView(availableHeight: height, showsRelayPanel: previewHeight == nil).environmentObject(store))
            host.sizingOptions = [.preferredContentSize]
            popover.contentViewController = host
            let anchor = previewAnchor ?? button
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await store.refresh() }
        }
    }

    // 右键菜单:刷新 / 开机自启 / 退出。
    private func showMenu() {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let launch = NSMenuItem(title: "开机自启", action: #selector(menuToggleLaunch), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // 临时挂上菜单弹出,弹完即摘,保证左键仍能 toggle popover。
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { Task { await store.refresh() } }

    @objc private func menuToggleLaunch(_ sender: NSMenuItem) {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func updateStatusIcon(alertCount: Int, severity: AlertSeverity?) {
        guard let button = statusItem.button else { return }
        if alertCount > 0 {
            let sev = severity ?? .critical
            button.image = Self.alertStatusImage(severity: sev)
            button.image?.isTemplate = false
            let kindText = sev == .critical ? "含 5 小时" : "仅周额度"
            button.toolTip = "订阅用量:\(alertCount) 个告警(\(kindText))"
        } else {
            button.image = Self.normalStatusImage()
            button.image?.isTemplate = true
            button.toolTip = "订阅用量"
        }
    }

    private static func badgeColor(_ severity: AlertSeverity) -> NSColor {
        switch severity {
        case .critical: return .systemRed
        case .warning:  return .systemOrange
        }
    }

    private static func normalStatusImage() -> NSImage? {
        NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                accessibilityDescription: "订阅用量")
    }

    private static func alertStatusImage(severity: AlertSeverity) -> NSImage {
        let size = NSSize(width: 24, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let base = normalStatusImage()?.withSymbolConfiguration(symbolConfig)
        let baseRect = NSRect(x: 0, y: 1, width: 17, height: 16)
        NSColor.labelColor.set()
        base?.draw(in: baseRect, from: .zero, operation: .sourceOver, fraction: 0.9,
                   respectFlipped: true, hints: nil)

        let badgeRect = NSRect(x: 13, y: 7, width: 10, height: 10)
        badgeColor(severity).setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        NSString(string: "!").draw(in: NSRect(x: 13, y: 6.2, width: 10, height: 10), withAttributes: attrs)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
