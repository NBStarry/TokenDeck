import Foundation
import Security

enum KeychainAuthorization {
    struct Report: Sendable {
        var checked = 0
        var failures: [String] = []

        var message: String {
            if checked == 0 { return "没有需要验证的钥匙串凭证" }
            if failures.isEmpty { return "钥匙串授权完成，已验证后续无弹窗读取成功" }
            return "钥匙串读取验证未通过：" + failures.joined(separator: "；")
        }
    }

    static func inspect(entries: [(String, [String: Any])],
                        read: ([String: Any]) -> OSStatus) -> Report {
        var report = Report()
        for (name, query) in entries {
            report.checked += 1
            let status = read(query)
            switch status {
            case errSecSuccess: break
            case errSecCSReqFailed:
                report.failures.append("\(name)：凭证助手签名校验失败，请重新安装完整应用（\(status)）")
            case errSecItemNotFound:
                report.failures.append("\(name)：凭证不存在，请添加账号或导入密钥")
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                report.failures.append("\(name)：未获得持续读取权限，请重试并在系统弹窗选择“始终允许”（\(status)）")
            default:
                report.failures.append("\(name)：钥匙串读取失败（\(status)）")
            }
        }
        return report
    }

    static func request() async -> String {
        return await Task.detached(priority: .userInitiated) {
            do {
                // Each explicit read runs in the stable helper. A new noninteractive
                // helper must also succeed before we report persistent authorization.
                try? CredentialStore.authorizeConfiguredCredentials()
                return try CredentialStore.configuredCredentialReport().message
            } catch { return "无法完成钥匙串验证，请检查配置或重试授权" }
        }.value
    }
}
