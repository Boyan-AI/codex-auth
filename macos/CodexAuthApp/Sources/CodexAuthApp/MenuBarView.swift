import AppKit
import SwiftUI

/// 菜单栏主界面按直连/NewAPI 两种产品模式收敛可见操作。
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    var closeMenu: @MainActor () -> Void = {}
    var openManagement: @MainActor (ManagementSection) -> Void = { _ in }
    @State private var isShowingTokenUsage = false
    @State private var selectedSortOrder: AccountSortOrder = .added
    @State private var isShowingDisableConfirmation = false
    @State private var isShowingQuitConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if appState.isNewAPIEnabled {
                newAPIControls
                newAPIFooter
            } else {
                directControls
                accountControls
                accountList
                footer
            }
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 420)
        .confirmationDialog(
            "关闭 NewAPI？",
            isPresented: $isShowingDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("关闭 NewAPI", role: .destructive) {
                Task { await appState.setNewAPIEnabled(false) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将先恢复直连，再停止 NewAPI 和 CPA。")
        }
        .confirmationDialog(
            "退出 Codex Auth？",
            isPresented: $isShowingQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出并停止服务", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出前会恢复直连，并停止 NewAPI 与 CPA 以节约本机资源。")
        }
    }

    /// 展示产品名、当前模式和可读服务状态。
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Auth")
                    .font(.system(size: 20, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(modeStatusColor)
                        .frame(width: 7, height: 7)
                    Text(appState.isNewAPIEnabled ? appState.newAPIServiceStatus.menuBarText : "直连")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// 直连模式只保留一个开启 NewAPI 的入口，不暴露 CPA 全局路由。
    private var directControls: some View {
        HStack(spacing: 12) {
            Toggle(
                "开启 NewAPI",
                isOn: Binding(
                    get: { appState.isNewAPIEnabled },
                    set: { enabled in Task { await appState.setNewAPIEnabled(enabled) } }
                )
            )
            .toggleStyle(.switch)
            .disabled(appState.isNewAPIOperationInProgress || appState.isCPAOperationInProgress || appState.isAccountSwitchInProgress)

            Spacer()
            Text("当前直连")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 32)
    }

    /// NewAPI 模式只显示统一出口和两个上游管理网页入口。
    private var newAPIControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(
                    "NewAPI 统一出口",
                    isOn: Binding(
                        get: { appState.isNewAPIEnabled },
                        set: { enabled in Task { await appState.setNewAPIEnabled(enabled) } }
                    )
                )
                .toggleStyle(.switch)
                .disabled(appState.isNewAPIOperationInProgress || appState.isAccountSwitchInProgress)
                Spacer()
                Text(appState.newAPIServiceStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("CPA 上游")
                    .font(.caption.weight(.medium))
                Circle()
                    .fill(cpaStatusColor)
                    .frame(width: 7, height: 7)
                Text(appState.cpaServiceStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    closeMenu()
                    Task { await appState.openNewAPIManagementPage() }
                } label: {
                    Label("管理 NewAPI", systemImage: "safari")
                }
                .disabled(appState.newAPIServiceStatus == .notInstalled || appState.isNewAPIOperationInProgress)

                Button {
                    closeMenu()
                    Task { await appState.openCPAManagementPage() }
                } label: {
                    Label("管理 CPA", systemImage: "network")
                }
                .disabled(appState.cpaServiceStatus != .running || appState.isNewAPIOperationInProgress)
            }
        }
        .frame(minHeight: 64)
    }

    /// NewAPI 模式的底部只保留关闭和退出，避免混入账号管理动作。
    private var newAPIFooter: some View {
        HStack(spacing: 8) {
            Button {
                isShowingDisableConfirmation = true
            } label: {
                Label("关闭", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .disabled(appState.isNewAPIOperationInProgress)

            Spacer()

            Button {
                isShowingQuitConfirmation = true
            } label: {
                Label("退出", systemImage: "power")
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 32)
    }

    /// 将排序、今日消耗和额度与 Token 刷新合并为一行高频控制。
    private var accountControls: some View {
        HStack(spacing: 10) {
            Text(appState.isNewAPIEnabled || appState.isCPAEnabled ? "关闭统一出口后使用" : "当前直连账号")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Picker("排序", selection: $selectedSortOrder) {
                ForEach(AccountSortOrder.allCases) { order in Text(order.rawValue).tag(order) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            Spacer()

            Button("今日 \(appState.tokenUsage?.todayTotalText ?? "--")") {
                isShowingTokenUsage.toggle()
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .popover(isPresented: $isShowingTokenUsage, arrowEdge: .top) {
                TokenUsageView(info: appState.tokenUsage, compact: true)
            }

            Button {
                Task { await appState.refreshUsage() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("刷新额度与 Token")
        }
    }

    /// 展示最多约四个账号高度的备用直连列表。
    @ViewBuilder
    private var accountList: some View {
        if appState.isLoading && appState.state == nil {
            ProgressView("正在加载账号…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if sortedAccounts.isEmpty {
            Text("没有已保存的账号")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sortedAccounts) { account in AccountRow(account: account) }
                }
                .background(ScrollIndicatorHider())
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 350)
        }
    }

    /// 保留账号、管理、统计、设置和退出入口。
    private var footer: some View {
        HStack(spacing: 4) {
            footerButton("账号", systemImage: "plus", section: .addAccount)
            footerButton("管理", systemImage: "person.2", section: .accounts)
            footerButton("统计", systemImage: "chart.bar", section: .usage)
            footerButton("设置", systemImage: "gearshape", section: .settings)
            Button { isShowingQuitConfirmation = true } label: {
                footerLabel("退出", systemImage: "power")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// 构造打开统一管理窗口的底部按钮。
    private func footerButton(_ title: String, systemImage: String, section: ManagementSection) -> some View {
        Button {
            closeMenu()
            openManagement(section)
        } label: {
            footerLabel(title, systemImage: systemImage)
        }
        .frame(maxWidth: .infinity)
    }

    /// 统一底部入口的图标与文字样式。
    private func footerLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage).font(.callout)
            Text(title).font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// 根据当前产品模式映射收起菜单栏状态点颜色。
    private var modeStatusColor: Color {
        appState.isNewAPIEnabled ? newAPIStatusColor : .secondary
    }

    /// 根据 NewAPI 服务状态映射状态点颜色。
    private var newAPIStatusColor: Color {
        switch appState.newAPIServiceStatus {
        case .running: return .green
        case .starting, .setupRequired, .tokenRequired: return .orange
        case .unknown, .notInstalled, .stopped, .tokenInvalid, .unavailable, .incompatible: return .secondary
        }
    }

    /// 根据 CPA 上游状态映射状态点颜色。
    private var cpaStatusColor: Color {
        switch appState.cpaServiceStatus {
        case .running: return .green
        case .starting: return .orange
        case .unavailable, .incompatible: return .red
        case .unknown, .notInstalled, .stopped: return .secondary
        }
    }

    private var sortedAccounts: [CodexAccount] {
        AccountOrdering.sorted(appState.state?.accounts ?? [], by: selectedSortOrder)
    }
}

/// 从 SwiftUI 内容层定位底层 NSScrollView，覆盖系统滚动条偏好。
private struct ScrollIndicatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    /// 每次更新后关闭滚动条，保持菜单宽度稳定。
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else { return }
            scrollView.hasVerticalScroller = false
            scrollView.verticalScroller?.isHidden = true
            scrollView.autohidesScrollers = true
        }
    }
}
