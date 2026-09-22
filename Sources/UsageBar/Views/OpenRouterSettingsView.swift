import SwiftUI

struct OpenRouterSettingsView: View {
    @EnvironmentObject var store: UsageStore
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            SecureField("输入 API Key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { value in if !value.isEmpty { saved = false } }
            HStack {
                Button("保存并刷新") {
                    if store.configureOpenRouter(key) {
                        key = ""
                        saved = true
                    }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved { Text("已保存到钥匙串").font(.system(size: 11)).foregroundColor(.green) }
            }
            Text("普通 Key 显示自身用量和限额；管理 Key 显示账户余额。")
                .font(.system(size: 10)).foregroundColor(Theme.subGray)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.24)))
    }
}
