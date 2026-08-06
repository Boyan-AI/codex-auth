import Combine
import Foundation

/// 定义刷新优先级：菜单全量刷新覆盖额度定时刷新。
private enum AppRefreshWork {
    case full
    case quota
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static let defaultPeriodicRefreshIntervalNanoseconds: UInt64 = 60_000_000_000

    @Published private(set) var state: CodexAuthState?
    @Published private(set) var tokenUsage: TokenUsageInfo?
    @Published private(set) var deletedAccounts: [DeletedAccountRecord]
    @Published private(set) var cpaServiceStatus: CPAServiceStatus = .unknown
    @Published private(set) var isLoading = false
    @Published private(set) var isAccountSwitchInProgress = false
    @Published private(set) var isCPAOperationInProgress = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var pendingDeleteAccount: CodexAccount?

    private let client: CodexAuthClientProtocol
    private let cpaRuntime: CPAServiceRuntimeProtocol
    private let usageAlertPresenter: UsageAlertPresenting
    private var usageAlertTracker = UsageAlertTracker()
    private var didRefreshOnAppLaunch = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var refreshLoopTask: Task<Void, Never>?
    private var activeRefreshWork: AppRefreshWork?
    private var pendingFullRefresh = false
    private var pendingQuotaRefresh = false
    private var tokenUsageGeneration = 0
    private var loadSequence = 0

    /// 注入状态客户端和低额度展示器，便于隔离系统通知并测试阈值行为。
    init(
        client: CodexAuthClientProtocol = CodexAuthCLIClient(),
        cpaRuntime: CPAServiceRuntimeProtocol = CPAServiceRuntime(),
        usageAlertPresenter: UsageAlertPresenting? = nil
    ) {
        self.client = client
        self.cpaRuntime = cpaRuntime
        self.usageAlertPresenter = usageAlertPresenter ?? DisabledUsageAlertPresenter()
        self.deletedAccounts = DeletedAccountStore.load()
    }

    deinit {
        periodicRefreshTask?.cancel()
        refreshLoopTask?.cancel()
    }

    var isShowingDeleteConfirmation: Bool {
        pendingDeleteAccount != nil
    }

    /// 返回注册表中的权威全局路由状态。
    var isCPAEnabled: Bool {
        state?.globalRoute == .cpa
    }

    /// 提前准备系统通知权限，避免首次低额度事件只出现授权提示。
    func prepareUsageAlerts() {
        usageAlertPresenter.prepare()
    }

    func refresh(apiMode: CodexAuthAPIMode = .automatic) async {
        await load { try await client.loadState(apiMode: apiMode) }
    }

    /// 首次启动刷新状态后对账全局路由和用户级服务，失败时降级为直连。
    func refreshOnAppLaunch(apiMode: CodexAuthAPIMode = .automatic) async {
        guard !didRefreshOnAppLaunch else {
            return
        }
        didRefreshOnAppLaunch = true
        isCPAOperationInProgress = true
        defer { isCPAOperationInProgress = false }
        await requestRefresh(.full, apiMode: apiMode)
        guard let state else { return }
        if state.globalRoute == .cpa {
            await enableCPA(showSuccessNotice: false)
        } else {
            await disableCPA(showSuccessNotice: false)
        }
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

    /// 手动额度刷新也进入同一写入队列，避免与菜单全量结果交叉覆盖。
    func refreshUsage(apiMode: CodexAuthAPIMode = .automatic) async {
        await requestRefresh(.quota, apiMode: apiMode)
    }

    func switchAccount(accountKey: String) async {
        guard !isAccountSwitchInProgress, !isCPAOperationInProgress else {
            return
        }
        let currentState = state
        isAccountSwitchInProgress = true
        defer { isAccountSwitchInProgress = false }
        await load {
            let switchedState = try await client.switchAccount(accountKey: accountKey)
            notice = switchedState.globalRoute == .cpa
                ? "已更新备用直连账号。关闭 CPA 后将使用此账号。"
                : "已切换账号。新的 Codex CLI 会话将使用此账号。"
            return switchedState.preservingDisplayedTelemetry(from: currentState)
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

    /// 添加只属于直连账号列表的 API Key，不触碰 CPA 数据。
    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async {
        await load {
            let state = try await client.addAPIKey(alias: alias, provider: provider, baseURL: baseURL, apiKey: apiKey)
            notice = "已添加 API Key。"
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

    /// 响应全局 CPA 开关，并防止并发启停交叉覆盖路由。
    func setCPAEnabled(_ enabled: Bool) async {
        guard !isCPAOperationInProgress, !isAccountSwitchInProgress else { return }
        isCPAOperationInProgress = true
        defer { isCPAOperationInProgress = false }
        if enabled {
            await enableCPA(showSuccessNotice: true)
        } else {
            await disableCPA(showSuccessNotice: true)
        }
    }

    /// 健康检查通过后使用系统浏览器打开 CPA 原生管理页。
    func openCPAManagementPage() async {
        errorMessage = nil
        do {
            try await cpaRuntime.openManagementPage()
        } catch {
            errorMessage = error.localizedDescription
            cpaServiceStatus = await cpaRuntime.status()
        }
    }

    /// 响应用户显式命令，将管理密钥复制到系统剪贴板。
    func copyCPAManagementKey() {
        errorMessage = nil
        do {
            try cpaRuntime.copyManagementKey()
            notice = "已复制 CPA 管理密钥。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 更新 launchd 层状态，不触发服务启停或全局配置写入。
    func refreshCPAServiceStatus() async {
        cpaServiceStatus = await cpaRuntime.status()
    }

    /// 先启动并校验服务，再提交全局 CPA 路由；任一步失败都恢复直连并停服。
    private func enableCPA(showSuccessNotice: Bool) async {
        errorMessage = nil
        cpaServiceStatus = .starting
        do {
            let configuration = try await cpaRuntime.startAndValidate()
            let updatedState = try await client.enableCPARoute(
                baseURL: configuration.baseURL.absoluteString,
                clientConfigurationPath: configuration.clientConfigurationURL.path
            )
            await acceptState(updatedState)
            cpaServiceStatus = .running
            if showSuccessNotice { notice = "CPA 已开启。新建 Codex 会话将全局使用 CPA。" }
        } catch let enableError {
            do {
                let directState = try await client.disableCPARoute()
                await acceptState(directState)
            } catch let rollbackError {
                cpaServiceStatus = await cpaRuntime.status()
                errorMessage = "CPA 开启失败，恢复直连失败；CPA 服务保持运行：\(enableError.localizedDescription)；\(rollbackError.localizedDescription)"
                return
            }
            let stopError: Error?
            do {
                try await cpaRuntime.stop()
                stopError = nil
            } catch {
                stopError = error
            }
            cpaServiceStatus = await cpaRuntime.status()
            if let stopError {
                errorMessage = "CPA 开启失败，已恢复直连，但服务停止失败：\(enableError.localizedDescription)；\(stopError.localizedDescription)"
            } else {
                errorMessage = "CPA 开启失败，已恢复直连：\(enableError.localizedDescription)"
            }
        }
    }

    /// 先恢复直连路由，再停止服务，确保新会话不会指向不可用端点。
    private func disableCPA(showSuccessNotice: Bool) async {
        errorMessage = nil
        do {
            let directState = try await client.disableCPARoute()
            await acceptState(directState)
        } catch {
            cpaServiceStatus = await cpaRuntime.status()
            errorMessage = error.localizedDescription
            return
        }
        do {
            try await cpaRuntime.stop()
            cpaServiceStatus = await cpaRuntime.status()
            if showSuccessNotice { notice = "CPA 已关闭。新建 Codex 会话将使用当前直连账号。" }
        } catch {
            cpaServiceStatus = await cpaRuntime.status()
            errorMessage = "已恢复直连，但 CPA 服务停止失败：\(error.localizedDescription)"
        }
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
        }

        if refreshLoopTask == nil {
            refreshLoopTask = Task { [weak self] in
                await self?.runRefreshLoop(apiMode: apiMode)
            }
        }
        await refreshLoopTask?.value
    }

    /// 以全量、额度优先级串行执行，避免并发刷新覆盖账号操作。
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

    /// 接受最新状态并展示额度提醒；直连认证故障不再影响 CPA 独立会话。
    private func acceptState(_ loadedState: CodexAuthState) async {
        state = loadedState
        presentUsageAlerts(for: loadedState)
    }
}
