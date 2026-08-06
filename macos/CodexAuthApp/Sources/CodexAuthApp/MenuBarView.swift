import AppKit
import SwiftUI

/// 精简菜单栏主界面，提供全局 CPA 服务控制和备用直连账号选择。
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    var closeMenu: @MainActor () -> Void = {}
    var openManagement: @MainActor (ManagementSection) -> Void = { _ in }
    @State private var isShowingTokenUsage = false
    @State private var selectedSortOrder: AccountSortOrder = .added

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            cpaControls
            accountControls
            accountList
            footer
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    /// 展示产品名和当前服务状态。
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Auth")
                    .font(.system(size: 20, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(cpaStatusColor)
                        .frame(width: 7, height: 7)
                    Text(appState.cpaServiceStatus.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// 提供稳定尺寸的 CPA 全局开关和原生管理页入口。
    private var cpaControls: some View {
        HStack(spacing: 12) {
            Toggle(
                "CPA 全局路由",
                isOn: Binding(
                    get: { appState.isCPAEnabled },
                    set: { enabled in Task { await appState.setCPAEnabled(enabled) } }
                )
            )
            .toggleStyle(.switch)
            .disabled(appState.isCPAOperationInProgress || appState.isAccountSwitchInProgress)

            Spacer()

            Button {
                appState.copyCPAManagementKey()
            } label: {
                Label("复制密钥", systemImage: "doc.on.doc")
            }
            .disabled(appState.cpaServiceStatus == .notInstalled || appState.isCPAOperationInProgress)
            .help("复制 CPA 管理密钥")

            Button {
                closeMenu()
                Task { await appState.openCPAManagementPage() }
            } label: {
                Label("管理 CPA", systemImage: "safari")
            }
            .disabled(appState.cpaServiceStatus != .running || appState.isCPAOperationInProgress)
        }
        .frame(minHeight: 32)
    }

    /// 将排序、今日消耗和全量刷新合并为一行高频控制。
    private var accountControls: some View {
        HStack(spacing: 10) {
            Text(appState.isCPAEnabled ? "关闭 CPA 后使用" : "当前直连账号")
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
                Task { await appState.refreshOnMenuOpen() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("全量刷新")
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
            Button { NSApplication.shared.terminate(nil) } label: {
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

    /// 根据服务状态映射状态点颜色。
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
