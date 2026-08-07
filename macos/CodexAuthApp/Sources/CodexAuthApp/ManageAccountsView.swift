import SwiftUI

/// 提供固定状态筛选，不引入用户自定义分组。
private enum AccountStatusFilter: String, CaseIterable, Identifiable {
    case all = "现有"
    case available = "可用"
    case cooling = "冷却"
    case error = "异常"
    case deleted = "已删除"

    var id: String { rawValue }
}

/// 统一连接列表的认证类型筛选。
private enum ConnectionTypeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case chatgpt = "账号"
    case apikey = "Key"

    var id: String { rawValue }
}

/// 在统一管理窗口中提供账号列表、详情和 sheet 操作。
struct ManageAccountsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var selectedFilter: AccountStatusFilter = .all
    @State private var selectedType: ConnectionTypeFilter = .all
    @State private var selectedSortOrder: AccountSortOrder = .added
    @State private var selectedAccountID: CodexAccount.ID?
    @State private var isAddingAccount = false
    @State private var reconnectAction: ConnectionReconnectAction?
    @State private var deleteAccount: CodexAccount?

    /// 允许菜单中的“添加账号”入口直接打开账号页 sheet。
    init(opensAddAccountOnAppear: Bool = false) {
        _isAddingAccount = State(initialValue: opensAddAccountOnAppear)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedAccountID) {
                if selectedFilter == .deleted {
                    ForEach(filteredDeletedAccounts) { record in
                        deletedConnectionListRow(record)
                            .tag(record.id)
                    }
                } else {
                    ForEach(filteredAccounts) { account in
                        accountListRow(account)
                            .tag(account.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(width: 200)

            Divider()

            Group {
                if selectedFilter == .deleted, let record = selectedDeletedConnection ?? filteredDeletedAccounts.first {
                    DeletedConnectionDetailView(record: record)
                } else if selectedFilter == .deleted {
                    deletedEmptyState
                } else if let account = selectedAccount ?? filteredAccounts.first {
                    AccountDetailView(
                        account: account,
                        onReconnect: { reconnectAction = ConnectionReconnectAction(account: account) },
                        onDelete: { deleteAccount = account }
                    )
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .searchable(text: $searchText, prompt: "搜索账号或 Key")
        .navigationTitle("连接")
        .toolbar { accountToolbar }
        .sheet(isPresented: $isAddingAccount) {
            AddConnectionSheet()
        }
        .sheet(item: $reconnectAction) { action in
            switch action {
            case .account(let account):
                AccountLoginSheet(title: "重新登录", initialAlias: account.alias ?? "") { alias in
                    Task { await appState.login(alias: alias) }
                }
            case .apiKey(let account):
                AddConnectionSheet(configuration: .readdingAPIKey(for: account))
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
        guard selectedFilter != .deleted else { return [] }
        let accounts = appState.state?.accounts ?? []
        let filtered = accounts.filter { account in
            let matchesSearch = searchText.isEmpty ||
                [account.primaryLabel, account.secondaryLabel, account.accountKey]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(searchText)
            return matchesSearch && matchesType(account) && matchesFilter(account)
        }
        return AccountOrdering.sorted(filtered, by: selectedSortOrder)
    }

    /// 在已删除筛选中按名称、脱敏详情和连接类型匹配历史记录。
    private var filteredDeletedAccounts: [DeletedAccountRecord] {
        guard selectedFilter == .deleted else { return [] }
        return appState.deletedAccounts.filter { record in
            searchText.isEmpty || [
                record.label,
                record.detail,
                record.resolvedConnectionType == .apiKey ? "API Key" : "ChatGPT 账号",
            ]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 按统一连接模型筛选账号或 API Key。
    private func matchesType(_ account: CodexAccount) -> Bool {
        switch selectedType {
        case .all: return true
        case .chatgpt: return !account.isAPIKey
        case .apikey: return account.isAPIKey
        }
    }

    /// 将后端状态映射到可用、冷却、异常和已排除筛选。
    private func matchesFilter(_ account: CodexAccount) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .available:
            return account.isAvailable
        case .cooling:
            let status = account.usage.sevenDay.status.lowercased()
            return status.contains("429") || status.contains("quota")
        case .error:
            return !account.isAvailable
        case .deleted:
            return false
        }
    }

    /// 显示账号身份和紧凑额度摘要。
    private func accountListRow(_ account: CodexAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(account.primaryLabel)
                    .lineLimit(1)
                Spacer()
            }
            Text(account.secondaryLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(accountListUsage(account))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 已删除列表行只展示脱敏身份和连接类型。
    private func deletedConnectionListRow(_ record: DeletedAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.label)
                .lineLimit(1)
            Text(record.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(record.resolvedConnectionType == .apiKey ? "API Key" : "ChatGPT 账号")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 合并列表中实际存在的 5 小时额度和 7 天额度。
    private func accountListUsage(_ account: CodexAccount) -> String {
        if account.isAPIKey {
            return account.balanceText.map { "余额 \($0)" } ?? "API Key"
        }
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

            Picker("类型", selection: $selectedType) {
                ForEach(ConnectionTypeFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
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

    /// 返回当前选中的已删除记录。
    private var selectedDeletedConnection: DeletedAccountRecord? {
        guard let selectedAccountID else { return nil }
        return filteredDeletedAccounts.first { $0.id == selectedAccountID }
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

    /// 已删除筛选无记录或搜索无结果时显示只读空状态。
    private var deletedEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "archivebox")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("没有已删除连接")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 在管理页右侧展示已删除连接的只读信息，不提供恢复或密钥查看能力。
private struct DeletedConnectionDetailView: View {
    let record: DeletedAccountRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: record.resolvedConnectionType == .apiKey ? "key.slash" : "person.crop.circle.badge.xmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.label)
                        .font(.title2.weight(.semibold))
                    Text(record.detail)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow {
                    Text("连接类型")
                    Text(record.resolvedConnectionType == .apiKey ? "API Key" : "ChatGPT 账号")
                }
                GridRow {
                    Text("删除时间")
                    Text(record.deletedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Text("这里只保留脱敏记录，不保存 Key 原文，也不提供恢复操作。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 统一添加入口，根据连接类型展示账号登录或 API Key 表单。
private struct AddConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let configuration: ConnectionFormConfiguration

    /// 默认保持统一添加入口；重新添加 Key 时由调用方传入 Key-only 配置。
    init(configuration: ConnectionFormConfiguration = .adding) {
        self.configuration = configuration
    }

    var body: some View {
        AddConnectionForm(
            configuration: configuration,
            onCancel: { dismiss() },
            onAccount: { alias in
                dismiss()
                Task { await appState.login(alias: alias) }
            },
            onAPIKey: { alias, provider, baseURL, apiKey in
                dismiss()
                Task { await appState.addAPIKey(alias: alias, provider: provider, baseURL: baseURL, apiKey: apiKey) }
            }
        )
    }
}

/// 为管理页 sheet 和独立添加窗口提供一致的连接类型表单。
struct AddConnectionForm: View {
    let configuration: ConnectionFormConfiguration
    let onCancel: () -> Void
    let onAccount: (String?) -> Void
    let onAPIKey: (String, APIKeyProvider, String, String) -> Void
    @State private var connectionType: ConnectionFormType
    @State private var alias: String
    @State private var provider: APIKeyProvider
    @State private var baseURL: String
    @State private var apiKey: String

    /// 按配置初始化统一表单；重新添加 Key 时只接收非敏感默认值。
    init(
        configuration: ConnectionFormConfiguration = .adding,
        onCancel: @escaping () -> Void,
        onAccount: @escaping (String?) -> Void,
        onAPIKey: @escaping (String, APIKeyProvider, String, String) -> Void
    ) {
        self.configuration = configuration
        self.onCancel = onCancel
        self.onAccount = onAccount
        self.onAPIKey = onAPIKey
        _connectionType = State(initialValue: configuration.initialType)
        _alias = State(initialValue: configuration.initialAlias)
        _provider = State(initialValue: configuration.initialProvider)
        _baseURL = State(initialValue: configuration.initialBaseURL)
        _apiKey = State(initialValue: configuration.initialAPIKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(configuration.title)
                .font(.title2.weight(.semibold))
            if configuration.allowsTypeSelection {
                Picker("连接类型", selection: $connectionType) {
                    Text("ChatGPT 账号").tag(ConnectionFormType.account)
                    Text("API Key").tag(ConnectionFormType.apiKey)
                }
                .pickerStyle(.segmented)
            }

            TextField("名称（可选）", text: $alias)
                .textFieldStyle(.roundedBorder)

            if connectionType == .apiKey {
                Picker("服务商", selection: $provider) {
                    ForEach(APIKeyProvider.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .onChange(of: provider) { value in baseURL = value.defaultBaseURL }
                TextField("Base URL", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .disabled(provider == .openai)
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Text("余额仅在服务商支持且查询成功时显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button(connectionType == .account ? "继续登录" : "添加 Key") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(connectionType == .apiKey && !isKeyFormValid)
            }
        }
        .padding(24)
        .frame(width: 460, height: connectionType == .account ? 220 : 300)
    }

    /// 校验 Key 表单的最小必填字段，后端继续负责安全 URL 校验。
    private var isKeyFormValid: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 关闭表单后触发对应的异步添加流程。
    private func submit() {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if connectionType == .account {
            onAccount(trimmedAlias.isEmpty ? nil : trimmedAlias)
        } else {
            onAPIKey(
                trimmedAlias,
                provider,
                baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

/// 展示单个直连账号的额度、选择状态、别名和低频操作。
private struct AccountDetailView: View {
    @EnvironmentObject private var appState: AppState
    let account: CodexAccount
    let onReconnect: () -> Void
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
            if account.isAPIKey {
                if let balance = account.balanceText {
                    GridRow { Text("余额"); Text(balance).foregroundStyle(.green) }
                }
                if let baseURL = account.baseURL {
                    GridRow { Text("API 地址"); Text(baseURL).foregroundStyle(.secondary) }
                }
            } else if let fiveHour = account.usage.fiveHour {
                GridRow { Text("5 小时"); Text(fiveHour.displayTextWithReset) }
                GridRow { Text("7 天"); Text(account.usage.sevenDay.displayTextWithReset) }
                GridRow {
                    Text("重置机会")
                    Text(account.resetCredits?.accountDetailText ?? "查询失败")
                }
            } else {
                GridRow { Text("7 天"); Text(account.usage.sevenDay.displayTextWithReset) }
            }
        }
    }

    /// 选择关闭 CPA 后使用的直连连接。
    private var routingControls: some View {
        HStack {
            Text(appState.isCPAEnabled ? "关闭 CPA 后使用" : (account.isAPIKey ? "直连 Key" : "直连账号"))
            Spacer()
            Button(account.isActive ? "当前账号" : "设为当前") {
                Task { await appState.switchAccount(accountKey: account.accountKey) }
            }
            .disabled(
                account.isActive
                    || appState.isAccountSwitchInProgress
                    || appState.isCPAOperationInProgress
            )
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

    /// 按连接类型提供重新登录或重新添加 Key，并保留删除操作。
    private var actionFooter: some View {
        HStack {
            Text(account.lastRefreshAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未刷新")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(ConnectionReconnectAction(account: account).buttonTitle, action: onReconnect)
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
