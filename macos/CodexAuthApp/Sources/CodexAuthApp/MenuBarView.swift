import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    var closeMenu: @MainActor () -> Void = {}
    @State private var isManagingAccounts = false
    @State private var isAddingAccount = false
    @State private var newAccountAlias = ""
    @State private var isShowingTokenUsage = false
    @State private var isShowingDeletedAccounts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            accountList
            Divider()
            actions
            if isAddingAccount {
                addAccountPanel
            }
            if appState.pendingDeleteAccount != nil {
                deleteConfirmationPanel
            }
            if let error = appState.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 420)
        .background {
            MenuWindowOpenObserver {
                Task {
                    await appState.refreshOnMenuOpen()
                }
            }
            .frame(width: 0, height: 0)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 账号")
                    .font(.headline)
                if let active = appState.state?.activeAccount {
                    Text(active.primaryLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else {
                    Text("暂无活动账号")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    isShowingTokenUsage.toggle()
                } label: {
                    Label(
                        "今日 \(appState.tokenUsage?.todayTotalText ?? "--")",
                        systemImage: "chart.bar.xaxis"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $isShowingTokenUsage, arrowEdge: .top) {
                    TokenUsageView(info: appState.tokenUsage)
                }

                Button {
                    Task { await appState.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("刷新")
            }
        }
    }

    @ViewBuilder
    private var accountList: some View {
        if appState.isLoading && appState.state == nil {
            ProgressView("正在加载账号...")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let accounts = appState.state?.accounts, !accounts.isEmpty {
            VStack(spacing: 8) {
                ForEach(accounts) { account in
                    AccountRow(account: account, isManaging: isManagingAccounts)
                }
            }
        } else {
            Text("没有已保存的账号")
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) {
                    isAddingAccount.toggle()
                }
            } label: {
                compactLabel("添加", systemImage: "plus.circle")
            }
            .frame(maxWidth: .infinity)

            Button {
                openCodexSessionAfterChoosingDirectory()
            } label: {
                compactLabel("会话", systemImage: "terminal")
            }
            .frame(maxWidth: .infinity)

                Button {
                    withAnimation(.snappy) {
                        isManagingAccounts.toggle()
                }
            } label: {
                Label(
                    isManagingAccounts ? "完成" : "管理",
                    systemImage: isManagingAccounts ? "checkmark.circle" : "slider.horizontal.3"
                )
                .labelStyle(.titleAndIcon)
            }
            .frame(maxWidth: .infinity)

            Button {
                isShowingDeletedAccounts.toggle()
            } label: {
                compactLabel("失效", systemImage: "archivebox")
            }
            .frame(maxWidth: .infinity)
            .popover(isPresented: $isShowingDeletedAccounts, arrowEdge: .bottom) {
                DeletedAccountsView(records: appState.deletedAccounts)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                compactLabel("退出", systemImage: "power")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func compactLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var addAccountPanel: some View {
        HStack(spacing: 8) {
            TextField("新账号别名（可选）", text: $newAccountAlias)
                .textFieldStyle(.roundedBorder)

            Button("登录") {
                let alias = newAccountAlias.trimmingCharacters(in: .whitespacesAndNewlines)
                newAccountAlias = ""
                isAddingAccount = false
                Task { await appState.login(alias: alias) }
            }
            .buttonStyle(.borderedProminent)

            Button("取消") {
                newAccountAlias = ""
                isAddingAccount = false
            }
        }
    }

    /// 在菜单窗口内确认删除，避免 macOS 菜单栏浮窗中的系统确认弹窗阻塞交互。
    private var deleteConfirmationPanel: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("确定删除此账号？")
                    .font(.footnote)
                    .fontWeight(.semibold)
                Text(appState.pendingDeleteAccount?.primaryLabel ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("取消") {
                appState.cancelDelete()
            }
            .disabled(appState.isLoading)

            Button("删除", role: .destructive) {
                Task { await appState.confirmDelete() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isLoading)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

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
