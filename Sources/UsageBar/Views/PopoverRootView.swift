import SwiftUI
import UniformTypeIdentifiers

struct PopoverRootView: View {
    @EnvironmentObject var store: UsageStore
    @State private var showingSettings = false
    @State private var draggedCard: String?
    @State private var dragToken: String?
    @State private var dropTarget: String?
    private let dragType = UTType.data
    var availableHeight: CGFloat = 680
    var showsRelayPanel = true

    init(availableHeight: CGFloat = 680, showsRelayPanel: Bool = true, initiallyShowingSettings: Bool = false) {
        self.availableHeight = availableHeight
        self.showsRelayPanel = showsRelayPanel
        _showingSettings = State(initialValue: initiallyShowingSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showingSettings {
                        DisplaySettingsView(showsRelayPanel: showsRelayPanel)
                    } else {
                        if store.states.isEmpty {
                            Text("未选择任何渠道商")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.subGray)
                        }
                        ForEach(store.states) { rt in
                            ServiceCardView(runtime: rt, refreshing: store.refreshingServiceIDs.contains(rt.id),
                                            refreshEnabled: store.canRefreshService(rt.id),
                                            onRefresh: { Task { await store.refreshService(rt.id) } },
                                            dragProvider: {
                                let token = UUID().uuidString
                                draggedCard = rt.id
                                dragToken = token
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: dragType.identifier, visibility: .ownProcess) { completion in
                                    completion(Data(token.utf8), nil)
                                    return nil
                                }
                                return provider
                            })
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(dropTarget == rt.id && draggedCard != rt.id ? Color.accentColor : .clear, lineWidth: 2))
                            .onDrop(of: [dragType], isTargeted: Binding(
                                get: { dropTarget == rt.id },
                                set: { if $0 { dropTarget = rt.id } else if dropTarget == rt.id { dropTarget = nil } }
                            )) { providers in
                                guard let provider = providers.first, let source = draggedCard,
                                      let token = dragToken else { return false }
                                // Own-process data and a per-drag token reject external payloads and stale sessions.
                                provider.loadDataRepresentation(forTypeIdentifier: dragType.identifier) { data, _ in
                                    Task { @MainActor in
                                        guard dragToken == token else { return }
                                        draggedCard = nil
                                        dragToken = nil
                                        dropTarget = nil
                                        guard data == Data(token.utf8) else { return }
                                        store.moveCard(source, to: rt.id)
                                    }
                                }
                                return true
                            }
                            .contextMenu {
                                Button("上移") { store.moveCard(rt.id, by: -1) }
                                    .disabled(store.states.first?.id == rt.id)
                                Button("下移") { store.moveCard(rt.id, by: 1) }
                                    .disabled(store.states.last?.id == rt.id)
                            }
                            .accessibilityAction(named: "上移") { store.moveCard(rt.id, by: -1) }
                            .accessibilityAction(named: "下移") { store.moveCard(rt.id, by: 1) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
            }
            if !showingSettings {
                if let error = store.configSaveError {
                    Text(error).font(.system(size: 10)).foregroundColor(Theme.red)
                }
                footer
            }
        }
        .padding(16)
        .frame(width: 360, height: min(680, availableHeight))
        .background(VisualEffectBackground())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Text(showingSettings ? "显示设置" : "订阅用量")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button {
                showingSettings.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showingSettings ? "checkmark" : "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                    Text(showingSettings ? "完成" : "设置")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.88))
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-toggle")
            .help(showingSettings ? "完成" : "显示设置")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let updated = TimeFmt.hm(store.lastUpdated) {
                Text("更新于 \(updated)")
                    .font(.system(size: 10)).foregroundColor(Theme.footGray)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                HStack(spacing: 4) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    Text(store.isRefreshing ? "刷新中" : "刷新").font(.system(size: 11))
                }
                .foregroundColor(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.subGray)
            }
            .buttonStyle(.plain)
            .help("退出")
        }
        .padding(.top, 2)
    }
}

// 半透明毛玻璃背景。
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
