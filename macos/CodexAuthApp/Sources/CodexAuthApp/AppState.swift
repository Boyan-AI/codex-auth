import Combine
import Foundation

/// 定义刷新优先级：菜单全量刷新覆盖额度定时刷新，但保留期间到达的 Token 增量脏标记。
private enum AppRefreshWork {
    case full
    case quota
    case incrementalToken
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static let defaultPeriodicRefreshIntervalNanoseconds: UInt64 = 60_000_000_000

    @Published private(set) var state: CodexAuthState?
    @Published private(set) var tokenUsage: TokenUsageInfo?
    @Published private(set) var deletedAccounts: [DeletedAccountRecord]
    @Published private(set) var cpaConnectionStatus: CPAConnectionStatus = .unknown
    @Published private(set) var isLoading = false
    @Published private(set) var isAccountSwitchInProgress = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var pendingDeleteAccount: CodexAccount?

    private let client: CodexAuthClientProtocol
    private let usageAlertPresenter: UsageAlertPresenting
    private var usageAlertTracker = UsageAlertTracker()
    private var didRefreshOnAppLaunch = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var cpaEventPollingTask: Task<Void, Never>?
    private var refreshLoopTask: Task<Void, Never>?
    private var activeRefreshWork: AppRefreshWork?
    private var pendingFullRefresh = false
    private var pendingQuotaRefresh = false
    private var pendingIncrementalTokenRefresh = false
    private var tokenUsageGeneration = 0
    private var loadSequence = 0
    private var synchronizedCPAEligibility: [String: Bool] = [:]

    /// 注入状态客户端和低额度展示器，便于隔离系统通知并测试阈值行为。
    init(
        client: CodexAuthClientProtocol = CodexAuthCLIClient(),
        usageAlertPresenter: UsageAlertPresenting? = nil
    ) {
        self.client = client
        self.usageAlertPresenter = usageAlertPresenter ?? DisabledUsageAlertPresenter()
        self.deletedAccounts = DeletedAccountStore.load()
    }

    deinit {
        periodicRefreshTask?.cancel()
        cpaEventPollingTask?.cancel()
        refreshLoopTask?.cancel()
    }

    var isShowingDeleteConfirmation: Bool {
        pendingDeleteAccount != nil
    }

    /// 提前准备系统通知权限，避免首次低额度事件只出现授权提示。
    func prepareUsageAlerts() {
        usageAlertPresenter.prepare()
    }

    func refresh(apiMode: CodexAuthAPIMode = .automatic) async {
        await load { try await client.loadState(apiMode: apiMode) }
    }

    func refreshOnAppLaunch(apiMode: CodexAuthAPIMode = .automatic) async {
        guard !didRefreshOnAppLaunch else {
            return
        }
        didRefreshOnAppLaunch = true
        await requestRefresh(.full, apiMode: apiMode)
    }

    /// 菜单每次打开都请求全量刷新；进行中的全量请求由协调器合并。
    func refreshOnMenuOpen(apiMode: CodexAuthAPIMode = .automatic) async {
        await requestRefresh(.full, apiMode: apiMode)
    }

    func startPeriodicRefresh(
        intervalNanoseconds: UInt64 = AppState.defaultPeriodicRefreshIntervalNanoseconds,
        apiMode: CodexAuthAPIMode = .automatic
    ) {
        guard periodicRefreshTask == nil else {
            return
        }

        periodicRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                if Task.isCancelled {
                    break
                }
                await self?.refreshOnPeriodicTimer(apiMode: apiMode)
            }
        }
    }

    func refreshOnPeriodicTimer(apiMode: CodexAuthAPIMode = .automatic) async {
        await requestRefresh(.quota, apiMode: apiMode)
    }

    /// 每 5 秒消费 CPA 请求事件；空队列和暂时不可达均不干扰菜单使用。
    func startCPAEventPolling(intervalNanoseconds: UInt64 = 5_000_000_000) {
        guard cpaEventPollingTask == nil else {
            return
        }
        cpaEventPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                if Task.isCancelled {
                    break
                }
                await self?.pollCPAEventsOnce()
            }
        }
    }

    /// 执行单次 CPA 事件轮询，便于测试刷新触发逻辑。
    func pollCPAEventsOnce() async {
        guard let batch = try? await client.pollCPAEvents(), batch.eventCount > 0 else {
            return
        }
        await refreshOnCPAEvent(quotaExceeded: batch.quotaExceeded)
    }

    /// 手动额度刷新也进入同一写入队列，避免与菜单全量结果交叉覆盖。
    func refreshUsage(apiMode: CodexAuthAPIMode = .automatic) async {
        await requestRefresh(.quota, apiMode: apiMode)
    }

    /// CPA 请求事件标记增量 Token 扫描；429 额外触发权威额度刷新。
    func refreshOnCPAEvent(quotaExceeded: Bool = false) async {
        if quotaExceeded {
            await requestRefresh(.quota, apiMode: .automatic)
        }
        await requestRefresh(.incrementalToken, apiMode: .automatic)
    }

    func switchAccount(accountKey: String) async {
        guard !isAccountSwitchInProgress else {
            return
        }
        isAccountSwitchInProgress = true
        defer { isAccountSwitchInProgress = false }
        await load {
            let state = try await client.switchAccount(accountKey: accountKey)
            notice = "已切换账号。新的 Codex CLI 会话将使用此账号。"
            return state
        }
    }

    func requestDelete(_ account: CodexAccount) {
        pendingDeleteAccount = account
    }

    func cancelDelete() {
        pendingDeleteAccount = nil
    }

    func confirmDelete() async {
        guard let account = pendingDeleteAccount else {
            return
        }
        pendingDeleteAccount = nil
        await load {
            let state = try await client.removeAccount(accountKey: account.accountKey)
            DeletedAccountStore.append(account)
            deletedAccounts = DeletedAccountStore.load()
            notice = "已删除账号。"
            if await synchronizeCPAAccount(accountKey: account.accountKey, enabled: false) {
                synchronizedCPAEligibility.removeValue(forKey: account.accountKey)
            }
            return state
        }
    }

    func login(alias: String? = nil) async {
        await load {
            let previousActiveAccountKey = state?.activeAccountKey ?? state?.activeAccount?.accountKey
            let loggedInState = try await client.login()
            let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let accountKey = loggedInState.activeAccountKey ?? loggedInState.activeAccount?.accountKey
            var resultingState = loggedInState
            guard !trimmedAlias.isEmpty else {
                notice = "已添加账号。"
                if let previousActiveAccountKey, previousActiveAccountKey != accountKey {
                    resultingState = try await client.switchAccount(accountKey: previousActiveAccountKey)
                }
                return resultingState
            }
            guard let accountKey else {
                notice = "已添加账号。"
                return loggedInState
            }
            resultingState = try await client.setAlias(accountKey: accountKey, alias: trimmedAlias)
            notice = "已添加账号并设置别名。"
            if let previousActiveAccountKey, previousActiveAccountKey != accountKey {
                resultingState = try await client.switchAccount(accountKey: previousActiveAccountKey)
            }
            return resultingState
        }
    }

    /// 添加 API Key 连接；默认不切换当前直连，也不加入智能路由。
    /// 添加 API Key；默认只保存直连连接，用户明确选择后才加入 CPA 智能池。
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String, includeInSmartPool: Bool = false) async {
        await load {
            var state = try await client.addAPIKey(alias: alias, provider: provider, baseURL: baseURL, apiKey: apiKey)
            notice = includeInSmartPool ? "已添加 API Key 并加入智能路由。" : "已添加 API Key。默认未加入智能路由。"
            if includeInSmartPool, let account = state.accounts.first(where: { $0.isAPIKey && $0.baseURL == baseURL }) {
                state = try await client.setSmartPoolEnabled(accountKey: account.accountKey, enabled: true)
                if await synchronizeCPAAccount(accountKey: account.accountKey, enabled: true) {
                    synchronizedCPAEligibility[account.accountKey] = true
                }
            }
            return state
        }
    }

    func importAuth(path: String, alias: String?) async {
        await load {
            let state = try await client.importAuth(path: path, alias: alias)
            notice = "已导入账号。"
            return state
        }
    }

    func setAlias(accountKey: String, alias: String) async {
        await load {
            let state = try await client.setAlias(accountKey: accountKey, alias: alias)
            notice = "已更新别名。"
            return state
        }
    }

    func clearAlias(accountKey: String) async {
        await load {
            let state = try await client.clearAlias(accountKey: accountKey)
            notice = "已清除别名。"
            return state
        }
    }

    /// 更新账号的智能池成员状态，并保留当前直连选择不变。
    func setSmartPoolEnabled(accountKey: String, enabled: Bool) async {
        await load {
            let state = try await client.setSmartPoolEnabled(accountKey: accountKey, enabled: enabled)
            notice = enabled ? "已加入智能路由。" : "已从智能路由排除。"
            let routingEnabled = state.accounts
                .first(where: { $0.accountKey == accountKey })?
                .isEligibleForSmartRouting ?? false
            if await synchronizeCPAAccount(accountKey: accountKey, enabled: routingEnabled) {
                synchronizedCPAEligibility[accountKey] = routingEnabled
            }
            return state
        }
    }

    func openNewCodexSession(at directoryPath: String) async {
        errorMessage = nil
        do {
            try await client.openNewCodexSession(at: directoryPath)
            cpaConnectionStatus = .connected
        } catch {
            if error as? CPARuntimeError == .missingAPIKey {
                cpaConnectionStatus = .notConfigured
            } else {
                cpaConnectionStatus = .unavailable
            }
            errorMessage = error.localizedDescription
        }
    }

    /// 使用当前选中的连接启动直连 Codex，不改变 CPA 状态。
    func openDirectCodexSession(at directoryPath: String) async {
        guard let account = state?.activeAccount else {
            errorMessage = "请先选择一个当前连接。"
            return
        }
        errorMessage = nil
        do {
            try await client.openDirectCodexSession(at: directoryPath, account: account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 仅检查 CPA 连接状态，不触发账号额度或 Token 全量刷新。
    func refreshCPAConnection() async {
        cpaConnectionStatus = await client.checkCPAConnection()
    }

    /// 合并刷新请求并等待当前刷新循环处理完所有必要的后续工作。
    private func requestRefresh(_ work: AppRefreshWork, apiMode: CodexAuthAPIMode) async {
        switch work {
        case .full:
            if activeRefreshWork != .full {
                pendingFullRefresh = true
            }
        case .quota:
            if activeRefreshWork != .full && activeRefreshWork != .quota && !pendingFullRefresh {
                pendingQuotaRefresh = true
            }
        case .incrementalToken:
            if activeRefreshWork != .incrementalToken {
                pendingIncrementalTokenRefresh = true
            }
        }

        if refreshLoopTask == nil {
            refreshLoopTask = Task { [weak self] in
                await self?.runRefreshLoop(apiMode: apiMode)
            }
        }
        await refreshLoopTask?.value
    }

    /// 以全量、额度、增量的优先级串行执行；全量期间的新增量请求最多补跑一次。
    private func runRefreshLoop(apiMode: CodexAuthAPIMode) async {
        isLoading = true
        defer {
            activeRefreshWork = nil
            refreshLoopTask = nil
            isLoading = false
        }

        while !Task.isCancelled {
            if pendingFullRefresh {
                pendingFullRefresh = false
                pendingQuotaRefresh = false
                pendingIncrementalTokenRefresh = false
                activeRefreshWork = .full
                await performFullRefresh(apiMode: apiMode)
                activeRefreshWork = nil
                continue
            }
            if pendingQuotaRefresh {
                pendingQuotaRefresh = false
                activeRefreshWork = .quota
                await performQuotaRefresh(apiMode: apiMode)
                activeRefreshWork = nil
                continue
            }
            if pendingIncrementalTokenRefresh {
                pendingIncrementalTokenRefresh = false
                activeRefreshWork = .incrementalToken
                await performTokenRefresh(mode: .incremental)
                activeRefreshWork = nil
                continue
            }
            break
        }
    }

    /// 顺序提交额度和全量 Token 结果，使用现有序列号阻止旧额度覆盖账号操作。
    private func performFullRefresh(apiMode: CodexAuthAPIMode) async {
        loadSequence += 1
        let sequence = loadSequence
        errorMessage = nil
        do {
            let loadedState = try await client.refresh(apiMode: apiMode)
            if sequence == loadSequence {
                await acceptState(loadedState)
            }
        } catch {
            if sequence == loadSequence {
                errorMessage = error.localizedDescription
            }
        }
        await performTokenRefresh(mode: .full)
        cpaConnectionStatus = await client.checkCPAConnection()
    }

    /// 仅刷新权威额度数据，并沿用序列号保护账号切换结果。
    private func performQuotaRefresh(apiMode: CodexAuthAPIMode) async {
        loadSequence += 1
        let sequence = loadSequence
        errorMessage = nil
        do {
            let loadedState = try await client.refresh(apiMode: apiMode)
            if sequence == loadSequence {
                await acceptState(loadedState)
            }
        } catch {
            if sequence == loadSequence {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 仅接受最新一代 Token 扫描结果，失败时保留上一次成功值。
    private func performTokenRefresh(mode: TokenUsageScanMode) async {
        tokenUsageGeneration += 1
        let generation = tokenUsageGeneration
        do {
            let loadedUsage = try await client.loadTokenUsage(mode: mode)
            if generation == tokenUsageGeneration {
                tokenUsage = loadedUsage
            }
        } catch {
        }
    }

    /// 串行化状态结果写入，仅接受最新请求并在成功后检查低额度提醒。
    private func load(_ operation: () async throws -> CodexAuthState) async {
        loadSequence += 1
        let sequence = loadSequence
        isLoading = true
        errorMessage = nil
        defer {
            if sequence == loadSequence {
                isLoading = false
            }
        }
        do {
            let loadedState = try await operation()
            if sequence == loadSequence {
                await acceptState(loadedState)
            }
        } catch {
            if sequence == loadSequence {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 对最新活动账号执行阈值去重，并展示本次新增的低额度提醒。
    private func presentUsageAlerts(for state: CodexAuthState) {
        for alert in usageAlertTracker.alerts(for: state.activeAccount) {
            usageAlertPresenter.present(alert)
        }
    }

    /// 接受最新状态后协调终止性认证故障，确保 CPA 不再选择已失效的凭据副本。
    private func acceptState(_ loadedState: CodexAuthState) async {
        state = loadedState
        presentUsageAlerts(for: loadedState)
        await reconcileCPAEligibility(for: loadedState.accounts)
    }

    /// 失败同步保持未确认状态供下次刷新重试；健康成员只在此前被自动暂停时恢复。
    private func reconcileCPAEligibility(for accounts: [CodexAccount]) async {
        for account in accounts where account.participatesInSmartPool {
            let desiredEligibility: Bool
            if account.hasTerminalAuthenticationFailure {
                desiredEligibility = false
            } else if synchronizedCPAEligibility[account.accountKey] == false {
                desiredEligibility = true
            } else {
                continue
            }
            guard synchronizedCPAEligibility[account.accountKey] != desiredEligibility else {
                continue
            }
            if await synchronizeCPAAccount(accountKey: account.accountKey, enabled: desiredEligibility) {
                synchronizedCPAEligibility[account.accountKey] = desiredEligibility
            }
        }
    }

    /// CPA 同步失败不回滚已保存的成员状态，只展示可恢复的告警。
    @discardableResult
    private func synchronizeCPAAccount(accountKey: String, enabled: Bool) async -> Bool {
        do {
            try await client.syncCPAAccount(accountKey: accountKey, enabled: enabled)
            return true
        } catch {
            errorMessage = "智能池设置已保存，但 CPA 凭据同步失败：\(error.localizedDescription)"
            return false
        }
    }
}
