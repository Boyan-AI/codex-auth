import SwiftUI

/// 提供固定状态筛选，不引入用户自定义分组。
private enum AccountStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case available = "可用"
    case cooling = "冷却"
    case error = "异常"
    case excluded = "已排除"

    var id: String { rawValue }
}

/// 在统一管理窗口中提供账号列表、详情和 sheet 操作。
struct ManageAccountsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var selectedFilter: AccountStatusFilter = .all
    @State private var selectedSortOrder: AccountSortOrder = .added
    @State private var selectedAccountID: CodexAccount.ID?
    @State private var isAddingAccount = false
    @State private var reloginAccount: CodexAccount?
    @State private var deleteAccount: CodexAccount?

    /// 允许菜单中的“添加账号”入口直接打开账号页 sheet。
    init(opensAddAccountOnAppear: Bool = false) {
        _isAddingAccount = State(initialValue: opensAddAccountOnAppear)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(filteredAccounts, selection: $selectedAccountID) { account in
                accountListRow(account)
            }
            .scrollIndicators(.hidden)
            .frame(width: 200)

            Divider()

            Group {
                if let account = selectedAccount ?? filteredAccounts.first {
                    AccountDetailView(
                        account: account,
                        onRelogin: { reloginAccount = account },
                        onDelete: { deleteAccount = account }
                    )
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .searchable(text: $searchText, prompt: "搜索账号")
        .navigationTitle("账号")
        .toolbar { accountToolbar }
        .sheet(isPresented: $isAddingAccount) {
            AccountLoginSheet(title: "添加账号", initialAlias: "") { alias in
                Task { await appState.login(alias: alias) }
            }
        }
        .sheet(item: $reloginAccount) { account in
            AccountLoginSheet(title: "重新登录", initialAlias: account.alias ?? "") { alias in
                Task { await appState.login(alias: alias) }
            }
        }
        .sheet(item: $deleteAccount) { account in
            DeleteAccountSheet(account: account) {
                appState.requestDelete(account)
                Task { await appState.confirmDelete() }
            }
        }
        .task {
            if appState.state == nil {
                await appState.refresh()
            }
        }
    }

    /// 先按搜索词和固定状态筛选，再应用账号列表的统一排序规则。
    private var filteredAccounts: [CodexAccount] {
        let accounts = appState.state?.accounts ?? []
        let filtered = accounts.filter { account in
            let matchesSearch = searchText.isEmpty ||
                [account.primaryLabel, account.secondaryLabel, account.accountKey]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(searchText)
            return matchesSearch && matchesFilter(account)
        }
        return AccountOrdering.sorted(filtered, by: selectedSortOrder)
    }

    /// 将后端状态映射到可用、冷却、异常和已排除筛选。
    private func matchesFilter(_ account: CodexAccount) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .available:
            return account.participatesInSmartPool && account.isAvailable
        case .cooling:
            let status = account.usage.sevenDay.status.lowercased()
            return status.contains("429") || status.contains("quota")
        case .error:
            return account.participatesInSmartPool && !account.isAvailable
        case .excluded:
            return !account.participatesInSmartPool
        }
    }

    /// 显示账号身份和紧凑额度摘要。
    private func accountListRow(_ account: CodexAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(account.primaryLabel)
                    .lineLimit(1)
                Spacer()
                if account.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(account.isAvailable ? Color.accentColor : Color.red)
                }
            }
            Text(account.secondaryLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(accountListUsage(account))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .tag(account.id)
    }

    /// 合并列表中实际存在的 5 小时额度和 7 天额度。
    private func accountListUsage(_ account: CodexAccount) -> String {
        var parts: [String] = []
        if let fiveHour = account.usage.fiveHour {
            parts.append("5h \(fiveHour.displayText)")
        }
        parts.append("7d \(account.usage.sevenDay.displayText)")
        return parts.joined(separator: " · ")
    }

    /// 账号页工具栏提供排序、固定筛选、刷新和添加。
    @ToolbarContentBuilder
    private var accountToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("排序", selection: $selectedSortOrder) {
                ForEach(AccountSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)

            Picker("状态", selection: $selectedFilter) {
                ForEach(AccountStatusFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)

            Button {
                Task { await appState.refreshOnMenuOpen() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            Button {
                isAddingAccount = true
            } label: {
                Label("添加", systemImage: "plus")
            }
        }
    }

    private var selectedAccount: CodexAccount? {
        guard let selectedAccountID else { return nil }
        return filteredAccounts.first { $0.id == selectedAccountID }
    }

    /// 无账号或筛选无结果时保持简洁空状态。
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("没有匹配账号")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 展示单个账号额度、智能池状态、别名和低频操作。
private struct AccountDetailView: View {
    @EnvironmentObject private var appState: AppState
    let account: CodexAccount
    let onRelogin: () -> Void
    let onDelete: () -> Void
    @State private var aliasText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileHeader
                quotaGrid
                Divider()
                routingControls
                aliasEditor
                actionFooter
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { aliasText = account.alias ?? "" }
        .onChange(of: account.accountKey) { _ in aliasText = account.alias ?? "" }
        .onChange(of: account.alias ?? "") { aliasText = $0 }
    }

    /// 展示别名、脱敏邮箱和套餐。
    private var profileHeader: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 48, height: 48)
                .overlay {
                    Text(String(account.primaryLabel.prefix(1)).uppercased())
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(account.primaryLabel)
                        .font(.title2.weight(.semibold))
                    Text(account.planLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(account.secondaryLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 仅展示实际存在的 5 小时窗口，并始终展示 7 天和重置机会。
    private var quotaGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
            if let fiveHour = account.usage.fiveHour {
                GridRow { Text("5 小时"); Text(fiveHour.displayTextWithReset) }
            }
            GridRow { Text("7 天"); Text(account.usage.sevenDay.displayTextWithReset) }
            GridRow {
                Text("重置机会")
                Text(account.resetCredits?.accountDetailText ?? "查询失败")
            }
        }
    }

    /// 分离官方直连选择和 CPA 智能池成员开关。
    private var routingControls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("直连账号")
                Spacer()
                Button(account.isActive ? "当前账号" : "设为当前") {
                    Task { await appState.switchAccount(accountKey: account.accountKey) }
                }
                .disabled(account.isActive || appState.isLoading)
            }
            Toggle(
                "加入智能路由",
                isOn: Binding(
                    get: { account.participatesInSmartPool },
                    set: { enabled in
                        Task { await appState.setSmartPoolEnabled(accountKey: account.accountKey, enabled: enabled) }
                    }
                )
            )
            .disabled(appState.isLoading)
        }
    }

    /// 在详情页编辑别名，空值由单独的清除操作处理。
    private var aliasEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("别名")
                .font(.headline)
            HStack {
                TextField("输入别名", text: $aliasText)
                    .textFieldStyle(.roundedBorder)
                Button("保存") {
                    Task { await appState.setAlias(accountKey: account.accountKey, alias: aliasText) }
                }
                .disabled(aliasText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("清除") {
                    Task { await appState.clearAlias(accountKey: account.accountKey) }
                }
            }
        }
    }

    /// 将重新登录和删除保留为低频 sheet 操作。
    private var actionFooter: some View {
        HStack {
            Text(account.lastRefreshAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未刷新")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("重新登录", action: onRelogin)
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

/// 添加账号窗口和重新登录 sheet 共用的轻量表单。
struct AccountLoginForm: View {
    let title: String
    let onCancel: () -> Void
    let onConfirm: (String?) -> Void
    @State private var alias: String

    init(
        title: String,
        initialAlias: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String?) -> Void
    ) {
        self.title = title
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _alias = State(initialValue: initialAlias)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            TextField("账号别名（可选）", text: $alias)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("继续登录") {
                    let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    onConfirm(value.isEmpty ? nil : value)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420, height: 170)
    }
}

/// 为管理页 sheet 适配共享登录表单的关闭行为。
private struct AccountLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initialAlias: String
    let onConfirm: (String?) -> Void

    var body: some View {
        AccountLoginForm(
            title: title,
            initialAlias: initialAlias,
            onCancel: { dismiss() },
            onConfirm: { alias in
                dismiss()
                onConfirm(alias)
            }
        )
    }
}

/// 使用 sheet 明确确认账号删除范围。
private struct DeleteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: CodexAccount
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("删除账号")
                .font(.title2.weight(.semibold))
            Text("确定删除“\(account.primaryLabel)”及其直连快照吗？")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("删除", role: .destructive) {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420, height: 170)
    }
}
