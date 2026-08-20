import Combine
import Foundation

/// 定义刷新优先级：菜单全量刷新覆盖额度定时刷新。
private enum AppRefreshWork {
    case full
    case quota
    case state
}

@MainActor
final class AppState: ObservableObject {
    nonisolated static let defaultPeriodicRefreshIntervalNanoseconds: UInt64 = 60_000_000_000
    nonisolated static let resetCreditsRefreshInterval: TimeInterval = 12 * 60 * 60

    @Published private(set) var state: CodexAuthState?
    @Published private(set) var tokenUsage: TokenUsageInfo?
    @Published private(set) var deletedAccounts: [DeletedAccountRecord]
    @Published private(set) var cpaServiceStatus: CPAServiceStatus = .unknown
    @Published private(set) var newAPIServiceStatus: NewAPIServiceStatus = .unknown
    @Published private(set) var hasSavedNewAPIToken = false
    @Published private(set) var isLoading = false
    @Published private(set) var isAccountSwitchInProgress = false
    @Published private(set) var isCPAOperationInProgress = false
    @Published private(set) var isNewAPIOperationInProgress = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var pendingDeleteAccount: CodexAccount?

    private let client: CodexAuthClientProtocol
    private let cpaRuntime: CPAServiceRuntimeProtocol
    private let newAPIRuntime: NewAPIServiceRuntimeProtocol
    private let newAPIChannelProvisioner: NewAPICPAChannelProvisioning
    private let usageAlertPresenter: UsageAlertPresenting
    private var usageAlertTracker = UsageAlertTracker()
    private var didRefreshOnAppLaunch = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var initialTokenRefreshTask: Task<Void, Never>?
    private var refreshLoopTask: Task<Void, Never>?
    private var activeRefreshWork: AppRefreshWork?
    private var pendingFullRefresh = false
    private var pendingQuotaRefresh = false
    private var pendingResetCreditsRefresh = false
    private var pendingTokenRefresh = false
    private var pendingStateLoad = false
    private var tokenUsageGeneration = 0
    private var loadSequence = 0
    private var isShuttingDown = false
    private var lastResetCreditsRefreshAt: Date?
    private let now: () -> Date

    /// 注入状态客户端和低额度展示器，便于隔离系统通知并测试阈值行为。
    init(
        client: CodexAuthClientProtocol = CodexAuthCLIClient(),
        cpaRuntime: CPAServiceRuntimeProtocol = CPAServiceRuntime(),
        newAPIRuntime: NewAPIServiceRuntimeProtocol = NewAPIServiceRuntime(),
        newAPIChannelProvisioner: NewAPICPAChannelProvisioning = BundledNewAPICPAChannelProvisioner(),
        usageAlertPresenter: UsageAlertPresenting? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.cpaRuntime = cpaRuntime
        self.newAPIRuntime = newAPIRuntime
        self.newAPIChannelProvisioner = newAPIChannelProvisioner
        self.usageAlertPresenter = usageAlertPresenter ?? DisabledUsageAlertPresenter()
        self.now = now
        self.deletedAccounts = DeletedAccountStore.load()
    }

    deinit {
        periodicRefreshTask?.cancel()
        initialTokenRefreshTask?.cancel()
        refreshLoopTask?.cancel()
    }

    var isShowingDeleteConfirmation: Bool {
        pendingDeleteAccount != nil
    }

    /// 返回注册表中的权威全局路由状态。
    var isCPAEnabled: Bool {
        state?.globalRoute == .cpa
    }

    /// 返回 NewAPI 模式下 CPA 上游服务是否实际运行。
    var isCPAServiceEnabled: Bool {
        cpaServiceStatus == .running
    }

    /// 返回桌面端产品模式是否已经切换到 NewAPI 统一出口。
    var isNewAPIEnabled: Bool {
        state?.globalRoute == .newapi
    }

    /// 提前准备系统通知权限，避免首次低额度事件只出现授权提示。
    func prepareUsageAlerts() {
        usageAlertPresenter.prepare()
    }

    func refresh(apiMode: CodexAuthAPIMode = .automatic) async {
        await load { try await client.loadState(apiMode: apiMode) }
    }

    /// 首次启动先用本地状态对账路由和服务，再异步扫描只影响展示的 Token 数据。
    func refreshOnAppLaunch(apiMode: CodexAuthAPIMode = .automatic) async {
        guard !didRefreshOnAppLaunch else {
            return
        }
        didRefreshOnAppLaunch = true
        isCPAOperationInProgress = true
        await refresh(apiMode: apiMode)
        guard let state else {
            isCPAOperationInProgress = false
            return
        }
        if state.globalRoute == .newapi {
            isNewAPIOperationInProgress = true
            await enableNewAPI(showSuccessNotice: false)
            isNewAPIOperationInProgress = false
        } else if state.globalRoute == .cpa {
            await enableCPA(showSuccessNotice: false)
        } else {
            await disableCPA(showSuccessNotice: false)
            await stopNewAPIIfNeeded()
        }
        isCPAOperationInProgress = false
        if errorMessage == nil {
            await requestRefresh(
                .quota,
                apiMode: apiMode,
                includeResetCredits: true,
                includeTokenRefresh: false
            )
        }
        startInitialTokenRefresh()
    }

    /// 后台执行首次全量 Token 扫描，不占用账号刷新与 CPA 路由操作队列。
    private func startInitialTokenRefresh() {
        initialTokenRefreshTask = Task { [weak self] in
            await self?.performTokenRefresh(mode: .full)
        }
    }

    /// 菜单打开时只读取本地权威状态；CPA 路由写入期间跳过，避免并发 CLI 覆盖注册表。
    func refreshOnMenuOpen(apiMode: CodexAuthAPIMode = .automatic) async {
        guard !isCPAOperationInProgress, !isNewAPIOperationInProgress else { return }
        if shouldRefreshResetCredits {
            await requestRefresh(
                .quota,
                apiMode: apiMode,
                includeResetCredits: true,
                includeTokenRefresh: false
            )
        } else {
            await requestRefresh(.state, apiMode: apiMode)
        }
        if isNewAPIEnabled {
            await refreshNewAPIServiceStatus()
            await refreshCPAServiceStatus()
        }
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
        guard !isCPAOperationInProgress, !isNewAPIOperationInProgress else { return }
        await requestRefresh(.quota, apiMode: apiMode, includeResetCredits: false)
    }

    /// 手动刷新额度与 Token；CPA 路由写入期间留待下次刷新。
    func refreshUsage(apiMode: CodexAuthAPIMode = .automatic) async {
        guard !isCPAOperationInProgress, !isNewAPIOperationInProgress else { return }
        await requestRefresh(.quota, apiMode: apiMode, includeResetCredits: true)
    }

    func switchAccount(accountKey: String) async {
        guard !isAccountSwitchInProgress, !isCPAOperationInProgress, !isNewAPIOperationInProgress else {
            return
        }
        let currentState = state
        isAccountSwitchInProgress = true
        defer { isAccountSwitchInProgress = false }
        await load {
            let switchedState = try await client.switchAccount(accountKey: accountKey)
            notice = switch switchedState.globalRoute {
            case .cpa:
                "已更新备用直连账号。关闭 CPA 后将使用此账号。"
            case .newapi:
                "已更新备用直连账号。关闭统一出口后将使用此账号。"
            case .direct:
                "已切换账号。新的 Codex CLI 会话将使用此账号。"
            }
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
        guard !isCPAOperationInProgress, !isNewAPIOperationInProgress, !isAccountSwitchInProgress else { return }
        isCPAOperationInProgress = true
        defer { isCPAOperationInProgress = false }
        let activeRefresh = refreshLoopTask
        await activeRefresh?.value
        if enabled {
            await enableCPA(showSuccessNotice: true)
        } else {
            await disableCPA(showSuccessNotice: true)
        }
    }

    /// 仅控制 NewAPI 使用的 CPA 上游服务，不改写当前全局路由。
    func setCPAServiceEnabled(_ enabled: Bool) async {
        guard !isCPAOperationInProgress, !isNewAPIOperationInProgress, !isAccountSwitchInProgress else { return }
        isCPAOperationInProgress = true
        defer { isCPAOperationInProgress = false }
        errorMessage = nil
        if enabled {
            cpaServiceStatus = .starting
            do {
                _ = try await cpaRuntime.startAndValidate()
                cpaServiceStatus = .running
            } catch {
                cpaServiceStatus = await cpaRuntime.status()
                errorMessage = "CPA 上游启动失败：\(error.localizedDescription)"
            }
        } else {
            do {
                try await cpaRuntime.stop()
                cpaServiceStatus = await cpaRuntime.status()
            } catch {
                cpaServiceStatus = await cpaRuntime.status()
                errorMessage = "CPA 上游停止失败：\(error.localizedDescription)"
            }
        }
    }

    /// 响应 NewAPI 统一出口开关，并串行完成上游服务、路由和回滚。
    func setNewAPIEnabled(_ enabled: Bool) async {
        guard !isNewAPIOperationInProgress, !isCPAOperationInProgress, !isAccountSwitchInProgress else { return }
        isNewAPIOperationInProgress = true
        defer { isNewAPIOperationInProgress = false }
        let activeRefresh = refreshLoopTask
        await activeRefresh?.value
        if enabled {
            await enableNewAPI(showSuccessNotice: true)
        } else {
            await disableNewAPI(showSuccessNotice: true)
        }
    }

    /// CPAMP 健康检查通过后使用系统浏览器打开 Full Mode 管理页。
    func openCPAManagementPage() async {
        errorMessage = nil
        do {
            try await cpaRuntime.openManagementPage()
        } catch {
            errorMessage = error.localizedDescription
            cpaServiceStatus = await cpaRuntime.status()
        }
    }

    /// 通过 NewAPI 原生网页打开本机管理入口，不向网页传递调用 Token。
    func openNewAPIManagementPage() async {
        errorMessage = nil
        do {
            try await newAPIRuntime.openManagementPage()
            newAPIServiceStatus = await newAPIRuntime.status()
        } catch {
            errorMessage = error.localizedDescription
            newAPIServiceStatus = await newAPIRuntime.status()
        }
    }

    /// 保存用户从 NewAPI 网页创建的调用 Token，并立即重新校验服务状态。
    func saveNewAPIToken(_ apiKey: String) async {
        errorMessage = nil
        do {
            try newAPIRuntime.saveAPIKey(apiKey)
            hasSavedNewAPIToken = true
            await refreshNewAPIServiceStatus()
            notice = "NewAPI Token 已保存。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 响应用户显式命令，将管理密钥复制到系统剪贴板。
    func copyCPAManagementKey() {
        errorMessage = nil
        do {
            try cpaRuntime.copyManagementKey()
            notice = "已复制 CPAMP 管理员密钥。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 更新 launchd 层状态，不触发服务启停或全局配置写入。
    func refreshCPAServiceStatus() async {
        cpaServiceStatus = await cpaRuntime.status()
    }

    /// 更新 NewAPI 服务状态，不触发启停和全局路由写入。
    func refreshNewAPIServiceStatus() async {
        newAPIServiceStatus = await newAPIRuntime.status()
        hasSavedNewAPIToken = newAPIRuntime.hasSavedAPIKey()
    }

    /// 清除本机保存的 NewAPI Token，并刷新服务状态。
    func clearNewAPIToken() async {
        errorMessage = nil
        do {
            try newAPIRuntime.clearAPIKey()
            hasSavedNewAPIToken = false
            await refreshNewAPIServiceStatus()
            notice = "NewAPI Token 已清除。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 退出前按直连路由、NewAPI、CPA 的顺序完成停服，再由 AppDelegate 终止进程。
    func shutdown(publishRouteState: Bool = true) async -> Bool {
        guard !isShuttingDown else { return false }
        isShuttingDown = true
        periodicRefreshTask?.cancel()
        initialTokenRefreshTask?.cancel()
        // 后台刷新可能卡在外部 CLI 或网络 I/O；退出只需取消它，不等待其完成，避免确认后主线程长期挂起。
        refreshLoopTask?.cancel()
        refreshLoopTask = nil

        if state?.globalRoute == .newapi {
            do {
                let directState = try await client.disableNewAPIRoute()
                if publishRouteState {
                    await acceptAuthoritativeRouteState(directState)
                }
            } catch {
                errorMessage = "退出前恢复直连失败：\(error.localizedDescription)"
                isShuttingDown = false
                return false
            }
        } else if state?.globalRoute == .cpa {
            do {
                let directState = try await client.disableCPARoute()
                if publishRouteState {
                    await acceptAuthoritativeRouteState(directState)
                }
            } catch {
                errorMessage = "退出前恢复直连失败：\(error.localizedDescription)"
                isShuttingDown = false
                return false
            }
        }
        // 退出路径只发送停服命令，不做 NewAPI 网络健康检查，避免异常服务阻塞退出确认。
        let newAPIStopError = await stopNewAPIForShutdown()
        let cpaStopError = await stopCPAIfNeeded()
        if let newAPIStopError {
            errorMessage = "退出前停止 NewAPI 失败：\(newAPIStopError.localizedDescription)"
            isShuttingDown = false
            return false
        }
        if let cpaStopError {
            errorMessage = "退出前停止 CPA 失败：\(cpaStopError.localizedDescription)"
            isShuttingDown = false
            return false
        }
        return true
    }

    /// 退出时直接停止 NewAPI；服务控制器自身保证未安装或已停止时幂等返回。
    @discardableResult
    private func stopNewAPIForShutdown() async -> Error? {
        do {
            try await newAPIRuntime.stop()
            newAPIServiceStatus = .stopped
            return nil
        } catch {
            newAPIServiceStatus = .unavailable
            return error
        }
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
            await acceptAuthoritativeRouteState(updatedState)
            cpaServiceStatus = .running
            if showSuccessNotice { notice = "CPA 已开启。新建 Codex 会话将全局使用 CPA。" }
        } catch let enableError {
            do {
                let directState = try await client.disableCPARoute()
                await acceptAuthoritativeRouteState(directState)
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

    /// 尝试启动 CPA 作为 NewAPI 上游；CPA 失败只降级状态，不阻断 NewAPI。
    private func enableNewAPI(showSuccessNotice: Bool) async {
        errorMessage = nil
        newAPIServiceStatus = .starting
        var cpaStartError: Error?
        do {
            _ = try await cpaRuntime.startAndValidate()
            cpaServiceStatus = .running
        } catch {
            cpaStartError = error
            cpaServiceStatus = await cpaRuntime.status()
        }

        do {
            if cpaStartError == nil {
                try await newAPIRuntime.stop()
                try await newAPIChannelProvisioner.configure()
            }
            let configuration = try await newAPIRuntime.startAndValidate()
            let updatedState = try await client.enableNewAPIRoute(
                baseURL: configuration.baseURL.absoluteString,
                clientConfigurationPath: configuration.clientConfigurationURL.path
            )
            await acceptAuthoritativeRouteState(updatedState)
            newAPIServiceStatus = .running
            if showSuccessNotice {
                notice = cpaStartError == nil
                    ? "NewAPI 已开启。新建 Codex 会话将统一使用 NewAPI。"
                    : "NewAPI 已开启，但 CPA 上游未连接：\(cpaStartError!.localizedDescription)"
            }
        } catch let enableError {
            do {
                let directState = try await client.disableNewAPIRoute()
                await acceptAuthoritativeRouteState(directState)
            } catch let rollbackError {
                newAPIServiceStatus = await newAPIRuntime.status()
                errorMessage = "NewAPI 开启失败，恢复直连失败；服务保持运行：\(enableError.localizedDescription)；\(rollbackError.localizedDescription)"
                return
            }
            await stopNewAPIIfNeeded()
            await stopCPAIfNeeded()
            newAPIServiceStatus = await newAPIRuntime.status()
            errorMessage = cpaStartError == nil
                ? "NewAPI 开启失败，已恢复直连：\(enableError.localizedDescription)"
                : "NewAPI 开启失败，已恢复直连；CPA 上游也已停止：\(enableError.localizedDescription)"
        }
    }

    /// 先恢复直连路由，再停止服务，确保新会话不会指向不可用端点。
    private func disableCPA(showSuccessNotice: Bool) async {
        errorMessage = nil
        do {
            let directState = try await client.disableCPARoute()
            await acceptAuthoritativeRouteState(directState)
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

    /// 先恢复直连路由，再停 NewAPI 和 CPA，避免留下指向已关闭服务的配置。
    private func disableNewAPI(showSuccessNotice: Bool) async {
        errorMessage = nil
        do {
            let directState = try await client.disableNewAPIRoute()
            await acceptAuthoritativeRouteState(directState)
        } catch {
            newAPIServiceStatus = await newAPIRuntime.status()
            errorMessage = error.localizedDescription
            return
        }
        let newAPIStopError = await stopNewAPIIfNeeded()
        let cpaStopError = await stopCPAIfNeeded()
        if let newAPIStopError {
            errorMessage = "已恢复直连，但 NewAPI 服务停止失败：\(newAPIStopError.localizedDescription)"
        } else if let cpaStopError {
            errorMessage = "已恢复直连并关闭 NewAPI，但 CPA 服务停止失败：\(cpaStopError.localizedDescription)"
        } else if showSuccessNotice {
            notice = "NewAPI 已关闭。新建 Codex 会话将使用当前直连账号。"
        }
    }

    /// 只在服务确实已安装并运行时执行停止，避免退出时把“未安装”误报为故障。
    @discardableResult
    private func stopNewAPIIfNeeded() async -> Error? {
        let status = await newAPIRuntime.status()
        newAPIServiceStatus = status
        guard status != .notInstalled, status != .stopped, status != .unknown else { return nil }
        do {
            try await newAPIRuntime.stop()
            newAPIServiceStatus = await newAPIRuntime.status()
            return nil
        } catch {
            newAPIServiceStatus = await newAPIRuntime.status()
            return error
        }
    }

    /// 始终要求运行时清理 CPA 所有受管服务，包括网关已停但 CPAMP 仍在运行的场景。
    @discardableResult
    private func stopCPAIfNeeded() async -> Error? {
        let status = await cpaRuntime.status()
        cpaServiceStatus = status
        do {
            try await cpaRuntime.stop()
            cpaServiceStatus = await cpaRuntime.status()
            return nil
        } catch {
            cpaServiceStatus = await cpaRuntime.status()
            return error
        }
    }

    /// 判断菜单打开时是否已经超过重置次数的十二小时缓存窗口。
    private var shouldRefreshResetCredits: Bool {
        guard let lastResetCreditsRefreshAt else { return true }
        return now().timeIntervalSince(lastResetCreditsRefreshAt) >= Self.resetCreditsRefreshInterval
    }

    /// 合并刷新请求并等待当前刷新循环处理完所有必要的后续工作。
    private func requestRefresh(
        _ work: AppRefreshWork,
        apiMode: CodexAuthAPIMode,
        includeResetCredits: Bool = false,
        includeTokenRefresh: Bool = true
    ) async {
        switch work {
        case .full:
            if activeRefreshWork != .full {
                pendingFullRefresh = true
            }
        case .quota:
            if activeRefreshWork != .full && activeRefreshWork != .quota && !pendingFullRefresh {
                pendingQuotaRefresh = true
                pendingResetCreditsRefresh = pendingResetCreditsRefresh || includeResetCredits
                pendingTokenRefresh = pendingTokenRefresh || includeTokenRefresh
            }
        case .state:
            if activeRefreshWork == nil && !pendingFullRefresh && !pendingQuotaRefresh {
                pendingStateLoad = true
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
                pendingResetCreditsRefresh = false
                pendingTokenRefresh = false
                pendingStateLoad = false
                activeRefreshWork = .full
                await performFullRefresh(apiMode: apiMode)
                activeRefreshWork = nil
                continue
            }
            if pendingQuotaRefresh {
                pendingQuotaRefresh = false
                let includeResetCredits = pendingResetCreditsRefresh
                pendingResetCreditsRefresh = false
                let includeTokenRefresh = pendingTokenRefresh
                pendingTokenRefresh = false
                pendingStateLoad = false
                activeRefreshWork = .quota
                await performQuotaRefresh(
                    apiMode: apiMode,
                    includeResetCredits: includeResetCredits,
                    includeTokenRefresh: includeTokenRefresh
                )
                activeRefreshWork = nil
                continue
            }
            if pendingStateLoad {
                pendingStateLoad = false
                activeRefreshWork = .state
                await performStateLoad(apiMode: apiMode)
                activeRefreshWork = nil
                continue
            }
            break
        }
    }

    /// 读取本地注册表状态，不触发账号联网刷新或完整 Token 扫描。
    private func performStateLoad(apiMode: CodexAuthAPIMode) async {
        loadSequence += 1
        let sequence = loadSequence
        errorMessage = nil
        do {
            let loadedState = try await client.loadState(apiMode: apiMode)
            if sequence == loadSequence {
                await acceptState(loadedState.preservingResetCredits(from: state))
            }
        } catch {
            if sequence == loadSequence {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 顺序提交额度和全量 Token 结果，使用现有序列号阻止旧额度覆盖账号操作。
    private func performFullRefresh(apiMode: CodexAuthAPIMode) async {
        loadSequence += 1
        let sequence = loadSequence
        errorMessage = nil
        do {
            let loadedState = try await client.refresh(apiMode: apiMode, includeResetCredits: true)
            if sequence == loadSequence {
                await acceptState(loadedState)
                lastResetCreditsRefreshAt = now()
            }
        } catch {
            if sequence == loadSequence {
                errorMessage = error.localizedDescription
            }
        }
        await performTokenRefresh(mode: .full)
    }

    /// 刷新权威额度后执行增量 Token 扫描，并沿用序列号保护账号切换结果。
    private func performQuotaRefresh(
        apiMode: CodexAuthAPIMode,
        includeResetCredits: Bool,
        includeTokenRefresh: Bool
    ) async {
        loadSequence += 1
        let sequence = loadSequence
        errorMessage = nil
        do {
            let loadedState = try await client.refresh(
                apiMode: apiMode,
                includeResetCredits: includeResetCredits
            )
            if sequence == loadSequence {
                let acceptedState = includeResetCredits
                    ? loadedState
                    : loadedState.preservingResetCredits(from: state)
                await acceptState(acceptedState)
                if includeResetCredits {
                    lastResetCreditsRefreshAt = now()
                }
            }
        } catch {
            if sequence == loadSequence {
                errorMessage = error.localizedDescription
            }
        }
        if includeTokenRefresh {
            await performIncrementalTokenRefresh()
        }
    }

    /// 等待启动全量扫描结束后再增量扫描，避免两个 CLI 进程并发改写 Token 缓存。
    private func performIncrementalTokenRefresh() async {
        await initialTokenRefreshTask?.value
        await performTokenRefresh(mode: .incremental)
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

    /// 提交 CPA 路由命令返回的权威状态，并让所有更早启动的刷新结果失效。
    private func acceptAuthoritativeRouteState(_ loadedState: CodexAuthState) async {
        loadSequence += 1
        isLoading = false
        await acceptState(loadedState)
    }
}
