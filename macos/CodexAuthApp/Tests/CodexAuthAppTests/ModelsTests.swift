import XCTest
@testable import CodexAuthApp

final class ModelsTests: XCTestCase {
    /// 验证桌面端解码根级全局路由，不再从账号字段推断 CPA 状态。
    func testDecodesGlobalCPARoute() throws {
        let json = Data(#"{"schema_version":6,"codex_home":"/tmp/codex","global_route":"cpa","active_account_key":null,"generated_at":"2026-08-05T00:00:00Z","refresh":{"attempted":false,"status":"skipped","message":null},"warnings":[],"accounts":[]}"#.utf8)

        let state = try JSONDecoder.codexAuth.decode(CodexAuthState.self, from: json)

        XCTAssertEqual(state.globalRoute, .cpa)
    }

    /// 验证桌面端识别 NewAPI 路由，并将未知路由安全降级为直连。
    func testDecodesNewAPIAndFallsBackForUnknownGlobalRoute() throws {
        let newapiJSON = Data(#"{"schema_version":6,"codex_home":"/tmp/codex","global_route":"newapi","active_account_key":null,"generated_at":"2026-08-05T00:00:00Z","refresh":{"attempted":false,"status":"skipped","message":null},"warnings":[],"accounts":[]}"#.utf8)
        let unknownJSON = Data(#"{"schema_version":6,"codex_home":"/tmp/codex","global_route":"future-route","active_account_key":null,"generated_at":"2026-08-05T00:00:00Z","refresh":{"attempted":false,"status":"skipped","message":null},"warnings":[],"accounts":[]}"#.utf8)

        let newapiState = try JSONDecoder.codexAuth.decode(CodexAuthState.self, from: newapiJSON)
        let unknownState = try JSONDecoder.codexAuth.decode(CodexAuthState.self, from: unknownJSON)

        XCTAssertEqual(newapiState.globalRoute, .newapi)
        XCTAssertEqual(unknownState.globalRoute, .direct)
    }

    func testAPIKeyConnectionUsesBalanceAndDoesNotRequireQuotaWindows() throws {
        let json = Data("""
        {
          "account_key": "key-relay",
          "display_name": "AI 系统",
          "alias": "AI 系统",
          "email": "api.example.com",
          "account_name": null,
          "plan": null,
          "auth_mode": "apikey",
          "smart_pool_enabled": false,
          "provider_kind": "relay",
          "base_url": "https://api.example.com/v1",
          "balance": {"amount": "999.98", "currency": "USD", "updated_at": 100},
          "is_active": true,
          "usage": {"five_hour": null, "seven_day": {"status": "unsupported", "remaining_percent": null, "total": null, "used": null, "reset_at": null}},
          "last_usage_at": null,
          "last_refresh_at": null
        }
        """.utf8)

        let account = try JSONDecoder.codexAuth.decode(CodexAccount.self, from: json)
        XCTAssertTrue(account.isAPIKey)
        XCTAssertEqual(account.balanceText, "999.98 USD")
        XCTAssertEqual(account.providerKind, "relay")
        XCTAssertEqual(account.baseURL, "https://api.example.com/v1")
        XCTAssertTrue(account.isAvailable)
        XCTAssertNil(account.fiveHourUsageText)
    }

    func testDecodesGuiStateAndDerivesChineseLabels() throws {
        let json = """
        {
          "schema_version": 1,
          "codex_home": "/Users/me/.codex",
          "active_account_key": "acct-1",
          "generated_at": "2026-06-29T12:00:00Z",
          "reset_credits": {
            "available_count": 2,
            "expires_at": "2026-07-30T00:00:00Z"
          },
          "refresh": {
            "attempted": true,
            "status": "ok",
            "message": null
          },
          "warnings": [],
          "accounts": [
            {
              "account_key": "acct-1",
              "display_name": "Work",
              "alias": "工作号",
              "email": "me@example.com",
              "account_name": "Workspace",
              "plan": "pro",
              "auth_mode": "chatgpt",
              "smart_pool_enabled": false,
              "is_active": true,
              "usage": {
                "five_hour": {
                  "status": "ok",
                  "remaining_percent": 99,
                  "total": 100,
                  "used": 1,
                  "reset_at": "2026-06-29T17:00:00Z"
                },
                "seven_day": {
                  "status": "ok",
                  "remaining_percent": 100,
                  "total": 100,
                  "used": 0,
                  "reset_at": "2026-07-06T12:00:00Z"
                }
              },
              "last_usage_at": "2026-06-29T11:58:00Z",
              "last_refresh_at": "2026-06-29T12:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let state = try JSONDecoder.codexAuth.decode(CodexAuthState.self, from: json)

        XCTAssertEqual(state.codexHome, "/Users/me/.codex")
        XCTAssertEqual(state.activeAccount?.accountKey, "acct-1")
        XCTAssertEqual(state.accounts[0].primaryLabel, "工作号")
        XCTAssertEqual(state.accounts[0].secondaryLabel, "me***@example.com")
        XCTAssertEqual(state.accounts[0].planLabel, "Pro")
        XCTAssertEqual(state.accounts[0].fiveHourUsageText, "99%（6月30日 01:00刷新）")
        XCTAssertEqual(state.accounts[0].sevenDayUsageText, "100%（7月6日 20:00刷新）")
        XCTAssertEqual(state.resetCredits?.availableCount, 2)
        XCTAssertEqual(state.resetCredits?.menuBarText, "重置 2次 · 7月30日 08:00")
    }

    /// 验证账号模型不依赖已删除的智能池字段。
    func testAccountDecodesWithoutLegacySmartPoolField() throws {
        let json = """
        {
          "account_key": "acct-legacy",
          "display_name": "Legacy",
          "alias": null,
          "email": null,
          "account_name": null,
          "plan": "plus",
          "auth_mode": "chatgpt",
          "is_active": false,
          "usage": {
            "five_hour": null,
            "seven_day": {
              "status": "ok",
              "remaining_percent": 88,
              "total": 100,
              "used": 12,
              "reset_at": null
            }
          },
          "last_usage_at": null,
          "last_refresh_at": null
        }
        """.data(using: .utf8)!

        let account = try JSONDecoder.codexAuth.decode(CodexAccount.self, from: json)

        XCTAssertTrue(account.isAvailable)
    }

    /// 验证旧删除记录可继续读取，并默认识别为 ChatGPT 账号。
    func testDeletedConnectionRecordKeepsLegacyCompatibility() throws {
        let data = Data(#"{"accountKey":"legacy","label":"旧账号","detail":"me***@example.com","deletedAt":0}"#.utf8)

        let record = try JSONDecoder().decode(DeletedAccountRecord.self, from: data)

        XCTAssertEqual(record.resolvedConnectionType, .account)
    }

    /// 验证旧版已删除 Key 可通过历史 Base URL 继续正确分类。
    func testDeletedConnectionRecordInfersLegacyAPIKeyFromBaseURL() throws {
        let data = Data(#"{"accountKey":"legacy-key","label":"旧 Key","detail":"https://api.openai.com/v1","deletedAt":0}"#.utf8)

        let record = try JSONDecoder().decode(DeletedAccountRecord.self, from: data)

        XCTAssertEqual(record.resolvedConnectionType, .apiKey)
    }

    /// 验证删除 API Key 时只保存脱敏展示信息和连接类型。
    func testDeletedConnectionStoreRecordsAPIKeyTypeWithoutSecret() throws {
        UserDefaults.standard.removeObject(forKey: "deleted-account-records")
        defer { UserDefaults.standard.removeObject(forKey: "deleted-account-records") }
        let data = Data(#"{"account_key":"key-1","display_name":"生产 Key","alias":"生产 Key","email":null,"account_name":"sk-masked","plan":null,"auth_mode":"apikey","smart_pool_enabled":false,"provider_kind":"openai","base_url":"https://api.openai.com/v1","balance":null,"is_active":false,"usage":{"five_hour":null,"seven_day":{"status":"not_applicable","remaining_percent":null,"total":null,"used":null,"reset_at":null}},"last_usage_at":null,"last_refresh_at":null}"#.utf8)
        let account = try JSONDecoder.codexAuth.decode(CodexAccount.self, from: data)

        DeletedAccountStore.append(account)

        let record = try XCTUnwrap(DeletedAccountStore.load().first)
        XCTAssertEqual(record.resolvedConnectionType, .apiKey)
        XCTAssertEqual(record.detail, "https://api.openai.com/v1")
        XCTAssertFalse(record.label.contains("sk-"))
    }

    func testAccountLabelsUseMaskedEmailWhenAliasIsMissing() {
        let account = CodexAccount(
            accountKey: "acct-123456",
            displayName: "me@example.com",
            alias: nil,
            email: "me@example.com",
            accountName: nil,
            plan: "plus",
            authMode: "chatgpt",
            isActive: false,
            usage: UsageInfo(
                fiveHour: UsageWindow(status: "ok", remainingPercent: 88, total: 100, used: 12, resetAt: nil),
                sevenDay: UsageWindow(status: "ok", remainingPercent: 99, total: 100, used: 1, resetAt: nil)
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )

        XCTAssertEqual(account.primaryLabel, "me***@example.com")
        XCTAssertEqual(account.secondaryLabel, "me***@example.com")
    }

    func testAccountAlwaysShowsMaskedEmailAsSecondaryLabelWhenAliasExists() {
        let account = CodexAccount.sample(accountKey: "acct-abcdef", alias: "工作号", isActive: true)

        XCTAssertEqual(account.primaryLabel, "工作号")
        XCTAssertEqual(account.secondaryLabel, "me***@example.com")
    }

    /// 验证默认排序严格保留后端返回的账号添加顺序。
    func testAccountOrderingPreservesAddedOrderByDefault() {
        let accounts = [
            makeAccount(accountKey: "first", remainingPercent: 10),
            makeAccount(accountKey: "second", remainingPercent: 90),
            makeAccount(accountKey: "third", remainingPercent: nil)
        ]

        XCTAssertEqual(AccountOrdering.sorted(accounts, by: .added).map(\.accountKey), ["first", "second", "third"])
    }

    /// 验证额度排序降序、未知值置后，并保持相同额度的添加顺序。
    func testAccountOrderingSortsQuotaDescendingAndStably() {
        let accounts = [
            makeAccount(accountKey: "low", remainingPercent: 10),
            makeAccount(accountKey: "high-first", remainingPercent: 90),
            makeAccount(accountKey: "unknown", remainingPercent: nil),
            makeAccount(accountKey: "high-second", remainingPercent: 90)
        ]

        XCTAssertEqual(
            AccountOrdering.sorted(accounts, by: .quota).map(\.accountKey),
            ["high-first", "high-second", "low", "unknown"]
        )
    }

    /// 验证异常窗口尺寸恢复默认值，合法用户尺寸保持不变。
    func testManagementWindowLayoutNormalizesInvalidContentSize() {
        XCTAssertEqual(
            ManagementWindowLayout.normalizedContentSize(NSSize(width: 1_600, height: 120)),
            ManagementWindowLayout.defaultContentSize
        )
        XCTAssertEqual(
            ManagementWindowLayout.normalizedContentSize(NSSize(width: 1_100, height: 700)),
            NSSize(width: 1_100, height: 700)
        )
    }

    func testUnknownUsageUsesChineseFallback() throws {
        let window = UsageWindow(status: "missing_auth", remainingPercent: nil, total: nil, used: nil, resetAt: nil)

        XCTAssertEqual(window.displayText, "未知")
        XCTAssertEqual(window.detailText, "缺少认证信息")
    }

    func testUsageOverrideStatusIsDisplayedDirectly() {
        let window = UsageWindow(status: "401 token_invalidated", remainingPercent: nil, total: nil, used: nil, resetAt: nil)

        XCTAssertEqual(window.displayText, "401 token_invalidated")
        XCTAssertEqual(window.displayTextWithReset, "401 token_invalidated")
        XCTAssertEqual(window.menuBarPercentText, "--")
    }

    /// 验证终止性认证错误仍可用于直连账号状态展示。
    func testDetectsTerminalAuthenticationFailuresOnly() {
        let invalidated = makeAccount(accountKey: "invalidated", usageStatus: "401 token_invalidated")
        let revoked = makeAccount(accountKey: "revoked", usageStatus: "401 token_revoked")
        XCTAssertTrue(invalidated.hasTerminalAuthenticationFailure)
        XCTAssertTrue(revoked.hasTerminalAuthenticationFailure)
    }

    func testLowUsageThresholdIsBelowTwentyPercent() {
        let low = UsageWindow(status: "ok", remainingPercent: 19, total: 100, used: 81, resetAt: nil)
        let boundary = UsageWindow(status: "ok", remainingPercent: 20, total: 100, used: 80, resetAt: nil)
        let unknown = UsageWindow(status: "missing_auth", remainingPercent: nil, total: nil, used: nil, resetAt: nil)

        XCTAssertTrue(low.isLowRemaining)
        XCTAssertFalse(boundary.isLowRemaining)
        XCTAssertFalse(unknown.isLowRemaining)
    }

    func testMenuBarQuotaLinesUseCompactFiveHourAndSevenDayText() {
        let account = CodexAccount(
            accountKey: "acct-123456",
            displayName: "me@example.com",
            alias: "工作号",
            email: "me@example.com",
            accountName: nil,
            plan: "plus",
            authMode: "chatgpt",
            isActive: true,
            usage: UsageInfo(
                fiveHour: UsageWindow(status: "ok", remainingPercent: 99, total: 100, used: 1, resetAt: nil),
                sevenDay: UsageWindow(status: "ok", remainingPercent: 100, total: 100, used: 0, resetAt: nil)
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )

        XCTAssertEqual(account.menuBarFiveHourText, "5h 99%")
        XCTAssertEqual(account.menuBarSevenDayText, "7d 100%")
    }

    func testMenuBarQuotaUsesFallbackForUnknownUsage() {
        let window = UsageWindow(status: "network_error", remainingPercent: nil, total: nil, used: nil, resetAt: nil)

        XCTAssertEqual(window.menuBarPercentText, "--")
        XCTAssertEqual(window.menuBarUsageTone, .unavailable)
    }

    /// 验证仅返回周窗口时可正常解码，并保留窗口缺失语义。
    func testDecodesUsageWithoutFiveHourWindow() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": {
            "status": "ok",
            "remaining_percent": 93,
            "total": 100,
            "used": 7,
            "reset_at": null
          }
        }
        """.data(using: .utf8)!

        let usage = try JSONDecoder.codexAuth.decode(UsageInfo.self, from: json)

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay.remainingPercent, 93)
    }

    /// 验证菜单栏额度在 20% 和 50% 边界正确切换红、黄、绿三档。
    func testMenuBarQuotaToneUsesGreenYellowAndRedThresholds() {
        let low = UsageWindow(status: "ok", remainingPercent: 19, total: 100, used: 81, resetAt: nil)
        let warningLowerBoundary = UsageWindow(status: "ok", remainingPercent: 20, total: 100, used: 80, resetAt: nil)
        let warningUpperBoundary = UsageWindow(status: "ok", remainingPercent: 49, total: 100, used: 51, resetAt: nil)
        let available = UsageWindow(status: "ok", remainingPercent: 50, total: 100, used: 50, resetAt: nil)

        XCTAssertEqual(low.menuBarUsageTone, .low)
        XCTAssertEqual(warningLowerBoundary.menuBarUsageTone, .warning)
        XCTAssertEqual(warningUpperBoundary.menuBarUsageTone, .warning)
        XCTAssertEqual(available.menuBarUsageTone, .available)
    }

    func testStatusItemPresentationUsesVisibleSingleLineSegments() {
        let account = CodexAccount(
            accountKey: "acct-123456",
            displayName: "me@example.com",
            alias: "工作号",
            email: "me@example.com",
            accountName: nil,
            plan: "plus",
            authMode: "chatgpt",
            isActive: true,
            usage: UsageInfo(
                fiveHour: UsageWindow(status: "ok", remainingPercent: 99, total: 100, used: 1, resetAt: nil),
                sevenDay: UsageWindow(status: "ok", remainingPercent: 12, total: 100, used: 88, resetAt: nil)
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )

        let presentation = StatusItemPresentation(account: account, isLoading: false)

        XCTAssertEqual(presentation.plainText, "12%")
        XCTAssertEqual(presentation.segments.map(\.tone), [.low])
        XCTAssertLessThan(presentation.minimumStatusItemLength, 50)
    }

    /// 验证 API Key 直连在菜单栏显示明确模式，不使用缺失额度占位符。
    func testStatusItemPresentationShowsAPIKeyMode() {
        let account = CodexAccount(
            accountKey: "key-agent-router",
            displayName: "AgentRouter",
            alias: "AgentRouter",
            email: nil,
            accountName: "sk-test",
            plan: nil,
            authMode: "apikey",
            providerKind: "relay",
            baseURL: "https://agentrouter.org/v1",
            isActive: true,
            usage: UsageInfo(
                fiveHour: nil,
                sevenDay: UsageWindow(
                    status: "not_applicable",
                    remainingPercent: nil,
                    total: nil,
                    used: nil,
                    resetAt: nil
                )
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )

        let presentation = StatusItemPresentation(account: account, isLoading: false)

        XCTAssertEqual(presentation.plainText, "KEY")
        XCTAssertEqual(presentation.segments.map(\.tone), [.unavailable])
    }

    /// 验证 NewAPI 模式收起后显示可读连接状态，不再显示直连账号额度。
    func testStatusItemPresentationShowsNewAPIHealthState() {
        let presentation = StatusItemPresentation(
            account: nil,
            isLoading: false,
            globalRoute: .newapi,
            newAPIServiceStatus: .running
        )

        XCTAssertEqual(presentation.statusBarButtonText, "NewAPI · 已连接")
        XCTAssertEqual(presentation.segments.map(\.tone), [.available])
    }

    /// 验证额度文案变化时状态项宽度保持稳定，且短文案仍围绕弹窗锚点居中。
    func testStatusItemPresentationKeepsStableWidthAndCentersShortText() {
        let unavailable = StatusItemPresentation(account: nil, isLoading: false)
        let warning = StatusItemPresentation(
            account: makeAccount(accountKey: "warning", remainingPercent: 26),
            isLoading: false
        )
        let full = StatusItemPresentation(
            account: makeAccount(accountKey: "full", remainingPercent: 100),
            isLoading: false
        )

        XCTAssertEqual(unavailable.minimumStatusItemLength, warning.minimumStatusItemLength)
        XCTAssertEqual(warning.minimumStatusItemLength, full.minimumStatusItemLength)
        XCTAssertEqual(unavailable.horizontalOrigin(containerWidth: 42, contentWidth: 28), 7)
    }

    /// 验证缺少 5 小时窗口时菜单栏只保留周用量片段。
    func testStatusItemPresentationOmitsMissingFiveHourSegment() {
        let account = CodexAccount(
            accountKey: "acct-123456",
            displayName: "me@example.com",
            alias: "工作号",
            email: "me@example.com",
            accountName: nil,
            plan: "plus",
            authMode: "chatgpt",
            isActive: true,
            usage: UsageInfo(
                fiveHour: nil,
                sevenDay: UsageWindow(status: "ok", remainingPercent: 93, total: 100, used: 7, resetAt: nil)
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )

        let presentation = StatusItemPresentation(account: account, isLoading: false)

        XCTAssertEqual(presentation.plainText, "93%")
        XCTAssertEqual(presentation.segments.map(\.tone), [.available])
        XCTAssertLessThan(presentation.minimumStatusItemLength, 50)
        XCTAssertEqual(StatusItemPresentation.capsuleHorizontalPadding, 14)
        XCTAssertEqual(StatusItemPresentation.statusItemOuterPadding, 2)
    }

    func testStatusItemPresentationShowsResetCredits() {
        let account = CodexAccount.sample(accountKey: "acct-123456", alias: "工作号", isActive: true)
        let resetCredits = ResetCreditsInfo(
            availableCount: 1,
            expiresAt: Date(timeIntervalSince1970: 1_783_046_400)
        )

        let presentation = StatusItemPresentation(
            account: account,
            isLoading: false,
            resetCredits: resetCredits
        )

        XCTAssertEqual(presentation.plainText, "100%")
        XCTAssertEqual(presentation.segments.last?.tone, .available)
        XCTAssertEqual(resetCredits.accountDetailText, "重置 1次 · 最近到期 7月3日 10:40")
    }

    /// 验证单行额度在菜单栏高度内垂直居中，避免文字在移除 5 小时窗口后上移。
    func testStatusItemPresentationCentersSingleLine() {
        let presentation = StatusItemPresentation(account: nil, isLoading: false)

        XCTAssertEqual(
            presentation.lineOrigins(containerHeight: 24, textHeight: 11, lineSpacing: 10),
            [6]
        )
    }

    /// 验证双行额度作为整体居中，并保持从上到下的固定行距。
    func testStatusItemPresentationCentersTwoLines() {
        let account = CodexAccount(
            accountKey: "acct-123456",
            displayName: "me@example.com",
            alias: "工作号",
            email: "me@example.com",
            accountName: nil,
            plan: "plus",
            authMode: "chatgpt",
            isActive: true,
            usage: UsageInfo(
                fiveHour: UsageWindow(status: "ok", remainingPercent: 90, total: 100, used: 10, resetAt: nil),
                sevenDay: UsageWindow(status: "ok", remainingPercent: 80, total: 100, used: 20, resetAt: nil)
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )
        let presentation = StatusItemPresentation(account: account, isLoading: false)

        XCTAssertEqual(
            presentation.lineOrigins(containerHeight: 24, textHeight: 11, lineSpacing: 10),
            [6]
        )
    }

    /// 构造指定周额度的排序测试账号。
    private func makeAccount(accountKey: String, remainingPercent: Int?) -> CodexAccount {
        makeAccount(
            accountKey: accountKey,
            usageStatus: remainingPercent == nil ? "network_error" : "ok",
            remainingPercent: remainingPercent
        )
    }

    /// 构造指定周额度状态的测试账号，集中验证认证失败与普通不可用状态的差异。
    private func makeAccount(
        accountKey: String,
        usageStatus: String,
        remainingPercent: Int? = nil
    ) -> CodexAccount {
        CodexAccount(
            accountKey: accountKey,
            displayName: accountKey,
            alias: accountKey,
            email: "\(accountKey)@example.com",
            accountName: nil,
            plan: "plus",
            authMode: "chatgpt",
            isActive: false,
            usage: UsageInfo(
                fiveHour: nil,
                sevenDay: UsageWindow(
                    status: usageStatus,
                    remainingPercent: remainingPercent,
                    total: remainingPercent == nil ? nil : 100,
                    used: remainingPercent.map { 100 - $0 },
                    resetAt: nil
                )
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )
    }
}
