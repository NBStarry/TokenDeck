import SwiftUI

struct ProviderAPICardBody: View {
    let info: APIInfo
    let display: ServiceDisplayOptions
    let accent: Color
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let router = info.openRouter {
                Text(router.scope == .account ? "账户额度 · USD" : "当前 Key · USD")
                    .foregroundColor(Theme.labelGray)
                if display.balance {
                    if let remaining = router.remaining {
                        Text(String(format: "%@ $%.2f", router.scope == .account ? "账户余额" : "Key 剩余额度", remaining))
                            .font(.system(size: 18, weight: .semibold)).foregroundColor(accent)
                    } else {
                        Text(router.limit == nil ? "Key 未设限额" : "Key 剩余额度未知")
                            .foregroundColor(Theme.subGray)
                    }
                    if let limit = router.limit { Text(String(format: "Key 限额 $%.2f", limit)).foregroundColor(Theme.subGray) }
                }
                if display.used {
                    Text(String(format: "%@ $%.2f", router.scope == .account ? "账户累计消耗" : "Key 累计消耗", router.used))
                        .foregroundColor(Theme.subGray)
                }
                if router.scope == .key {
                    if let reset = router.reset {
                        Text("Key 限额重置周期：" + (["daily": "每日", "weekly": "每周", "monthly": "每月"][reset] ?? reset))
                            .foregroundColor(Theme.subGray)
                    }
                    Text("账户总余额需使用管理 Key 查询").foregroundColor(Theme.subGray)
                }
            }
            if let balances = info.balances {
                if display.balance {
                    ForEach(Array(balances.enumerated()), id: \.offset) { _, balance in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("总余额 · \(balance.currency)").foregroundColor(Theme.labelGray)
                            Text(String(format: "%.2f", balance.total))
                                .font(.system(size: 22, weight: .semibold)).foregroundColor(accent)
                            Text(String(format: "充值余额 %.2f · 赠金余额 %.2f", balance.toppedUp, balance.granted))
                                .foregroundColor(Theme.subGray)
                        }
                    }
                }
                if info.isAvailable == false {
                    Text("余额不足，当前不可调用").foregroundColor(Theme.amber)
                } else if !display.balance {
                    Text("余额展示已关闭").foregroundColor(Theme.subGray)
                }
            }
            if let models = info.models {
                Text("密钥查询正常").foregroundColor(accent)
                Text("暂不提供额度查询").foregroundColor(Theme.subGray)
                if display.models {
                    if models.isEmpty {
                        Text("暂无授权模型").foregroundColor(Theme.subGray)
                    } else {
                        Button {
                            withAnimation { expanded.toggle() }
                        } label: {
                            HStack {
                                Text("授权模型 · \(models.count)")
                                Spacer()
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundColor(Theme.labelGray)
                        if expanded {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(models, id: \.self) { Text($0).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 150).foregroundColor(Theme.subGray)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
    }
}
