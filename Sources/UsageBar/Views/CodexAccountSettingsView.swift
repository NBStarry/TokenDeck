import SwiftUI
import UniformTypeIdentifiers

struct CodexAccountSettingsView: View {
    @EnvironmentObject var store: UsageStore
    @ObservedObject private var login = CodexLoginController.shared
    @State private var showingImporter = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex 多账户").font(.system(size: 12, weight: .semibold))
            Text("点击添加账号，在浏览器完成登录后自动保存。当前账号自动置顶。")
                .font(.system(size: 11)).foregroundColor(Theme.subGray)
                .fixedSize(horizontal: false, vertical: true)
            Button("添加账号") { CodexLoginController.shared.show(store: store) }
                .accessibilityIdentifier("login-codex-account")
            DisclosureGroup("其他添加方式") {
                Button("添加／更新当前登录账号") { importError = nil; store.addCurrentAccount() }
                    .accessibilityIdentifier("add-codex-account")
                Button("从独立登录目录导入…") { importError = nil; showingImporter = true }
                    .accessibilityIdentifier("import-codex-account")
                Text("选择独立登录目录或 auth.json。只添加账号，不切换当前登录。")
                    .font(.system(size: 10)).foregroundColor(Theme.subGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = store.accountNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10)).foregroundColor(.green)
            }
            ForEach(store.config.codexAccounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.accountName(account.id)).fontWeight(.medium)
                    Text(String(account.id.suffix(6))).font(.caption2).foregroundStyle(.secondary)
                    if account.id == store.currentAccountID { Text("当前使用").foregroundColor(.green) }
                    if account.id != store.currentAccountID {
                        Button("设为 CLI 当前账号") {
                            if store.needsCLILogin(account.id) {
                                login.show(store: store, expectedID: account.id, switchAfterLogin: true)
                            } else { store.switchCLIAccount(account.id) }
                        }
                        .disabled(login.running || login.canRetrySave || store.isSwitchingAccount)
                    }
                    HStack {
                        Button("重新登录") { CodexLoginController.shared.show(store: store, expectedID: account.id) }
                        Button("移除") { store.removeAccount(account.id) }
                    }
                }
            }
            Text("切换只影响默认登录；请重开 CLI 会话。自定义 CODEX_HOME 或 API Key 不受控制，共享默认登录的 IDE 也可能受影响。")
                .font(.system(size: 10)).foregroundColor(Theme.subGray)
            Text("凭证过期时，点击该账号的重新登录。移除仅删除本应用副本，当前登录账号仍会显示。")
                .font(.system(size: 10)).foregroundColor(Theme.subGray)
                .fixedSize(horizontal: false, vertical: true)
            if let error = importError ?? store.accountError {
                Text(error).font(.system(size: 11)).foregroundColor(Theme.red)
            }
        }
        .disabled(store.isSwitchingAccount)
        .font(.system(size: 11))
        .foregroundColor(.white)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.24)))
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder, .json]) { result in
            importError = nil
            switch result {
            case .success(let url): store.importAccount(from: url)
            case .failure: importError = "无法打开所选登录文件，请重试"
            }
        }
    }
}
