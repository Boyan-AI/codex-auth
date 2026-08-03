import XCTest
@testable import CodexAuthApp

@MainActor
final class AppStateTests: XCTestCase {
    func testSwitchUpdatesStateAndChineseMessage() async throws {
        let initial = CodexAuthState.empty(codexHome: "/tmp/codex")
        let switched = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-2",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                CodexAccount.sample(accountKey: "acct-2", alias: "备用号", isActive: true)
            ]
        )
        let client = StubCodexAuthClient(state: initial)
        client.switchState = switched
        let appState = AppState(client: client)

        await appState.refresh()
        await appState.switchAccount(accountKey: "acct-2")

        XCTAssertEqual(appState.state?.activeAccountKey, "acct-2")
        XCTAssertEqual(appState.notice, "已切换账号。新的 Codex CLI 会话将使用此账号。")
    }

    /// 验证切换主号只更新活动状态，不用注册表旧缓存覆盖当前展示的额度与认证错误。
    func testSwitchPreservesCurrentUsageSnapshot() async {
        let currentState = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-1",
            generatedAt: Date(timeIntervalSince1970: 10),
            refresh: RefreshInfo(attempted: true, status: "ok", message: nil),
            warnings: [],
            accounts: [
                makeSwitchAccount(accountKey: "acct-1", isActive: true, remainingPercent: 100),
                makeSwitchAccount(
                    accountKey: "acct-2",
                    isActive: false,
                    remainingPercent: nil,
                    status: "401 token_revoked"
                ),
                makeSwitchAccount(accountKey: "acct-removed", isActive: false, remainingPercent: 50),
            ]
        )
        let staleSwitchState = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-2",
            generatedAt: Date(timeIntervalSince1970: 20),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                makeSwitchAccount(accountKey: "acct-1", isActive: false, remainingPercent: 80),
                makeSwitchAccount(accountKey: "acct-2", isActive: true, remainingPercent: 99),
                makeSwitchAccount(accountKey: "acct-new", isActive: false, remainingPercent: 70),
            ]
        )
        let client = StubCodexAuthClient(state: currentState)
        client.switchState = staleSwitchState
        let appState = AppState(client: client)
        await appState.refresh()

        await appState.switchAccount(accountKey: "acct-2")

        XCTAssertEqual(appState.state?.activeAccountKey, "acct-2")
        XCTAssertEqual(appState.state?.accounts[0].usage.sevenDay.remainingPercent, 100)
        XCTAssertEqual(appState.state?.accounts[1].usage.sevenDay.status, "401 token_revoked")
        XCTAssertNil(appState.state?.accounts[1].usage.sevenDay.remainingPercent)
        XCTAssertEqual(appState.state?.accounts.map(\.accountKey), ["acct-1", "acct-2", "acct-new"])
        XCTAssertEqual(appState.state?.accounts[2].usage.sevenDay.remainingPercent, 70)
    }

    /// 验证账号切换期间只阻止重复切换，不复用后台全量刷新状态。
    func testAccountSwitchBusyStateCoalescesDuplicateRequests() async {
        let state = CodexAuthState.empty(codexHome: "/tmp/codex")
        let client = StubCodexAuthClient(state: state)
        client.shouldDelaySwitch = true
        let appState = AppState(client: client)

        let first = Task { await appState.switchAccount(accountKey: "acct-1") }
        await client.waitUntilSwitchStarted()
        XCTAssertTrue(appState.isAccountSwitchInProgress)

        let duplicate = Task { await appState.switchAccount(accountKey: "acct-2") }
        await duplicate.value
        XCTAssertEqual(client.switchCallCount, 1)

        client.finishSwitch()
        await first.value
        XCTAssertFalse(appState.isAccountSwitchInProgress)
    }

    func testDeleteRequiresConfirmation() {
        let appState = AppState(client: StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex")))
        let account = CodexAccount.sample(accountKey: "acct-1", alias: "工作号", isActive: true)

        appState.requestDelete(account)

        XCTAssertEqual(appState.pendingDeleteAccount?.accountKey, "acct-1")
        XCTAssertTrue(appState.isShowingDeleteConfirmation)
    }

    func testLoginUpdatesStateAndChineseMessage() async {
        let loggedIn = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-1",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                CodexAccount.sample(accountKey: "acct-1", alias: "工作号", isActive: true)
            ]
        )
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        client.loginState = loggedIn
        let appState = AppState(client: client)

        await appState.login()

        XCTAssertEqual(appState.state?.activeAccountKey, "acct-1")
        XCTAssertEqual(appState.notice, "已添加账号。")
    }

    func testLoginWithAliasPersistsAliasOnNewActiveAccount() async {
        let loggedIn = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-1",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                CodexAccount.sample(accountKey: "acct-1", alias: nil, isActive: true)
            ]
        )
        let renamed = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-1",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                CodexAccount.sample(accountKey: "acct-1", alias: "工作号", isActive: true)
            ]
        )
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        client.loginState = loggedIn
        client.aliasState = renamed
        let appState = AppState(client: client)

        await appState.login(alias: "工作号")

        XCTAssertEqual(client.setAliasAccountKey, "acct-1")
        XCTAssertEqual(client.setAliasValue, "工作号")
        XCTAssertEqual(appState.state?.activeAccount?.primaryLabel, "工作号")
        XCTAssertEqual(appState.notice, "已添加账号并设置别名。")
    }

    /// 验证已有当前连接时新增账号完成后恢复原当前连接。
    func testLoginRestoresPreviousActiveConnection() async {
        let original = CodexAccount.sample(accountKey: "acct-old", alias: "原账号", isActive: true)
        let added = CodexAccount.sample(accountKey: "acct-new", alias: nil, isActive: true)
        let initial = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-old",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [original]
        )
        let loggedIn = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-new",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [original, added]
        )
        let client = StubCodexAuthClient(state: initial)
        client.loginState = loggedIn
        client.switchState = initial
        let appState = AppState(client: client)
        await appState.refresh()

        await appState.login(alias: "新账号")

        XCTAssertEqual(client.setAliasAccountKey, "acct-new")
        XCTAssertEqual(client.switchAccountKey, "acct-old")
    }

    func testSetAliasUpdatesStateAndChineseMessage() async {
        let renamed = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-1",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                CodexAccount.sample(accountKey: "acct-1", alias: "新名字", isActive: true)
            ]
        )
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        client.aliasState = renamed
        let appState = AppState(client: client)

        await appState.setAlias(accountKey: "acct-1", alias: "新名字")

        XCTAssertEqual(appState.state?.accounts.first?.primaryLabel, "新名字")
        XCTAssertEqual(appState.notice, "已更新别名。")
    }

    /// 验证管理页智能池开关更新状态，但不改变官方 CLI 的当前直连账号。
    func testSetSmartPoolEnabledUpdatesStateAndMessage() async {
        let initialAccount = CodexAccount.sample(accountKey: "acct-1", alias: "工作号", isActive: true)
        let excludedAccount = CodexAccount(
            accountKey: initialAccount.accountKey,
            displayName: initialAccount.displayName,
            alias: initialAccount.alias,
            email: initialAccount.email,
            accountName: initialAccount.accountName,
            plan: initialAccount.plan,
            authMode: initialAccount.authMode,
            smartPoolEnabled: false,
            isActive: true,
            usage: initialAccount.usage,
            lastUsageAt: initialAccount.lastUsageAt,
            lastRefreshAt: initialAccount.lastRefreshAt
        )
        let excludedState = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-1",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [excludedAccount]
        )
        let client = StubCodexAuthClient(state: excludedState)
        client.smartPoolState = excludedState
        let appState = AppState(client: client)

        await appState.setSmartPoolEnabled(accountKey: "acct-1", enabled: false)

        XCTAssertEqual(client.smartPoolAccountKey, "acct-1")
        XCTAssertEqual(client.smartPoolEnabled, false)
        XCTAssertEqual(appState.state?.activeAccountKey, "acct-1")
        XCTAssertFalse(appState.state?.activeAccount?.participatesInSmartPool ?? true)
        XCTAssertEqual(appState.notice, "已从智能路由排除。")
        XCTAssertEqual(client.cpaSyncCalls, [CPAAccountSyncCall(accountKey: "acct-1", enabled: false)])
    }

    /// 验证首次发现终止性认证错误时删除 CPA 副本，重复刷新不会重复执行同步。
    func testTerminalAuthenticationFailurePausesCPARoutingOnce() async {
        let client = StubCodexAuthClient(state: makeUsageState(status: "401 token_invalidated"))
        let appState = AppState(client: client)

        await appState.refresh()
        await appState.refresh()

        XCTAssertEqual(client.cpaSyncCalls, [CPAAccountSyncCall(accountKey: "acct-alert", enabled: false)])
    }

    /// 验证被认证错误自动暂停的账号在重新认证并刷新成功后恢复 CPA 副本。
    func testRecoveredAuthenticationRestoresCPARouting() async {
        let client = StubCodexAuthClient(state: makeUsageState(status: "401 token_revoked"))
        let appState = AppState(client: client)
        await appState.refresh()

        client.state = makeUsageState(remainingPercent: 80, status: "ok")
        await appState.refresh()

        XCTAssertEqual(client.cpaSyncCalls, [
            CPAAccountSyncCall(accountKey: "acct-alert", enabled: false),
            CPAAccountSyncCall(accountKey: "acct-alert", enabled: true),
        ])
    }

    /// 验证用户明确排除的账号即使状态恢复，也不会被自动重新加入 CPA。
    func testExcludedAccountIsNotAutomaticallyRestoredToCPA() async {
        let client = StubCodexAuthClient(
            state: makeUsageState(status: "401 token_invalidated", smartPoolEnabled: false)
        )
        let appState = AppState(client: client)
        await appState.refresh()

        client.state = makeUsageState(remainingPercent: 80, status: "ok", smartPoolEnabled: false)
        await appState.refresh()

        XCTAssertTrue(client.cpaSyncCalls.isEmpty)
    }

    func testOpenCodexSessionUsesDirectoryWithoutPersistentOpenedMessage() async {
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        let appState = AppState(client: client)

        await appState.openNewCodexSession(at: "/Users/me/project")

        XCTAssertEqual(client.openedSessionDirectoryPath, "/Users/me/project")
        XCTAssertNil(appState.notice)
        XCTAssertEqual(appState.cpaConnectionStatus, .connected)
    }

    func testRefreshOnAppLaunchRunsUsageRefreshOnlyOnce() async {
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        let appState = AppState(client: client)

        await appState.refreshOnAppLaunch()
        await appState.refreshOnAppLaunch()

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertEqual(client.loadStateCallCount, 0)
        XCTAssertEqual(client.cpaReconcileCallCount, 1)
        XCTAssertEqual(client.startupOperationCalls, ["reconcile", "refresh"])
    }

    /// 验证启动 CPA 对账失败只显示可恢复错误，不丢弃已经加载的直连状态。
    func testRefreshOnAppLaunchKeepsLoadedStateWhenCPAReconcileFails() async {
        let expectedState = CodexAuthState.empty(codexHome: "/tmp/codex")
        let client = StubCodexAuthClient(state: expectedState)
        client.cpaReconcileError = CodexAuthCLIError.commandFailed("reconcile failed")
        let appState = AppState(client: client)

        await appState.refreshOnAppLaunch()

        XCTAssertEqual(appState.state, expectedState)
        XCTAssertEqual(appState.errorMessage, "CPA 账号池对账失败：命令执行失败：reconcile failed")
    }

    func testRefreshOnMenuOpenRunsUsageRefreshEveryTime() async {
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        let appState = AppState(client: client)

        await appState.refreshOnMenuOpen()
        await appState.refreshOnMenuOpen()

        XCTAssertEqual(client.refreshCallCount, 2)
        XCTAssertEqual(client.loadStateCallCount, 0)
    }

    /// 验证同一轮进行中的菜单全量刷新会被合并，而不是重复请求额度接口。
    func testConcurrentMenuOpenFullRefreshesAreCoalesced() async {
        let state = CodexAuthState.empty(codexHome: "/tmp/codex")
        let client = DelayedRefreshCodexAuthClient(refreshState: state, switchState: state)
        let appState = AppState(client: client)

        let first = Task { await appState.refreshOnMenuOpen() }
        await client.waitUntilRefreshStarted()
        let second = Task { await appState.refreshOnMenuOpen() }
        await Task.yield()
        XCTAssertTrue(appState.isLoading)
        XCTAssertFalse(appState.isAccountSwitchInProgress)
        client.finishRefresh()
        await first.value
        await second.value

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertEqual(client.tokenUsageCallModes, [.full])
    }

    /// 验证全量刷新期间到达的 CPA 事件会在全量完成后合并成一次增量补扫。
    func testCPAEventDuringFullRefreshRunsOneIncrementalFollowUp() async {
        let state = CodexAuthState.empty(codexHome: "/tmp/codex")
        let client = DelayedRefreshCodexAuthClient(refreshState: state, switchState: state)
        let appState = AppState(client: client)

        let full = Task { await appState.refreshOnMenuOpen() }
        await client.waitUntilRefreshStarted()
        let firstEvent = Task { await appState.refreshOnCPAEvent() }
        let secondEvent = Task { await appState.refreshOnCPAEvent() }
        await Task.yield()
        client.finishRefresh()
        await full.value
        await firstEvent.value
        await secondEvent.value

        XCTAssertEqual(client.tokenUsageCallModes, [.full, .incremental])
    }

    /// 验证 CPA 429 事件先刷新权威额度，再执行本地 Token 增量扫描。
    func testCPAQuotaEventRefreshesQuotaAndIncrementalTokens() async {
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        let appState = AppState(client: client)

        await appState.refreshOnCPAEvent(quotaExceeded: true)

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertEqual(client.tokenUsageCallModes, [.incremental])
    }

    /// 验证管理队列轮询结果会复用现有串行刷新协调器。
    func testPollCPAEventsOnceTriggersQuotaAndIncrementalRefresh() async {
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        client.cpaEventBatch = CPAEventBatch(eventCount: 1, quotaExceeded: true)
        let appState = AppState(client: client)

        await appState.pollCPAEventsOnce()

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertEqual(client.tokenUsageCallModes, [.incremental])
    }

    func testPeriodicRefreshTickRunsUsageRefresh() async {
        let client = StubCodexAuthClient(state: .empty(codexHome: "/tmp/codex"))
        let appState = AppState(client: client)

        await appState.refreshOnPeriodicTimer()

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertEqual(client.loadStateCallCount, 0)
    }

    /// 验证 25% 和 10% 阈值各提醒一次，并在额度恢复后重新开放提醒资格。
    func testUsageAlertsTriggerOncePerThresholdAndResetAfterRecovery() async {
        let client = StubCodexAuthClient(state: makeUsageState(remainingPercent: 24))
        let presenter = RecordingUsageAlertPresenter()
        let appState = AppState(client: client, usageAlertPresenter: presenter)

        appState.prepareUsageAlerts()
        await appState.refresh()
        client.state = makeUsageState(remainingPercent: 20)
        await appState.refresh()
        client.state = makeUsageState(remainingPercent: 9)
        await appState.refresh()
        await appState.refresh()
        client.state = makeUsageState(remainingPercent: 30)
        await appState.refresh()
        client.state = makeUsageState(remainingPercent: 24)
        await appState.refresh()

        XCTAssertEqual(presenter.prepareCallCount, 1)
        XCTAssertEqual(presenter.alerts.map(\.threshold), [25, 10, 25])
        XCTAssertEqual(presenter.alerts.map(\.remainingPercent), [24, 9, 24])
        XCTAssertTrue(presenter.alerts.allSatisfy { $0.windowLabel == "7 天" })
    }

    /// 验证刷新失败和缺失窗口不会产生低额度提醒。
    func testUsageAlertsIgnoreUnavailableWindows() async {
        let unavailableWindow = UsageWindow(
            status: "network_error",
            remainingPercent: nil,
            total: nil,
            used: nil,
            resetAt: nil
        )
        let client = StubCodexAuthClient(state: makeUsageState(sevenDay: unavailableWindow))
        let presenter = RecordingUsageAlertPresenter()
        let appState = AppState(client: client, usageAlertPresenter: presenter)

        await appState.refresh()

        XCTAssertTrue(presenter.alerts.isEmpty)
    }

    func testSwitchResultIsNotOverwrittenByOlderRefresh() async {
        let original = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-1",
            generatedAt: Date(timeIntervalSince1970: 0),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                CodexAccount.sample(accountKey: "acct-1", alias: "原账号", isActive: true),
                CodexAccount.sample(accountKey: "acct-2", alias: "新账号", isActive: false),
            ]
        )
        let switched = CodexAuthState(
            schemaVersion: 1,
            codexHome: "/tmp/codex",
            activeAccountKey: "acct-2",
            generatedAt: Date(timeIntervalSince1970: 1),
            refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
            warnings: [],
            accounts: [
                CodexAccount.sample(accountKey: "acct-1", alias: "原账号", isActive: false),
                CodexAccount.sample(accountKey: "acct-2", alias: "新账号", isActive: true),
            ]
        )
        let client = DelayedRefreshCodexAuthClient(refreshState: original, switchState: switched)
        let appState = AppState(client: client)

        let refreshTask = Task { await appState.refreshOnMenuOpen() }
        await client.waitUntilRefreshStarted()

        await appState.switchAccount(accountKey: "acct-2")
        client.finishRefresh()
        await refreshTask.value

        XCTAssertEqual(appState.state?.activeAccountKey, "acct-2")
        XCTAssertEqual(appState.notice, "已切换账号。新的 Codex CLI 会话将使用此账号。")
    }
}

/// 记录提醒展示调用，避免单元测试访问真实系统通知中心。
@MainActor
final class RecordingUsageAlertPresenter: UsageAlertPresenting {
    private(set) var prepareCallCount = 0
    private(set) var alerts: [UsageAlert] = []

    /// 记录通知权限准备调用，不访问真实系统通知中心。
    func prepare() {
        prepareCallCount += 1
    }

    /// 记录阈值提醒，供 AppState 测试断言。
    func present(_ alert: UsageAlert) {
        alerts.append(alert)
    }
}

/// 创建仅包含 7 天窗口的测试状态，默认窗口状态为可用。
private func makeUsageState(
    remainingPercent: Int? = nil,
    sevenDay: UsageWindow? = nil,
    status: String = "ok",
    smartPoolEnabled: Bool = true
) -> CodexAuthState {
    let resolvedSevenDay = sevenDay ?? UsageWindow(
        status: status,
        remainingPercent: remainingPercent,
        total: 100,
        used: remainingPercent.map { 100 - $0 },
        resetAt: nil
    )
    let account = CodexAccount(
        accountKey: "acct-alert",
        displayName: "提醒账号",
        alias: "提醒账号",
        email: "alert@example.com",
        accountName: nil,
        plan: "pro",
        authMode: "chatgpt",
        smartPoolEnabled: smartPoolEnabled,
        isActive: true,
        usage: UsageInfo(fiveHour: nil, sevenDay: resolvedSevenDay),
        lastUsageAt: nil,
        lastRefreshAt: nil
    )
    return CodexAuthState(
        schemaVersion: 1,
        codexHome: "/tmp/codex",
        activeAccountKey: account.accountKey,
        generatedAt: Date(timeIntervalSince1970: 0),
        refresh: RefreshInfo(attempted: true, status: "ok", message: nil),
        warnings: [],
        accounts: [account]
    )
}

/// 创建账号切换测试使用的状态记录，可分别表达当前展示值和注册表旧缓存。
private func makeSwitchAccount(
    accountKey: String,
    isActive: Bool,
    remainingPercent: Int?,
    status: String = "ok"
) -> CodexAccount {
    CodexAccount(
        accountKey: accountKey,
        displayName: accountKey,
        alias: accountKey,
        email: "\(accountKey)@example.com",
        accountName: nil,
        plan: "plus",
        authMode: "chatgpt",
        smartPoolEnabled: true,
        isActive: isActive,
        usage: UsageInfo(
            fiveHour: nil,
            sevenDay: UsageWindow(
                status: status,
                remainingPercent: remainingPercent,
                total: remainingPercent == nil ? nil : 100,
                used: remainingPercent.map { 100 - $0 },
                resetAt: nil
            )
        ),
        lastUsageAt: Date(timeIntervalSince1970: 5),
        lastRefreshAt: Date(timeIntervalSince1970: 5)
    )
}

final class StubCodexAuthClient: CodexAuthClientProtocol {
    var state: CodexAuthState
    var switchState: CodexAuthState?
    var loginState: CodexAuthState?
    var aliasState: CodexAuthState?
    var smartPoolState: CodexAuthState?
    var openedSessionDirectoryPath: String?
    var setAliasAccountKey: String?
    var switchAccountKey: String?
    var setAliasValue: String?
    var smartPoolAccountKey: String?
    var smartPoolEnabled: Bool?
    var loadStateCallCount = 0
    var refreshCallCount = 0
    var tokenUsageCallModes: [TokenUsageScanMode] = []
    var cpaSyncCalls: [CPAAccountSyncCall] = []
    var cpaReconcileCallCount = 0
    var cpaReconcileError: Error?
    var startupOperationCalls: [String] = []
    var cpaEventBatch: CPAEventBatch = .empty
    var shouldDelaySwitch = false
    private var switchContinuation: CheckedContinuation<Void, Never>?
    private var switchStartedContinuation: CheckedContinuation<Void, Never>?
    private(set) var switchCallCount = 0

    init(state: CodexAuthState) {
        self.state = state
    }

    func loadState(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState {
        loadStateCallCount += 1
        return state
    }

    /// 记录 Token 扫描模式，并使用明确错误让测试保留空统计状态。
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo {
        tokenUsageCallModes.append(mode)
        throw CodexAuthCLIError.commandFailed("Token usage is unavailable")
    }

    func refresh(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState {
        refreshCallCount += 1
        startupOperationCalls.append("refresh")
        return state
    }

    func switchAccount(accountKey: String) async throws -> CodexAuthState {
        switchCallCount += 1
        switchAccountKey = accountKey
        if shouldDelaySwitch {
            await withCheckedContinuation { continuation in
                switchContinuation = continuation
                switchStartedContinuation?.resume()
                switchStartedContinuation = nil
            }
        }
        return switchState ?? state
    }

    /// 等待测试账号切换进入挂起状态，避免依赖固定延迟。
    func waitUntilSwitchStarted() async {
        if switchContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            switchStartedContinuation = continuation
        }
    }

    /// 恢复挂起的测试账号切换。
    func finishSwitch() {
        switchContinuation?.resume()
        switchContinuation = nil
    }

    func removeAccount(accountKey: String) async throws -> CodexAuthState {
        state
    }

    func setAlias(accountKey: String, alias: String) async throws -> CodexAuthState {
        setAliasAccountKey = accountKey
        setAliasValue = alias
        return aliasState ?? state
    }

    func clearAlias(accountKey: String) async throws -> CodexAuthState {
        state
    }

    /// 记录智能池开关参数并返回指定状态。
    func setSmartPoolEnabled(accountKey: String, enabled: Bool) async throws -> CodexAuthState {
        smartPoolAccountKey = accountKey
        smartPoolEnabled = enabled
        return smartPoolState ?? state
    }

    /// 记录 AppState 发出的 CPA 凭据同步请求。
    func syncCPAAccount(accountKey: String, enabled: Bool) async throws {
        cpaSyncCalls.append(CPAAccountSyncCall(accountKey: accountKey, enabled: enabled))
    }

    /// 记录启动 CPA 全目录对账，并按需注入可恢复错误。
    func reconcileCPAAccounts() async throws {
        cpaReconcileCallCount += 1
        startupOperationCalls.append("reconcile")
        if let cpaReconcileError {
            throw cpaReconcileError
        }
    }

    /// 返回预置事件批次，验证轮询与刷新协调器的衔接。
    func pollCPAEvents() async throws -> CPAEventBatch {
        cpaEventBatch
    }

    func login() async throws -> CodexAuthState {
        loginState ?? state
    }

    func importAuth(path: String, alias: String?) async throws -> CodexAuthState {
        state
    }

    func openNewCodexSession(at directoryPath: String) async throws {
        openedSessionDirectoryPath = directoryPath
    }
}

/// 表示测试客户端收到的一次 CPA 成员同步调用。
struct CPAAccountSyncCall: Equatable {
    let accountKey: String
    let enabled: Bool
}

@MainActor
final class DelayedRefreshCodexAuthClient: CodexAuthClientProtocol {
    let refreshState: CodexAuthState
    let switchState: CodexAuthState
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var refreshStartedContinuation: CheckedContinuation<Void, Never>?
    private(set) var refreshCallCount = 0
    private(set) var tokenUsageCallModes: [TokenUsageScanMode] = []

    init(refreshState: CodexAuthState, switchState: CodexAuthState) {
        self.refreshState = refreshState
        self.switchState = switchState
    }

    func waitUntilRefreshStarted() async {
        if refreshContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            refreshStartedContinuation = continuation
        }
    }

    func finishRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    func loadState(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState {
        refreshState
    }

    func refresh(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState {
        refreshCallCount += 1
        await withCheckedContinuation { continuation in
            refreshContinuation = continuation
            refreshStartedContinuation?.resume()
            refreshStartedContinuation = nil
        }
        return refreshState
    }

    /// 记录协调器选择的全量或增量模式，不访问真实 rollout 文件。
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo {
        tokenUsageCallModes.append(mode)
        throw CodexAuthCLIError.commandFailed("Token usage is unavailable")
    }

    func switchAccount(accountKey: String) async throws -> CodexAuthState {
        switchState
    }

    func removeAccount(accountKey: String) async throws -> CodexAuthState {
        refreshState
    }

    func setAlias(accountKey: String, alias: String) async throws -> CodexAuthState {
        refreshState
    }

    func clearAlias(accountKey: String) async throws -> CodexAuthState {
        refreshState
    }

    func login() async throws -> CodexAuthState {
        refreshState
    }

    func importAuth(path: String, alias: String?) async throws -> CodexAuthState {
        refreshState
    }

    func openNewCodexSession(at directoryPath: String) async throws {}
}
