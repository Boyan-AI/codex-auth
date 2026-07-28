import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    nonisolated static let defaultPeriodicRefreshIntervalNanoseconds: UInt64 = 60_000_000_000

    @Published private(set) var state: CodexAuthState?
    @Published private(set) var tokenUsage: TokenUsageInfo?
    @Published private(set) var deletedAccounts: [DeletedAccountRecord]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var pendingDeleteAccount: CodexAccount?

    private let client: CodexAuthClientProtocol
    private let usageAlertPresenter: UsageAlertPresenting
    private var usageAlertTracker = UsageAlertTracker()
    private var didRefreshOnAppLaunch = false
    private var periodicRefreshTask: Task<Void, Never>?
    private var loadSequence = 0

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
        await refreshUsage(apiMode: apiMode)
        await loadTokenUsageData()
    }

    func refreshOnMenuOpen(apiMode: CodexAuthAPIMode = .automatic) async {
        guard !isLoading else {
            return
        }
        await refreshUsage(apiMode: apiMode)
        await loadTokenUsageData()
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
        guard !isLoading else {
            return
        }
        await refreshUsage(apiMode: apiMode)
    }

    func refreshUsage(apiMode: CodexAuthAPIMode = .automatic) async {
        await load { try await client.refresh(apiMode: apiMode) }
    }

    func loadTokenUsageData() async {
        do {
            tokenUsage = try await client.loadTokenUsage()
        } catch {
        }
    }

    func switchAccount(accountKey: String) async {
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
            return state
        }
    }

    func login(alias: String? = nil) async {
        await load {
            let state = try await client.login()
            let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedAlias.isEmpty, let accountKey = state.activeAccountKey ?? state.activeAccount?.accountKey else {
                notice = "已添加账号。"
                return state
            }
            let renamedState = try await client.setAlias(accountKey: accountKey, alias: trimmedAlias)
            notice = "已添加账号并设置别名。"
            return renamedState
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

    func openNewCodexSession(at directoryPath: String) async {
        do {
            try await client.openNewCodexSession(at: directoryPath)
            notice = "已打开 Codex，会恢复最近会话或创建新会话。"
        } catch {
            errorMessage = error.localizedDescription
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
                state = loadedState
                presentUsageAlerts(for: loadedState)
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
}
