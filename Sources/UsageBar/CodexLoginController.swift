import AppKit
import SwiftUI

@MainActor
final class CodexLoginController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CodexLoginController()
    @Published private(set) var message = "在浏览器完成官方登录后，账号会自动添加。"
    @Published private(set) var running = false
    @Published private(set) var needsExecutable = false
    private var window: NSWindow?
    private var process: Process?
    private var task: Task<Void, Never>?
    private var pending: CredentialStore.CodexCreds?
    private var store: UsageStore?
    private var expectedID: String?
    @Published private(set) var switchAfterLogin = false
    private var executable: URL?

    init(executable: URL? = nil, store: UsageStore? = nil) {
        self.executable = executable
        self.store = store
        super.init()
    }

    static func nativeExecutable(_ url: URL) -> URL {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.pathExtension == "js" else { return url }
        #if arch(arm64)
        let platform = "arm64"
        let triple = "aarch64"
        #else
        let platform = "x64"
        let triple = "x86_64"
        #endif
        let root = resolved.deletingLastPathComponent().deletingLastPathComponent()
        let relative = "vendor/\(triple)-apple-darwin/bin/codex"
        for candidate in [root.appendingPathComponent("node_modules/@openai/codex-darwin-\(platform)/" + relative), root.appendingPathComponent(relative)] {
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return url
    }

    static func findExecutable() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: url.path) { return nativeExecutable(url) }
        }
        return nil
    }

    func show(store: UsageStore, expectedID: String? = nil, switchAfterLogin: Bool = false) {
        guard !store.isSwitchingAccount else { return }
        if running || pending != nil { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        self.store = store
        self.expectedID = expectedID
        self.switchAfterLogin = switchAfterLogin
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Codex 账号登录"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: CodexLoginView(controller: self))
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        start()
    }

    func start(timeout: TimeInterval = 300) {
        guard !running else { return }
        guard let executable = executable ?? Self.findExecutable() else {
            needsExecutable = true
            message = "未找到 Codex，请选择已安装的程序，或查看官方安装说明。"
            return
        }
        needsExecutable = false
        pending = nil
        running = true
        message = "等待浏览器登录…请在浏览器中选择要添加的账号。"
        task = Task { [weak self] in
            guard let self else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokendeck-login-" + UUID().uuidString)
            defer {
                try? FileManager.default.removeItem(at: directory)
                self.process = nil
                self.running = false
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let p = Process()
                p.executableURL = Self.nativeExecutable(executable)
                p.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login"]
                var env = ProcessInfo.processInfo.environment
                env["CODEX_HOME"] = directory.path
                env["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                for key in ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY"] { env[key] = nil }
                p.environment = env
                p.currentDirectoryURL = directory
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                self.process = p
                try p.run()
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && !Task.isCancelled && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                if p.isRunning {
                    p.terminate()
                    let stopDeadline = Date().addingTimeInterval(2)
                    while p.isRunning && Date() < stopDeadline { await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value }
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    while p.isRunning { await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value }
                    self.message = Task.isCancelled ? "登录已取消" : "登录超时，请重试"
                    return
                }
                guard !Task.isCancelled else { self.message = "登录已取消"; return }
                guard p.terminationStatus == 0,
                      case .ok(let creds) = CredentialStore.codexCreds(at: directory) else {
                    self.message = "登录未完成，或未取得有效订阅账号。请重试；若浏览器未打开，请检查 Codex 安装及网络。"
                    return
                }
                if let expectedID = self.expectedID, expectedID != creds.identity {
                    self.message = "登录账号不匹配，请重试并选择原账号。"
                    return
                }
                self.pending = creds
                self.savePending()
                self.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch { self.message = "无法启动登录程序，请检查所选 Codex 程序后重试。" }
        }
    }

    func savePending() {
        guard let pending, let store else { return }
        if store.saveAccount(pending, expectedID: expectedID) {
            if switchAfterLogin {
                if store.switchCLIAccount(pending.identity) {
                    self.pending = nil
                    message = store.accountNotice ?? "已切换，请重开 CLI 会话"
                } else { message = store.accountError ?? "切换失败，请重试" }
                return
            }
            self.pending = nil
            message = "已添加／更新：" + pending.displayName + "。可关闭窗口返回仪表盘。"
        } else { message = store.accountError ?? "保存失败，请重试保存" }
    }
    var canRetrySave: Bool { pending != nil }
    func cancel() { task?.cancel(); pending = nil; if !running { message = "登录已取消" } }
    func windowWillClose(_ notification: Notification) { cancel() }
    func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择已安装的 Codex 可执行程序"
        if panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) {
            executable = url
            start()
        }
    }
}

private struct CodexLoginView: View {
    @ObservedObject var controller: CodexLoginController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("登录 Codex 账号").font(.headline)
            Text(controller.message).fixedSize(horizontal: false, vertical: true)
            Text(controller.switchAfterLogin ? "登录成功后切换默认 CLI 账号；不会结束现有会话。" : "不会退出或切换你当前使用的 Codex 账号。").font(.caption).foregroundStyle(.secondary)
            HStack {
                if controller.running {
                    ProgressView().controlSize(.small)
                    Button("取消登录") { controller.cancel() }
                } else if controller.canRetrySave {
                    Button("重试保存") { controller.savePending() }
                    Button("取消") { controller.cancel() }
                } else {
                    Button("重新登录") { controller.start() }
                    Button("选择 Codex 程序…") { controller.chooseExecutable() }
                }
                if controller.needsExecutable {
                    Link("安装说明", destination: URL(string: "https://developers.openai.com/codex/cli/")!)
                }
            }
        }.padding(24).frame(width: 420, height: 230)
    }
}
