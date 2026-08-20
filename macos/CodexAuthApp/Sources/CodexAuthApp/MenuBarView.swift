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
    }

    /// 在菜单栏弹窗内部展示退出确认，避免系统 confirmationDialog 阻塞无窗口 App。
    private var quitConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("退出 Codex Auth？")
                .font(.headline)
            Text("退出前将停止 NewAPI 与 CPA。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    isShowingQuitConfirmation = false
                }
                .buttonStyle(.bordered)
                Button("确认退出", role: .destructive) {
                    // 先执行统一清理，最多等待三秒；服务异常时仍保证菜单栏 App 能退出。
                    Task { @MainActor in
                        let cleanup = Task { @MainActor in await appState.shutdown(publishRouteState: false) }
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        cleanup.cancel()
                        Darwin.exit(0)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
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
                    Text(appState.isNewAPIEnabled ? appState.newAPIServiceStatus.menuBarText : "手动直连")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// 直连模式只保留统一自动连接入口。
    private var directControls: some View {
        HStack(spacing: 12) {
            Text("自动连接")
                .frame(width: 100, alignment: .leading)
            Toggle(
                "",
                isOn: Binding(
                    get: { appState.isNewAPIEnabled },
                    set: { enabled in Task { await appState.setNewAPIEnabled(enabled) } }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(appState.isNewAPIOperationInProgress || appState.isCPAOperationInProgress || appState.isAccountSwitchInProgress)
        }
        .frame(minHeight: 32)
    }

    /// NewAPI 模式展示总开关、两个独立服务开关、管理入口和退出入口。
    private var newAPIControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("自动连接")
                    .frame(width: 100, alignment: .leading)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { appState.isNewAPIEnabled },
                        set: { enabled in Task { await appState.setNewAPIEnabled(enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(appState.isNewAPIOperationInProgress || appState.isCPAOperationInProgress || appState.isAccountSwitchInProgress)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("NewAPI")
                    .frame(width: 100, alignment: .leading)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { appState.isNewAPIEnabled },
                        set: { enabled in Task { await appState.setNewAPIEnabled(enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(appState.isNewAPIOperationInProgress || appState.isCPAOperationInProgress)

                Button {
                    closeMenu()
                    Task { await appState.openNewAPIManagementPage() }
                } label: {
                    Label("管理 NewAPI", systemImage: "safari")
                }
                .disabled(appState.newAPIServiceStatus == .notInstalled || appState.isNewAPIOperationInProgress)
            }

            HStack(spacing: 8) {
                Text("CPA")
                    .frame(width: 100, alignment: .leading)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { appState.isCPAServiceEnabled },
                        set: { enabled in Task { await appState.setCPAServiceEnabled(enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(appState.isNewAPIOperationInProgress || appState.isCPAOperationInProgress)

                Button {
                    closeMenu()
                    Task { await appState.openCPAManagementPage() }
                } label: {
                    Label("管理 CPA", systemImage: "network")
                }
                .disabled(appState.cpaServiceStatus != .running || appState.isNewAPIOperationInProgress)
            }

            HStack {
                Spacer()

                Button {
                    isShowingQuitConfirmation = true
                } label: {
                    Label("退出", systemImage: "power")
                }
                .popover(isPresented: $isShowingQuitConfirmation, arrowEdge: .top) {
                    quitConfirmation
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 96)
    }

    /// 将排序、今日消耗和额度与 Token 刷新合并为一行高频控制。
    private var accountControls: some View {
        HStack(spacing: 10) {
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
            .popover(isPresented: $isShowingQuitConfirmation, arrowEdge: .top) {
                quitConfirmation
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
