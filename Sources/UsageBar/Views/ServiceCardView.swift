import SwiftUI

struct ServiceCardView: View {
    let runtime: ServiceRuntime
    var refreshing = false
    var refreshEnabled = true
    var onRefresh: (() -> Void)? = nil

    private var accent: Color { Color(hex: runtime.config.accent) }
    private var display: ServiceDisplayOptions { runtime.config.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if runtime.isCurrentAccount {
                Text("当前使用")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#10A37F"))
                    .padding(.bottom, 8)
            }
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cardBg)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    // ─── 头部:色点 + 名称 + plan 徽章 ───
    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 9, height: 9)
                .shadow(color: accent, radius: 3)
            Text(runtime.config.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer(minLength: 0)
            if display.plan, let plan = currentPlan {
                Text(plan)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black))
            }
            if let onRefresh {
                Button(action: onRefresh) {
                    if refreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.subGray)
                .frame(width: 24, height: 24)
                .disabled(!refreshEnabled || refreshing)
                .help("刷新此渠道")
                .accessibilityLabel("刷新 " + runtime.config.title)
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch runtime.status {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("加载中…").font(.system(size: 12)).foregroundColor(Theme.subGray)
            }
            .padding(.vertical, 4)

        case .ok(let usage, let fetchedAt):
            usageBody(usage)
            if display.updatedAt { footerOK(fetchedAt) }

        case .stale(let usage, let cachedAt, let error):
            usageBody(usage)
            footerStale(cachedAt)
            Text(error)
                .font(.system(size: 10))
                .foregroundColor(Theme.amber)
                .fixedSize(horizontal: false, vertical: true)

        case .error(let msg):
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(Theme.red)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    private var currentPlan: String? {
        switch runtime.status {
        case .ok(let u, _): return u.plan
        case .stale(let u, _, _): return u.plan
        default: return nil
        }
    }

    // 按数据形态选择渲染:余额型(PhanRouter)或用量窗口型(Claude/GPT)。
    @ViewBuilder
    private func usageBody(_ usage: Usage) -> some View {
        if let info = usage.apiInfo {
            ProviderAPICardBody(info: info, display: display, accent: accent)
        } else if let b = usage.balance {
            BalanceCardBody(info: b, accent: accent, display: display)
        } else {
            windows(usage.windows)
            if let credits = usage.resetCredits {
                resetCreditsBody(credits)
            } else if runtime.config.fetcher == .codexWham {
                Text("重置机会暂不可用，请稍后刷新")
                    .font(.system(size: 10)).foregroundColor(Theme.subGray).padding(.top, 12)
            }
        }
    }

    private func resetCreditsBody(_ info: ResetCredits) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("额度重置机会 · 剩余 \(info.availableCount) 次")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.labelGray)
            if let count = info.applicableCount, count != info.availableCount {
                Text("当前套餐可用 \(count) 次")
            }
            if let credits = info.credits {
                ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                    Text("第 \(index + 1) 次 · " + (credit.expiresAt.map {
                        $0.formatted(.dateTime.year().month().day().hour().minute()) + " 到期"
                    } ?? "到期时间未知") + (credit.applicable ? "" : " · 当前套餐不适用"))
                }
                if credits.count != info.availableCount {
                    Text("部分到期明细暂不可用")
                }
            } else if info.availableCount > 0 {
                Text("到期明细暂不可用，请稍后刷新")
            }
        }
        .font(.system(size: 10))
        .foregroundColor(Theme.subGray)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 12)
    }

    private func windows(_ ws: [UsageWindow]) -> some View {
        let visible = ws.filter { windowIsVisible($0) }
        return VStack(alignment: .leading, spacing: 11) {
            if visible.isEmpty {
                Text("无可展示内容")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.subGray)
            }
            ForEach(visible) { w in
                let pct = min(100, max(0, w.pct))
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(w.label).font(.system(size: 11)).foregroundColor(Theme.labelGray)
                        Spacer()
                        Text("\(Int(pct.rounded()))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.barColor(pct))
                    }
                    ProgressBarView(pct: pct)
                    if display.resetCountdown, let reset = TimeFmt.resetCountdown(w.resetAt) {
                        Text(reset).font(.system(size: 10)).foregroundColor(Theme.subGray)
                    }
                }
            }
        }
    }

    private func windowIsVisible(_ window: UsageWindow) -> Bool {
        switch window.kind {
        case .fiveHour: return display.fiveHour
        case .weekly:   return display.weekly
        }
    }

    private func footerOK(_ fetchedAt: Date) -> some View {
        HStack {
            Spacer()
            Text("更新于 \(TimeFmt.hm(fetchedAt) ?? "")")
                .font(.system(size: 10)).foregroundColor(Theme.footGray)
        }
        .padding(.top, 8)
    }

    private func footerStale(_ cachedAt: Date?) -> some View {
        HStack {
            Spacer()
            Text("⚠ 刷新失败,显示上次结果" + (TimeFmt.hm(cachedAt).map { " · \($0)" } ?? ""))
                .font(.system(size: 10)).foregroundColor(Theme.amber)
                .multilineTextAlignment(.trailing)
        }
        .padding(.top, 8)
    }
}
