import XCTest
@testable import CodexAuthApp

final class ModelsTests: XCTestCase {
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
        XCTAssertFalse(state.accounts[0].participatesInSmartPool)
        XCTAssertEqual(state.accounts[0].fiveHourUsageText, "99%（6月30日 01:00刷新）")
        XCTAssertEqual(state.accounts[0].sevenDayUsageText, "100%（7月6日 20:00刷新）")
        XCTAssertEqual(state.resetCredits?.availableCount, 2)
        XCTAssertEqual(state.resetCredits?.menuBarText, "重置 2次 · 7月30日 08:00")
    }

    /// 验证旧 GUI 输出缺少智能池字段时仍默认加入，兼容 schema 5 之前的版本。
    func testMissingSmartPoolFieldDefaultsToIncluded() throws {
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

        XCTAssertTrue(account.participatesInSmartPool)
        XCTAssertTrue(account.isAvailable)
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
            smartPoolEnabled: true,
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
            smartPoolEnabled: true,
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
            smartPoolEnabled: true,
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
        XCTAssertLessThan(presentation.minimumStatusItemLength, 45)
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
            smartPoolEnabled: true,
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
        XCTAssertLessThan(presentation.minimumStatusItemLength, 45)
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
            smartPoolEnabled: true,
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
}
