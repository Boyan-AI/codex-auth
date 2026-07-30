import SwiftUI

/// 精简菜单栏主界面，仅保留智能启动、账号直连选择和高频入口。
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    var closeMenu: @MainActor () -> Void = {}
    var openManagement: @MainActor (ManagementSection) -> Void = { _ in }
    @State private var isShowingTokenUsage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            smartLaunch
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

    /// 顶部展示 CPA 短状态、今日消耗和明确的全量刷新入口。
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Auth")
                    .font(.system(size: 20, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(cpaStatusColor)
                        .frame(width: 7, height: 7)
                    Text(appState.cpaConnectionStatus.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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

    /// 主按钮始终通过 CPA 启动官方 Codex CLI，不提供静默直连回退。
    private var smartLaunch: some View {
        VStack(spacing: 6) {
            Button {
                openCodexSessionAfterChoosingDirectory()
            } label: {
                Text("智能启动 Codex")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            Text("\(availableSmartAccountCount) / \(smartPoolAccountCount) 个账号可用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 当前直连账号优先，其余账号按可用、异常、已排除排序。
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
                    ForEach(sortedAccounts) { account in
                        AccountRow(account: account)
                    }
                }
            }
            .frame(maxHeight: 430)
        }
    }

    /// 底部只保留五个稳定入口，账号编辑和设置都在独立管理窗口中完成。
    private var footer: some View {
        HStack(spacing: 4) {
            footerButton("账号", systemImage: "plus", section: .addAccount)
            footerButton("管理", systemImage: "person.2", section: .accounts)
            footerButton("统计", systemImage: "chart.bar", section: .usage)
            footerButton("设置", systemImage: "gearshape", section: .settings)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
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

    /// 统一底部入口的紧凑图标与文字样式。
    private func footerLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.callout)
            Text(title)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// 根据连接状态映射菜单中的单点颜色。
    private var cpaStatusColor: Color {
        switch appState.cpaConnectionStatus {
        case .connected:
            return .orange
        case .unavailable:
            return .red
        case .unknown, .notConfigured:
            return .secondary
        }
    }

    private var sortedAccounts: [CodexAccount] {
        (appState.state?.accounts ?? []).sorted { left, right in
            let leftRank = accountSortRank(left)
            let rightRank = accountSortRank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.primaryLabel.localizedCaseInsensitiveCompare(right.primaryLabel) == .orderedAscending
        }
    }

    /// 当前选择、可用、异常、已排除依次排序。
    private func accountSortRank(_ account: CodexAccount) -> Int {
        if account.isActive { return 0 }
        if !account.participatesInSmartPool { return 3 }
        return account.isAvailable ? 1 : 2
    }

    private var smartPoolAccountCount: Int {
        (appState.state?.accounts ?? []).filter(\.participatesInSmartPool).count
    }

    private var availableSmartAccountCount: Int {
        (appState.state?.accounts ?? []).filter { $0.participatesInSmartPool && $0.isAvailable }.count
    }

    /// 关闭菜单后选择目录，并把目录交给 CPA 智能启动流程。
    @MainActor
    private func openCodexSessionAfterChoosingDirectory() {
        CodexSessionMenuAction(
            closeMenu: closeMenu,
            chooseDirectory: CodexDirectoryPicker.chooseDirectory,
            openSession: { directoryPath in
                Task { await appState.openNewCodexSession(at: directoryPath) }
            }
        ).run()
    }
}
