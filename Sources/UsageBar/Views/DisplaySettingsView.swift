import SwiftUI

struct DisplaySettingsView: View {
    @EnvironmentObject var store: UsageStore
    var showsRelayPanel = true

    // 手机中转面板：显示地址 + 二维码，供手机扫码配置。
    private var relayPanel: some View {
        let s = RelayConfigStore.loadOrCreate()
        let ipOpt = TailscaleAddress.current()
        let isDetected = ipOpt != nil
        let ip = ipOpt ?? "（未检测到 Tailscale）"
        let url = isDetected ? "http://\(ip):\(s.port)" : ip
        let payload = "{\"url\":\"http://\(ip):\(s.port)\",\"secret\":\"\(s.secret)\"}"
        return VStack(alignment: .leading, spacing: 8) {
            Text("手机中转")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Text(url)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))
                .textSelection(.enabled)
            if isDetected, let img = qrImage(payload) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 140, height: 140)
            }
            Text("手机端扫码配置（需同一 Tailscale 网络）")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.55))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CodexAccountSettingsView()

            if showsRelayPanel { relayPanel }

            AlertSettingsView()

            Text("渠道商")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(store.config.services.enumerated()), id: \.element.id) { index, cfg in
                    ServiceDisplaySettingsRow(config: cfg, index: index,
                                              count: store.config.services.count)
                }
            }
            .padding(.trailing, 2)

            if let error = store.configSaveError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("保存到 ~/.config/usage-bar/config.json")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.58))
        }
    }
}

private struct AlertSettingsView: View {
    @EnvironmentObject var store: UsageStore

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.config.alerts.enabled },
            set: { store.setAlertsEnabled($0) }
        )
    }

    private var cooldownBinding: Binding<Int> {
        Binding(
            get: { max(1, store.config.alerts.cooldownSeconds / 60) },
            set: { store.setAlertCooldownMinutes($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: enabledBinding) {
                Text("订阅号告警")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.96))
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 10) {
                // 5h 与周额度各自独立阈值 / 规则;颜色对应角标严重度(红 / 橙)。
                WindowAlertGroup(kind: .fiveHour)
                WindowAlertGroup(kind: .weekly)

                Stepper(value: cooldownBinding, in: 1...240, step: 5) {
                    Text("冷却 \(max(1, store.config.alerts.cooldownSeconds / 60)) 分钟")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.86))
                }
                .disabled(!store.config.alerts.enabled)
            }
            .opacity(store.config.alerts.enabled ? 1 : 0.55)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }
}

// 单个窗口(5 小时 / 周额度)的告警设置:开关 + 阈值 + 规则。
private struct WindowAlertGroup: View {
    @EnvironmentObject var store: UsageStore
    let kind: WindowKind

    private var wcfg: WindowAlertConfig { store.config.alerts.config(for: kind) }
    private var alertsEnabled: Bool { store.config.alerts.enabled }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.config.alerts.config(for: kind).enabled },
            set: { store.setWindowAlertEnabled(kind, enabled: $0) }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { store.config.alerts.config(for: kind).threshold },
            set: { store.setWindowAlertThreshold(kind, pct: $0) }
        )
    }

    private var ruleBinding: Binding<UsageAlertRule> {
        Binding(
            get: { store.config.alerts.config(for: kind).rule },
            set: { store.setWindowAlertRule(kind, rule: $0) }
        )
    }

    private var rowEnabled: Bool { alertsEnabled && wcfg.enabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: enabledBinding) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.severityColor(.forWindow(kind)))
                        .frame(width: 8, height: 8)
                    Text(kind.settingsTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!alertsEnabled)

            HStack {
                Text("阈值")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
                Spacer()
                Text("\(Int(wcfg.threshold.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
            Slider(value: thresholdBinding, in: 0...100, step: 5)
                .disabled(!rowEnabled)

            Picker("规则", selection: ruleBinding) {
                ForEach(UsageAlertRule.allCases) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!rowEnabled)
        }
        .opacity(rowEnabled ? 1 : 0.55)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct ServiceDisplaySettingsRow: View {
    @EnvironmentObject var store: UsageStore
    let config: ServiceConfig
    let index: Int
    let count: Int

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: {
                store.config.services.first(where: { $0.id == config.id })?.enabled ?? config.enabled
            },
            set: { store.setServiceEnabled(config.id, enabled: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: enabledBinding) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(hex: config.accent))
                            .frame(width: 8, height: 8)
                        Text(config.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(enabledBinding.wrappedValue ? 0.96 : 0.58))
                        Text(config.category.title)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(enabledBinding.wrappedValue ? 0.72 : 0.38))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.09)))
                    }
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 0)

                Button {
                    store.moveService(config.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(index == 0 ? 0.28 : 0.86))
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .help("上移")

                Button {
                    store.moveService(config.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(index == count - 1 ? 0.28 : 0.86))
                }
                .buttonStyle(.plain)
                .disabled(index == count - 1)
                .help("下移")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(DisplayContent.options(for: config)) { item in
                    Toggle(isOn: Binding(
                        get: { store.displayContentIsEnabled(item, for: config.id) },
                        set: { store.setDisplayContent(item, for: config.id, enabled: $0) }
                    )) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(enabledBinding.wrappedValue ? 0.86 : 0.42))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!enabledBinding.wrappedValue)
                }
            }
            .padding(.leading, 18)
            .opacity(enabledBinding.wrappedValue ? 1 : 0.68)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
    }
}
