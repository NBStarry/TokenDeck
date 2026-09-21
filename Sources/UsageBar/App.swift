import AppKit
import SwiftUI
import UserNotifications

@main
struct TokenDeckApp {
    @MainActor
    static func main() {
        // 隐藏 CLI 模式:--fetch <claude|codex>,跑一次取数并打印 JSON 后退出。
        // 用于无头验证取数层,与 GUI 共用同一套 Fetcher。
        let args = CommandLine.arguments
        if args.contains("--import-api-keys") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let keys = try JSONDecoder().decode([String: String].self, from: data)
                // 不通过 load 的默认回退覆盖用户已有但无法解析的配置。
                var config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: AppConfigStore.configURL))
                try ProviderAPIImport.apply(keys, config: &config, saveKey: CredentialStore.saveAPIKey)
                try AppConfigStore.save(config)
                print("API 凭证已保存，渠道配置已更新")
            } catch {
                print("API 导入失败；请检查输入、钥匙串及配置权限后重试")
                exit(1)
            }
            return
        }
        if args.contains("--preview-accounts") {
            AccountPreview.run()
            return
        }
        if args.count >= 3, args[1] == "--fetch" {
            runFetchCLI(service: args[2])
            return
        }
        // 无头开/关开机自启(注册的是当前运行二进制所属的 .app)。
        if args.count >= 2, args[1] == "--register-login" {
            let ok = LaunchAtLogin.set(true)
            print(ok ? "开机自启:已开启 (\(LaunchAtLogin.isEnabled))" : "开机自启:注册失败")
            return
        }
        if args.count >= 2, args[1] == "--unregister-login" {
            let ok = LaunchAtLogin.set(false)
            print(ok ? "开机自启:已关闭" : "开机自启:取消失败")
            return
        }
        // 调试:离屏渲染 PhanRouter 卡(模型列表展开)到 /tmp/token_usage_dashboard_preview.png。
        if args.count >= 2, args[1] == "--render" {
            renderPreview()
            return
        }
        // README 截图:用模拟数据离屏渲染主面板和设置页。
        if args.count >= 2, args[1] == "--render-readme" {
            renderReadmeScreenshots()
            return
        }
        // 调试:加载 config.json(含旧格式迁移)并打印解析后的告警配置,只读不写。
        if args.count >= 2, args[1] == "--dump-alerts" {
            dumpAlerts()
            return
        }
        // 调试:用模拟快照打印 relay JSON 到 stdout(核对契约形状)。
        if args.count >= 2, args[1] == "--relay-sample" {
            printRelaySample()
            return
        }
        // 调试:启动 NWListener HTTP 中继服务器（GET /usage，Bearer 校验）。
        if args.count >= 2, args[1] == "--serve" {
            let s = RelayConfigStore.loadOrCreate()
            // snapshotProvider 在 NWListener 后台队列中被调用，
            // 需要将 @MainActor 函数调用 dispatch 到主线程同步获取结果。
            let srv = RelayServer(settings: s, snapshotProvider: {
                var result = Data()
                DispatchQueue.main.sync {
                    result = relayPayloadJSON(states: makeSampleStates(), lastUpdated: Date())
                }
                return result
            })
            srv.start()
            print("listening \(s.port)")
            RunLoop.main.run()
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 无 Dock 图标的菜单栏 App
        app.run()
    }

    @MainActor
    static func renderPreview() {
        let sem = DispatchSemaphore(value: 0)
        var info: BalanceInfo?
        let config = AppConfig.default.services.first { $0.id == "phanrouter" }
        Task.detached {
            if let config, let fetcher = makeFetcher(for: config),
               case .success(let u) = await fetcher.fetch() {
                info = u.balance
            }
            sem.signal()
        }
        sem.wait()
        guard let info else { print("无 PhanRouter 数据"); return }

        let card = VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "#7C5CFC")).frame(width: 9, height: 9)
                Text("PhanRouter").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Spacer()
            }.padding(.bottom, 12)
            BalanceCardBody(info: info, accent: Color(hex: "#7C5CFC"), forceExpand: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardBg))
        .frame(width: 320)
        .padding(20)
        .background(Color(white: 0.12))

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败"); return
        }
        let url = URL(fileURLWithPath: "/tmp/token_usage_dashboard_preview.png")
        try? png.write(to: url)
        print("已渲染 \(url.path)")
    }

    @MainActor
    static func makeSampleStates() -> [ServiceRuntime] {
        let now = Date()
        return [
            ServiceRuntime(
                config: ServiceConfig(id: "claude", title: "Claude", accent: "#D97757",
                                      category: .subscription, fetcher: .claudeOAuth),
                status: .ok(Usage(plan: "Pro", windows: [
                    UsageWindow(label: "5 小时", pct: 72, resetAt: now.addingTimeInterval(76 * 60)),
                    UsageWindow(label: "周", pct: 48, resetAt: now.addingTimeInterval(3 * 24 * 60 * 60)),
                ]), fetchedAt: now)
            ),
            ServiceRuntime(
                config: ServiceConfig(id: "codex", title: "Codex", accent: "#10A37F",
                                      category: .subscription, fetcher: .codexWham),
                status: .ok(Usage(plan: "Plus", windows: [
                    UsageWindow(label: "5 小时", pct: 63, resetAt: now.addingTimeInterval(124 * 60)),
                    UsageWindow(label: "周", pct: 36, resetAt: now.addingTimeInterval(5 * 24 * 60 * 60)),
                ]), fetchedAt: now)
            ),
            ServiceRuntime(
                config: ServiceConfig(id: "phanrouter", title: "PhanRouter", accent: "#7C5CFC",
                                      category: .apiUsage, fetcher: .newAPI,
                                      credentialFile: "phanrouter.json"),
                status: .ok(Usage(balance: BalanceInfo(
                    balance: 18.42,
                    used: 31.58,
                    currency: "$",
                    requestCount: 12864,
                    models: [
                        ModelEntry(name: "gpt-4.1", vendor: "OpenAI"),
                        ModelEntry(name: "o3", vendor: "OpenAI"),
                        ModelEntry(name: "claude-3.7-sonnet", vendor: "Anthropic"),
                        ModelEntry(name: "gemini-2.5-pro", vendor: "Google"),
                        ModelEntry(name: "deepseek-r1", vendor: "DeepSeek"),
                    ]
                )), fetchedAt: now)
            ),
        ]
    }

    @MainActor
    static func renderReadmeScreenshots() {
        let baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Docs/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let sampleStates = makeSampleStates()

        let popover = ReadmePopoverPreview(states: sampleStates)
        renderPNG(popover, to: baseURL.appendingPathComponent("token-usage-dashboard-popover.png"))

        let settingsConfig = AppConfig.default
        let settingsStore = UsageStore(config: settingsConfig)
        let settings = ReadmeSettingsPreview()
            .environmentObject(settingsStore)
        renderPNG(settings, to: baseURL.appendingPathComponent("token-usage-dashboard-settings.png"))

        print("已生成 README 截图: \(baseURL.path)")
    }

    @MainActor
    static func printRelaySample() {
        let sampleStates = makeSampleStates()
        let data = relayPayloadJSON(states: sampleStates, lastUpdated: Date())
        print(String(data: data, encoding: .utf8) ?? "")
    }

    @MainActor
    static func renderPNG<Content: View>(_ content: Content, to url: URL) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败: \(url.path)")
            return
        }
        try? png.write(to: url)
    }

    @MainActor
    static func dumpAlerts() {
        let a = AppConfigStore.load().alerts
        func line(_ kind: WindowKind) -> String {
            let w = a.config(for: kind)
            return "  \(kind.settingsTitle): enabled=\(w.enabled) threshold=\(Int(w.threshold))% rule=\(w.rule.title) pace=\(w.paceMultiplier)"
        }
        print("订阅号告警 enabled=\(a.enabled) cooldown=\(a.cooldownSeconds)s serviceIDs=\(a.serviceIDs.map { "\($0)" } ?? "全部")")
        print(line(.fiveHour))
        print(line(.weekly))
    }

    @MainActor
    static func runFetchCLI(service: String) {
        guard let fetcher = makeFetcher(for: service) else {
            print("{\"ok\":false,\"error\":\"未知服务: \(service)\"}")
            return
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let outcome = await fetcher.fetch()
            switch outcome {
            case .success(let u):
                if let info = u.apiInfo, let encoded = try? JSONEncoder().encode(info),
                   let value = try? JSONSerialization.jsonObject(with: encoded),
                   let data = try? JSONSerialization.data(withJSONObject: ["ok": true, "service": service, "apiInfo": value]) {
                    print(String(decoding: data, as: UTF8.self))
                } else if let b = u.balance {
                    let vendors = b.groupedModels.map { "\($0.vendor):\($0.models.count)" }.joined(separator: ", ")
                    print("{\"ok\":true,\"service\":\"\(service)\",\"balance\":\(b.balance),\"used\":\(b.used),\"requestCount\":\(b.requestCount ?? 0),\"modelCount\":\(b.models.count),\"vendors\":\"\(vendors)\"}")
                } else {
                    let wins = u.windows.map {
                        "{\"label\":\"\($0.label)\",\"pct\":\($0.pct),\"resetAt\":\"\($0.resetAt?.description ?? "")\"}"
                    }.joined(separator: ",")
                    print("{\"ok\":true,\"service\":\"\(service)\",\"plan\":\"\(u.plan ?? "")\",\"windows\":[\(wins)]}")
                }
            case .failure(let msg):
                print("{\"ok\":false,\"service\":\"\(service)\",\"error\":\"\(msg)\"}")
            }
            sem.signal()
        }
        sem.wait()
    }
}

private struct ReadmePopoverPreview: View {
    let states: [ServiceRuntime]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("订阅用量")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                    Text("设置")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.88))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }

            ForEach(states) { rt in
                ServiceCardView(runtime: rt)
            }

            HStack(spacing: 10) {
                Text("更新于 16:20")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.footGray)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("刷新")
                        .font(.system(size: 11))
                }
                .foregroundColor(.white.opacity(0.9))
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.subGray)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(.sRGB, red: 22/255, green: 22/255, blue: 24/255, opacity: 1))
    }
}

private struct ReadmeSettingsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("显示设置")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("完成")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.88))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 10) {
                alertPanel

                Text("渠道商")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                serviceRow(title: "Claude", type: "订阅号", color: Color(hex: "#D97757"),
                           items: ["套餐", "5 小时", "周额度", "重置倒计时", "更新时间"])
                serviceRow(title: "Codex", type: "订阅号", color: Color(hex: "#10A37F"),
                           items: ["套餐", "5 小时", "周额度", "更新时间"])
                serviceRow(title: "PhanRouter", type: "API 用量", color: Color(hex: "#7C5CFC"),
                           items: ["当前余额", "历史消耗", "请求次数", "模型列表"])

                Text("保存到 ~/.config/usage-bar/config.json")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.58))
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Color(.sRGB, red: 22/255, green: 22/255, blue: 24/255, opacity: 1))
    }

    private var alertPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.square.fill")
                    .foregroundColor(Color(hex: "#3FB950"))
                    .font(.system(size: 13, weight: .semibold))
                Text("订阅号告警")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.96))
            }

            windowAlertGroup(title: "5 小时", dot: Theme.red, threshold: "60%",
                             progress: 0.6, ruleElapsedActive: true)
            windowAlertGroup(title: "周额度", dot: Color(hex: "#FF9F0A"), threshold: "80%",
                             progress: 0.8, ruleElapsedActive: false)

            Text("冷却 30 分钟")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.86))
        }
        .padding(10)
        .background(panelBackground)
    }

    private func windowAlertGroup(title: String, dot: Color, threshold: String,
                                  progress: Double, ruleElapsedActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.square.fill")
                    .foregroundColor(Color(hex: "#3FB950"))
                    .font(.system(size: 12, weight: .semibold))
                Circle().fill(dot).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
            }
            HStack {
                Text("阈值")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
                Spacer()
                Text(threshold)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
            mockSlider(progress: progress)
            HStack(spacing: 6) {
                rulePill("跑赢时间进度", active: ruleElapsedActive)
                rulePill("仅超过阈值", active: !ruleElapsedActive)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }

    private func serviceRow(title: String, type: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.square.fill")
                    .foregroundColor(Color(hex: "#3FB950"))
                    .font(.system(size: 13, weight: .semibold))
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.96))
                Text(type)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.square.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "#3FB950"))
                        Text(item)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.86))
                    }
                }
            }
            .padding(.leading, 18)
        }
        .padding(10)
        .background(panelBackground)
    }

    private func mockSlider(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(Color(hex: "#3FB950"))
                    .frame(width: geo.size.width * progress)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, geo.size.width * progress - 6))
            }
        }
        .frame(height: 7)
    }

    private func rulePill(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(active ? .white : .white.opacity(0.58))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.white.opacity(0.16) : Color.white.opacity(0.06)))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.24))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        let config = AppConfigStore.load()
        store = UsageStore(config: config)
        menuBar = MenuBarController(store: store)
        store.start()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
