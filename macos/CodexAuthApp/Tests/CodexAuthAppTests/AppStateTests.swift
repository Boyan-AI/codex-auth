import XCTest
@testable import CodexAuthApp

@MainActor
final class AppStateTests: XCTestCase {
    /// 验证 CPA 开启顺序为服务就绪后写全局路由。
    func testEnableCPAStartsServiceBeforeChangingGlobalRoute() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations)
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.setCPAEnabled(true)

        XCTAssertEqual(operations.values, ["service-start", "route-enable"])
        XCTAssertTrue(appState.isCPAEnabled)
        XCTAssertEqual(appState.cpaServiceStatus, .running)
    }

    /// 验证 NewAPI 模式下 CPA 独立开关只启停上游服务，不改写全局路由。
    func testCPAServiceToggleControlsOnlyUpstreamService() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .newapi), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations)
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.setCPAServiceEnabled(true)
        XCTAssertEqual(operations.values, ["service-start"])
        XCTAssertTrue(appState.isCPAServiceEnabled)

        await appState.setCPAServiceEnabled(false)
        XCTAssertEqual(operations.values, ["service-start", "service-stop"])
        XCTAssertFalse(appState.isCPAServiceEnabled)
    }

    /// 验证 NewAPI 开启顺序为 CPA 就绪、停服配置渠道、NewAPI 就绪和路由写入。
    func testEnableNewAPIStartsOptionalCPABeforeChangingNewAPIRoute() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let cpaRuntime = StubCPAServiceRuntime(operations: operations)
        let newAPIRuntime = StubNewAPIServiceRuntime(operations: operations)
        let provisioner = StubNewAPICPAChannelProvisioner(operations: operations)
        let appState = AppState(
            client: client,
            cpaRuntime: cpaRuntime,
            newAPIRuntime: newAPIRuntime,
            newAPIChannelProvisioner: provisioner
        )

        await appState.setNewAPIEnabled(true)

        XCTAssertEqual(operations.values, [
            "service-start",
            "newapi-stop",
            "newapi-provision",
            "newapi-start",
            "newapi-route-enable",
        ])
        XCTAssertTrue(appState.isNewAPIEnabled)
        XCTAssertEqual(appState.newAPIServiceStatus, .running)
        XCTAssertEqual(appState.cpaServiceStatus, .running)
    }

    /// 验证专属渠道同步失败时不切换 NewAPI 路由并停止已启动的 CPA。
    func testEnableNewAPIProvisioningFailureRollsBackWithoutEnablingRoute() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let cpaRuntime = StubCPAServiceRuntime(operations: operations)
        let newAPIRuntime = StubNewAPIServiceRuntime(operations: operations)
        let provisioner = StubNewAPICPAChannelProvisioner(operations: operations)
        provisioner.error = NewAPIRuntimeError.managedCPAChannelConfigurationFailed("fixture failure")
        let appState = AppState(
            client: client,
            cpaRuntime: cpaRuntime,
            newAPIRuntime: newAPIRuntime,
            newAPIChannelProvisioner: provisioner
        )

        await appState.setNewAPIEnabled(true)

        XCTAssertEqual(operations.values, [
            "service-start",
            "newapi-stop",
            "newapi-provision",
            "newapi-route-disable",
            "newapi-status",
            "service-stop",
            "newapi-status",
        ])
        XCTAssertFalse(appState.isNewAPIEnabled)
        XCTAssertEqual(newAPIRuntime.currentStatus, .stopped)
        XCTAssertEqual(cpaRuntime.currentStatus, .stopped)
    }

    /// 验证 CPA 上游失败时仍可启动 NewAPI，并向用户保留降级提示。
    func testEnableNewAPIContinuesWhenCPAUpstreamFails() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let cpaRuntime = StubCPAServiceRuntime(operations: operations)
        cpaRuntime.startError = CPARuntimeError.unavailable("CPA offline")
        let newAPIRuntime = StubNewAPIServiceRuntime(operations: operations)
        let appState = AppState(client: client, cpaRuntime: cpaRuntime, newAPIRuntime: newAPIRuntime)

        await appState.setNewAPIEnabled(true)

        XCTAssertEqual(operations.values, ["service-start", "newapi-start", "newapi-route-enable"])
        XCTAssertTrue(appState.isNewAPIEnabled)
        XCTAssertTrue(appState.notice?.contains("CPA 上游未连接") == true)
    }

    /// 验证 NewAPI 关闭先恢复直连，再停 NewAPI 和 CPA。
    func testDisableNewAPIRestoresDirectBeforeStoppingServices() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .newapi), operations: operations)
        let cpaRuntime = StubCPAServiceRuntime(operations: operations, status: .running)
        let newAPIRuntime = StubNewAPIServiceRuntime(operations: operations, status: .running)
        let appState = AppState(client: client, cpaRuntime: cpaRuntime, newAPIRuntime: newAPIRuntime)
        await appState.refresh()

        await appState.setNewAPIEnabled(false)

        XCTAssertEqual(operations.values, ["newapi-route-disable", "newapi-status", "newapi-stop", "newapi-status", "service-stop"])
        XCTAssertFalse(appState.isNewAPIEnabled)
        XCTAssertEqual(appState.newAPIServiceStatus, .stopped)
        XCTAssertEqual(appState.cpaServiceStatus, .stopped)
    }

    /// 验证退出会先恢复直连，再停止 NewAPI 和 CPA 服务。
    func testShutdownRestoresDirectAndStopsBothServices() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .newapi), operations: operations)
        let cpaRuntime = StubCPAServiceRuntime(operations: operations, status: .running)
        let newAPIRuntime = StubNewAPIServiceRuntime(operations: operations, status: .running)
        let appState = AppState(client: client, cpaRuntime: cpaRuntime, newAPIRuntime: newAPIRuntime)
        await appState.refresh()

        let canTerminate = await appState.shutdown()

        XCTAssertTrue(canTerminate)
        XCTAssertEqual(operations.values, ["newapi-route-disable", "newapi-stop", "service-stop"])
        XCTAssertFalse(appState.isNewAPIEnabled)
        XCTAssertEqual(appState.newAPIServiceStatus, .stopped)
        XCTAssertEqual(appState.cpaServiceStatus, .stopped)
    }

    /// 验证直连退出仍会清理 CPA 运行时拥有的管理服务，即使网关状态已经停止。
    func testShutdownCleansCPAResourcesWhenGatewayIsAlreadyStopped() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let cpaRuntime = StubCPAServiceRuntime(operations: operations, status: .stopped)
        let newAPIRuntime = StubNewAPIServiceRuntime(operations: operations, status: .stopped)
        let appState = AppState(client: client, cpaRuntime: cpaRuntime, newAPIRuntime: newAPIRuntime)
        await appState.refresh()

        let canTerminate = await appState.shutdown()

        XCTAssertTrue(canTerminate)
        XCTAssertEqual(operations.values, ["newapi-stop", "service-stop"])
        XCTAssertEqual(cpaRuntime.currentStatus, .stopped)
    }

    /// 验证退出前恢复直连失败时拒绝终止，并保留仍被路由引用的服务。
    func testShutdownFailureKeepsRoutedServicesRunning() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .newapi), operations: operations)
        client.disableError = CodexAuthCLIError.commandFailed("restore failed")
        let cpaRuntime = StubCPAServiceRuntime(operations: operations, status: .running)
        let newAPIRuntime = StubNewAPIServiceRuntime(operations: operations, status: .running)
        let appState = AppState(client: client, cpaRuntime: cpaRuntime, newAPIRuntime: newAPIRuntime)
        await appState.refresh()

        let canTerminate = await appState.shutdown()

        XCTAssertFalse(canTerminate)
        XCTAssertEqual(operations.values, ["newapi-route-disable"])
        XCTAssertEqual(newAPIRuntime.currentStatus, .running)
        XCTAssertEqual(cpaRuntime.currentStatus, .running)
        XCTAssertTrue(appState.errorMessage?.contains("恢复直连失败") == true)
    }

    /// 验证关闭 CPA 先恢复直连路由，再停止服务。
    func testDisableCPARestoresDirectRouteBeforeStoppingService() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .cpa), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations, status: .running)
        let appState = AppState(client: client, cpaRuntime: runtime)
        await appState.refresh()

        await appState.setCPAEnabled(false)

        XCTAssertEqual(operations.values, ["route-disable", "service-stop"])
        XCTAssertFalse(appState.isCPAEnabled)
        XCTAssertEqual(appState.cpaServiceStatus, .stopped)
    }

    /// 验证菜单本地状态读取结束前，CPA 路由操作不会并发改写注册表。
    func testCPAOperationWaitsForMenuStateLoadBeforeChangingRoute() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .cpa), operations: operations)
        client.recordsLoadStateOperation = true
        let runtime = StubCPAServiceRuntime(operations: operations, status: .running)
        let appState = AppState(client: client, cpaRuntime: runtime)
        let stateLoadGate = AsyncOperationGate()
        client.loadStateGate = stateLoadGate

        let menuRefresh = Task { await appState.refreshOnMenuOpen() }
        await stateLoadGate.waitUntilSuspended()
        let disable = Task { await appState.setCPAEnabled(false) }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(operations.values, ["state"])

        await stateLoadGate.resume()
        await menuRefresh.value
        await disable.value

        XCTAssertEqual(operations.values, ["state", "route-disable", "service-stop"])
        XCTAssertFalse(appState.isCPAEnabled)
        XCTAssertEqual(appState.cpaServiceStatus, .stopped)
    }

    /// 验证打开菜单只读取本地状态，不触发账号联网刷新。
    func testMenuOpenLoadsLocalStateWithoutNetworkRefresh() async {
        let client = StubCodexAuthClient(state: makeState(route: .direct))
        let appState = AppState(client: client, cpaRuntime: StubCPAServiceRuntime())

        await appState.refreshOnMenuOpen()

        XCTAssertEqual(client.loadStateCallCount, 1)
        XCTAssertEqual(client.refreshCallCount, 0)
        XCTAssertTrue(client.tokenUsageModes.isEmpty)
    }

    /// 验证 60 秒周期刷新在更新账号额度后执行增量 Token 扫描。
    func testPeriodicRefreshUpdatesQuotaAndTokenIncrementally() async {
        let client = StubCodexAuthClient(state: makeState(route: .direct))
        let appState = AppState(client: client, cpaRuntime: StubCPAServiceRuntime())

        await appState.refreshOnPeriodicTimer()

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertEqual(client.tokenUsageModes, [.incremental])
    }

    /// 验证用户手动刷新同时更新账号额度和本地 Token 增量。
    func testManualUsageRefreshUpdatesQuotaAndTokenIncrementally() async {
        let client = StubCodexAuthClient(state: makeState(route: .direct))
        let appState = AppState(client: client, cpaRuntime: StubCPAServiceRuntime())

        await appState.refreshUsage()

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertEqual(client.tokenUsageModes, [.incremental])
    }

    /// 验证权威 CPA 路由淘汰普通状态读取后仍会结束加载状态。
    func testAuthoritativeCPARouteClearsInvalidatedStateLoad() async {
        let client = StubCodexAuthClient(state: makeState(route: .cpa))
        let runtime = StubCPAServiceRuntime(status: .running)
        let appState = AppState(client: client, cpaRuntime: runtime)
        await appState.refresh()
        let loadStateGate = AsyncOperationGate()
        client.loadStateGate = loadStateGate

        let staleLoad = Task { await appState.refresh() }
        await loadStateGate.waitUntilSuspended()
        await appState.setCPAEnabled(false)
        await loadStateGate.resume()
        await staleLoad.value

        XCTAssertFalse(appState.isLoading)
        XCTAssertFalse(appState.isCPAEnabled)
        XCTAssertEqual(appState.cpaServiceStatus, .stopped)
    }

    /// 验证服务校验失败时恢复直连并停服。
    func testEnableCPAFailureRollsBackRouteAndService() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations)
        runtime.startError = CPARuntimeError.unavailable("health failed")
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.setCPAEnabled(true)

        XCTAssertEqual(operations.values, ["service-start", "route-disable", "service-stop"])
        XCTAssertFalse(appState.isCPAEnabled)
        XCTAssertTrue(appState.errorMessage?.contains("已恢复直连") == true)
    }

    /// 验证路由写入失败时同样恢复直连并停止已启动服务。
    func testRouteEnableFailureStopsStartedService() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        client.enableError = CodexAuthCLIError.commandFailed("write failed")
        let runtime = StubCPAServiceRuntime(operations: operations)
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.setCPAEnabled(true)

        XCTAssertEqual(operations.values, ["service-start", "route-enable", "route-disable", "service-stop"])
        XCTAssertFalse(appState.isCPAEnabled)
    }

    /// 验证直连回滚失败时保留 CPA 服务，避免把仍指向 CPA 的全局路由变成死路由。
    func testRollbackFailureKeepsCPAServiceRunning() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .cpa), operations: operations)
        client.disableError = CodexAuthCLIError.commandFailed("rollback failed")
        let runtime = StubCPAServiceRuntime(operations: operations, status: .running)
        runtime.startError = CPARuntimeError.unavailable("health failed")
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.setCPAEnabled(true)

        XCTAssertEqual(operations.values, ["service-start", "route-disable"])
        XCTAssertEqual(appState.cpaServiceStatus, .running)
        XCTAssertTrue(appState.errorMessage?.contains("恢复直连失败") == true)
    }

    /// 验证启动时 CPA 路由会重新检查服务和配置。
    func testAppLaunchReconcilesPersistedCPARoute() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .cpa), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations)
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.refreshOnAppLaunch()

        XCTAssertEqual(operations.values, ["service-start", "route-enable"])
        XCTAssertTrue(appState.isCPAEnabled)
    }

    /// 验证启动时直连路由会先覆盖可能残留的 CPA 配置，再停止服务。
    func testAppLaunchReconcilesPersistedDirectRouteBeforeStoppingService() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations, status: .running)
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.refreshOnAppLaunch()

        XCTAssertEqual(operations.values, ["route-disable", "service-stop"])
        XCTAssertFalse(appState.isCPAEnabled)
        XCTAssertEqual(appState.cpaServiceStatus, .stopped)
    }

    /// 验证启动时无法恢复直连配置不会停掉仍可能被全局路由引用的 CPA 服务。
    func testAppLaunchDirectRouteFailureKeepsCPAServiceRunning() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        client.disableError = CodexAuthCLIError.commandFailed("restore failed")
        let runtime = StubCPAServiceRuntime(operations: operations, status: .running)
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.refreshOnAppLaunch()

        XCTAssertEqual(operations.values, ["route-disable"])
        XCTAssertEqual(appState.cpaServiceStatus, .running)
        XCTAssertTrue(appState.errorMessage?.contains("restore failed") == true)
    }

    /// 验证启动对账失败会把持久化 CPA 路由降级为直连。
    func testAppLaunchFailureDowngradesPersistedCPARoute() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .cpa), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations)
        runtime.startError = CPARuntimeError.unavailable("offline")
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.refreshOnAppLaunch()

        XCTAssertFalse(appState.isCPAEnabled)
        XCTAssertEqual(operations.values, ["service-start", "route-disable", "service-stop"])
    }

    /// 验证启动路由对账不会等待只影响展示的全量 Token 扫描。
    func testAppLaunchReconcilesRouteBeforeBackgroundTokenScanCompletes() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .cpa), operations: operations)
        client.recordsTokenUsageOperation = true
        let tokenUsageGate = AsyncOperationGate()
        client.tokenUsageGate = tokenUsageGate
        let runtime = StubCPAServiceRuntime(operations: operations)
        let appState = AppState(client: client, cpaRuntime: runtime)

        let launchRefresh = Task { await appState.refreshOnAppLaunch() }
        await tokenUsageGate.waitUntilSuspended()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(operations.values, ["service-start", "route-enable", "token-scan"])
        XCTAssertFalse(appState.isCPAOperationInProgress)
        XCTAssertTrue(appState.isCPAEnabled)

        await tokenUsageGate.resume()
        await launchRefresh.value
    }

    /// 验证启动对账期间不会接受会反转最终路由的手动操作。
    func testAppLaunchReconciliationBlocksManualRouteAndAccountChanges() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .cpa), operations: operations)
        let runtime = StubCPAServiceRuntime(operations: operations)
        let startGate = AsyncOperationGate()
        runtime.startGate = startGate
        let appState = AppState(client: client, cpaRuntime: runtime)

        let reconciliation = Task { await appState.refreshOnAppLaunch() }
        await startGate.waitUntilSuspended()

        XCTAssertTrue(appState.isCPAOperationInProgress)
        await appState.setCPAEnabled(false)
        await appState.switchAccount(accountKey: "acct-2")
        await startGate.resume()
        await reconciliation.value

        XCTAssertEqual(operations.values, ["service-start", "route-enable"])
        XCTAssertEqual(appState.state?.activeAccountKey, "acct-1")
        XCTAssertTrue(appState.isCPAEnabled)
    }

    /// 验证 CPA 开启期间切换账号只更新关闭后使用的备用连接提示。
    func testSwitchAccountWhileCPAEnabledUpdatesDirectFallback() async {
        let client = StubCodexAuthClient(state: makeState(route: .cpa))
        let appState = AppState(client: client, cpaRuntime: StubCPAServiceRuntime())
        await appState.refresh()

        await appState.switchAccount(accountKey: "acct-2")

        XCTAssertEqual(appState.notice, "已更新备用直连账号。关闭 CPA 后将使用此账号。")
        XCTAssertTrue(appState.isCPAEnabled)
    }

    /// 验证直连状态下切换账号继续使用原有提示。
    func testSwitchAccountWhileDirectUsesDirectNotice() async {
        let client = StubCodexAuthClient(state: makeState(route: .direct))
        let appState = AppState(client: client, cpaRuntime: StubCPAServiceRuntime())
        await appState.refresh()

        await appState.switchAccount(accountKey: "acct-2")

        XCTAssertEqual(appState.notice, "已切换账号。新的 Codex CLI 会话将使用此账号。")
    }

    /// 验证 CPA 启停尚未提交最终路由时不会并发切换备用账号。
    func testCPAOperationBlocksAccountSwitch() async {
        let client = StubCodexAuthClient(state: makeState(route: .direct))
        let runtime = StubCPAServiceRuntime()
        let startGate = AsyncOperationGate()
        runtime.startGate = startGate
        let appState = AppState(client: client, cpaRuntime: runtime)
        await appState.refresh()

        let enable = Task { await appState.setCPAEnabled(true) }
        await startGate.waitUntilSuspended()
        await appState.switchAccount(accountKey: "acct-2")

        XCTAssertEqual(client.state.activeAccountKey, "acct-1")
        await startGate.resume()
        await enable.value
    }

    /// 验证备用账号切换尚未完成时不会并发改写 CPA 全局路由。
    func testAccountSwitchBlocksCPAOperation() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(route: .direct), operations: operations)
        let switchGate = AsyncOperationGate()
        client.switchGate = switchGate
        let appState = AppState(
            client: client,
            cpaRuntime: StubCPAServiceRuntime(operations: operations)
        )
        await appState.refresh()

        let accountSwitch = Task { await appState.switchAccount(accountKey: "acct-2") }
        await switchGate.waitUntilSuspended()
        await appState.setCPAEnabled(true)

        XCTAssertTrue(operations.values.isEmpty)
        await switchGate.resume()
        await accountSwitch.value
        XCTAssertFalse(appState.isCPAEnabled)
    }

    /// 验证管理页动作只委托 CPAMP 运行时，不调用账号 API。
    func testOpenManagementPageDelegatesToRuntime() async {
        let runtime = StubCPAServiceRuntime()
        let appState = AppState(client: StubCodexAuthClient(state: makeState()), cpaRuntime: runtime)

        await appState.openCPAManagementPage()

        XCTAssertEqual(runtime.openManagementCallCount, 1)
    }

    /// 验证打开 NewAPI 管理页后立即刷新服务状态，支持首次初始化展示。
    func testOpenNewAPIManagementPageRefreshesServiceStatus() async {
        let runtime = StubNewAPIServiceRuntime(status: .stopped)
        let appState = AppState(
            client: StubCodexAuthClient(state: makeState()),
            cpaRuntime: StubCPAServiceRuntime(),
            newAPIRuntime: runtime
        )

        await appState.openNewAPIManagementPage()

        XCTAssertEqual(runtime.openManagementCallCount, 1)
        XCTAssertEqual(appState.newAPIServiceStatus, .running)
    }

    /// 验证复制 CPAMP 管理员密钥只委托运行时，并给出完成状态。
    func testCopyManagementKeyDelegatesToRuntime() {
        let runtime = StubCPAServiceRuntime()
        let appState = AppState(client: StubCodexAuthClient(state: makeState()), cpaRuntime: runtime)

        appState.copyCPAManagementKey()

        XCTAssertEqual(runtime.copyManagementKeyCallCount, 1)
        XCTAssertEqual(appState.notice, "已复制 CPAMP 管理员密钥。")
    }

    /// 验证添加 Key 不产生任何 CPA 路由或账号同步调用。
    func testAddAPIKeyOnlyUpdatesDirectConnections() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(), operations: operations)
        let appState = AppState(client: client, cpaRuntime: StubCPAServiceRuntime(operations: operations))

        await appState.addAPIKey(alias: "Relay", provider: .relay, baseURL: "https://relay.example/v1", apiKey: "secret")

        XCTAssertEqual(operations.values, ["add-key"])
        XCTAssertEqual(appState.notice, "已添加 API Key。")
    }

    /// 验证应用启动的本地状态读取和后台 Token 扫描都只执行一次。
    func testAppLaunchRefreshRunsOnlyOnce() async {
        let operations = OperationRecorder()
        let client = StubCodexAuthClient(state: makeState(), operations: operations)
        let tokenUsageGate = AsyncOperationGate()
        client.tokenUsageGate = tokenUsageGate
        let runtime = StubCPAServiceRuntime(operations: operations)
        let appState = AppState(client: client, cpaRuntime: runtime)

        await appState.refreshOnAppLaunch()
        await appState.refreshOnAppLaunch()
        await tokenUsageGate.waitUntilSuspended()

        XCTAssertEqual(client.loadStateCallCount, 1)
        XCTAssertEqual(client.refreshCallCount, 0)
        XCTAssertEqual(client.tokenUsageCallCount, 1)
        await tokenUsageGate.resume()
    }
}

/// 记录跨客户端和运行时的操作顺序。
final class OperationRecorder {
    var values: [String] = []
}

/// 提供可控状态和路由错误的客户端替身。
final class StubCodexAuthClient: CodexAuthClientProtocol {
    var state: CodexAuthState
    var operations: OperationRecorder?
    var enableError: Error?
    var disableError: Error?
    var switchGate: AsyncOperationGate?
    var refreshGate: AsyncOperationGate?
    var loadStateGate: AsyncOperationGate?
    var tokenUsageGate: AsyncOperationGate?
    var recordsLoadStateOperation = false
    var recordsTokenUsageOperation = false
    var loadStateCallCount = 0
    var refreshCallCount = 0
    var tokenUsageCallCount = 0
    var tokenUsageModes: [TokenUsageScanMode] = []

    init(state: CodexAuthState, operations: OperationRecorder? = nil) {
        self.state = state
        self.operations = operations
    }

    /// 返回状态读取开始时的快照，并允许测试暂停结果以复现旧请求晚到。
    func loadState(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState {
        loadStateCallCount += 1
        if recordsLoadStateOperation { operations?.values.append("state") }
        let snapshot = state
        if let loadStateGate { await loadStateGate.suspend() }
        return snapshot
    }

    /// 返回刷新开始时捕获的快照，并允许测试暂停结果以复现旧请求晚到。
    func refresh(apiMode: CodexAuthAPIMode) async throws -> CodexAuthState {
        refreshCallCount += 1
        operations?.values.append("refresh")
        let snapshot = state
        if let refreshGate { await refreshGate.suspend() }
        return snapshot
    }

    /// 记录全量 Token 扫描并允许测试暂停，模拟大日志目录的慢扫描。
    func loadTokenUsage(mode: TokenUsageScanMode) async throws -> TokenUsageInfo {
        tokenUsageCallCount += 1
        tokenUsageModes.append(mode)
        if recordsTokenUsageOperation { operations?.values.append("token-scan") }
        if let tokenUsageGate { await tokenUsageGate.suspend() }
        throw CodexAuthCLIError.commandFailed("token scan unavailable in test")
    }

    func switchAccount(accountKey: String) async throws -> CodexAuthState {
        if let switchGate { await switchGate.suspend() }
        state = makeState(route: state.globalRoute, activeAccountKey: accountKey)
        return state
    }

    func removeAccount(accountKey: String) async throws -> CodexAuthState { state }
    func setAlias(accountKey: String, alias: String) async throws -> CodexAuthState { state }
    func clearAlias(accountKey: String) async throws -> CodexAuthState { state }
    func login() async throws -> CodexAuthState { state }

    func addAPIKey(alias: String, provider: APIKeyProvider, baseURL: String, apiKey: String) async throws -> CodexAuthState {
        operations?.values.append("add-key")
        return state
    }

    func importAuth(path: String, alias: String?) async throws -> CodexAuthState { state }

    func enableCPARoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState {
        operations?.values.append("route-enable")
        if let enableError { throw enableError }
        state = makeState(route: .cpa, activeAccountKey: state.activeAccountKey)
        return state
    }

    /// 记录 NewAPI 全局路由切换并返回对应权威状态。
    func enableNewAPIRoute(baseURL: String, clientConfigurationPath: String) async throws -> CodexAuthState {
        operations?.values.append("newapi-route-enable")
        if let enableError { throw enableError }
        state = makeState(route: .newapi, activeAccountKey: state.activeAccountKey)
        return state
    }

    func disableCPARoute() async throws -> CodexAuthState {
        operations?.values.append("route-disable")
        if let disableError { throw disableError }
        state = makeState(route: .direct, activeAccountKey: state.activeAccountKey)
        return state
    }

    /// 记录 NewAPI 关闭路由并返回直连状态。
    func disableNewAPIRoute() async throws -> CodexAuthState {
        operations?.values.append("newapi-route-disable")
        if let disableError { throw disableError }
        state = makeState(route: .direct, activeAccountKey: state.activeAccountKey)
        return state
    }
}

/// 提供可控启停和管理页行为的 CPA 运行时替身。
final class StubCPAServiceRuntime: CPAServiceRuntimeProtocol {
    var operations: OperationRecorder?
    var currentStatus: CPAServiceStatus
    var startError: Error?
    var stopError: Error?
    var startGate: AsyncOperationGate?
    var openManagementCallCount = 0
    var copyManagementKeyCallCount = 0

    init(operations: OperationRecorder? = nil, status: CPAServiceStatus = .stopped) {
        self.operations = operations
        self.currentStatus = status
    }

    func startAndValidate() async throws -> CPAConfiguration {
        operations?.values.append("service-start")
        if let startGate { await startGate.suspend() }
        if let startError { throw startError }
        currentStatus = .running
        return try CPAConfiguration(
            baseURLString: CPAConfiguration.defaultBaseURL,
            apiKey: "client-key",
            clientConfigurationURL: URL(fileURLWithPath: "/tmp/client.json")
        )
    }

    func stop() async throws {
        operations?.values.append("service-stop")
        if let stopError { throw stopError }
        currentStatus = .stopped
    }

    func status() async -> CPAServiceStatus { currentStatus }

    func openManagementPage() async throws {
        openManagementCallCount += 1
    }

    func copyManagementKey() throws {
        copyManagementKeyCallCount += 1
    }
}

/// 提供可控启停、状态和 Token 保存行为的 NewAPI 运行时替身。
final class StubNewAPIServiceRuntime: NewAPIServiceRuntimeProtocol {
    var operations: OperationRecorder?
    var currentStatus: NewAPIServiceStatus
    var startError: Error?
    var stopError: Error?
    var openManagementCallCount = 0

    init(operations: OperationRecorder? = nil, status: NewAPIServiceStatus = .stopped) {
        self.operations = operations
        self.currentStatus = status
    }

    func startAndValidate() async throws -> NewAPIConfiguration {
        operations?.values.append("newapi-start")
        if let startError { throw startError }
        currentStatus = .running
        return try NewAPIConfiguration(
            baseURLString: NewAPIConfiguration.defaultBaseURL,
            apiKey: "client-key",
            runtimeVersion: NewAPIInstallationPaths.expectedRuntimeVersion,
            clientConfigurationURL: URL(fileURLWithPath: "/tmp/NewAPI/client.json")
        )
    }

    func stop() async throws {
        operations?.values.append("newapi-stop")
        if let stopError { throw stopError }
        currentStatus = .stopped
    }

    func status() async -> NewAPIServiceStatus {
        operations?.values.append("newapi-status")
        return currentStatus
    }

    func openManagementPage() async throws {
        openManagementCallCount += 1
        currentStatus = .running
    }

    func saveAPIKey(_ apiKey: String) throws {}
}

/// 记录应用专属 CPA 渠道同步并允许注入失败。
final class StubNewAPICPAChannelProvisioner: NewAPICPAChannelProvisioning {
    var operations: OperationRecorder?
    var error: Error?

    init(operations: OperationRecorder? = nil) {
        self.operations = operations
    }

    /// 记录同步调用并抛出预设错误。
    func configure() async throws {
        operations?.values.append("newapi-provision")
        if let error { throw error }
    }
}

/// 在异步测试中暂停指定操作，直到测试显式继续。
actor AsyncOperationGate {
    private var isSuspended = false
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    /// 标记操作已进入并等待测试释放。
    func suspend() async {
        isSuspended = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation in
            suspensionContinuation = continuation
        }
    }

    /// 等待被测操作到达稳定暂停点。
    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            observers.append(continuation)
        }
    }

    /// 释放暂停中的操作并重置闸门。
    func resume() {
        isSuspended = false
        suspensionContinuation?.resume()
        suspensionContinuation = nil
    }
}

/// 构造包含两个直连账号的测试状态。
private func makeState(
    route: GlobalRoute = .direct,
    activeAccountKey: String? = "acct-1"
) -> CodexAuthState {
    let accounts = [
        CodexAccount.sample(accountKey: "acct-1", alias: "账号一", isActive: activeAccountKey == "acct-1"),
        CodexAccount.sample(accountKey: "acct-2", alias: "账号二", isActive: activeAccountKey == "acct-2"),
    ]
    return CodexAuthState(
        schemaVersion: 6,
        codexHome: "/tmp/codex",
        globalRoute: route,
        activeAccountKey: activeAccountKey,
        generatedAt: Date(timeIntervalSince1970: 0),
        refresh: RefreshInfo(attempted: false, status: "skipped", message: nil),
        warnings: [],
        accounts: accounts
    )
}
