import XCTest
@testable import CodexAuthApp

final class ConnectionReconnectTests: XCTestCase {
    /// 验证 ChatGPT 连接保持 OAuth 重新登录入口。
    func testChatGPTAccountUsesReloginAction() {
        let account = makeAccount(authMode: "chatgpt")
        let action = ConnectionReconnectAction(account: account)

        XCTAssertEqual(action.buttonTitle, "重新登录")
        guard case .account = action else {
            return XCTFail("ChatGPT account should open the account login sheet")
        }
    }

    /// 验证 API Key 使用重新添加入口，而不是 OAuth 登录入口。
    func testAPIKeyUsesReaddAction() {
        let account = makeAccount(authMode: "apikey", providerKind: "relay", baseURL: "https://relay.example/v1")
        let action = ConnectionReconnectAction(account: account)

        XCTAssertEqual(action.buttonTitle, "重新添加 Key")
        guard case .apiKey = action else {
            return XCTFail("API Key should open the key-only sheet")
        }
    }

    /// 验证普通添加入口继续默认展示账号与 Key 类型选择器。
    func testAddingConfigurationKeepsExistingSelectorDefaults() {
        let configuration = ConnectionFormConfiguration.adding

        XCTAssertEqual(configuration.title, "添加连接")
        XCTAssertEqual(configuration.initialType, .account)
        XCTAssertTrue(configuration.allowsTypeSelection)
        XCTAssertEqual(configuration.initialProvider, .openai)
        XCTAssertEqual(configuration.initialBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(configuration.initialAPIKey, "")
    }

    /// 验证 Key 表单只预填非敏感元数据，密钥始终为空。
    func testAPIKeyReconnectConfigurationPrefillsMetadataWithoutSecret() {
        let account = makeAccount(
            authMode: "apikey",
            alias: "生产 Key",
            providerKind: "relay",
            baseURL: "https://relay.example/v1"
        )
        let configuration = ConnectionFormConfiguration.readdingAPIKey(for: account)

        XCTAssertEqual(configuration.title, "重新添加 Key")
        XCTAssertEqual(configuration.initialType, .apiKey)
        XCTAssertFalse(configuration.allowsTypeSelection)
        XCTAssertEqual(configuration.initialAlias, "生产 Key")
        XCTAssertEqual(configuration.initialProvider, .relay)
        XCTAssertEqual(configuration.initialBaseURL, "https://relay.example/v1")
        XCTAssertEqual(configuration.initialAPIKey, "")
    }

    /// 验证 OpenAI Key 保持官方 provider 与固定 Base URL。
    func testOpenAIReconnectConfigurationKeepsOfficialProvider() {
        let account = makeAccount(
            authMode: "apikey",
            providerKind: "openai",
            baseURL: "https://api.openai.com/v1"
        )
        let configuration = ConnectionFormConfiguration.readdingAPIKey(for: account)

        XCTAssertEqual(configuration.initialProvider, .openai)
        XCTAssertEqual(configuration.initialBaseURL, "https://api.openai.com/v1")
    }

    /// 验证缺少 OpenAI Base URL 时使用官方默认地址。
    func testOpenAIReconnectConfigurationUsesDefaultBaseURLWhenMissing() {
        let account = makeAccount(authMode: "apikey", providerKind: "openai", baseURL: nil)
        let configuration = ConnectionFormConfiguration.readdingAPIKey(for: account)

        XCTAssertEqual(configuration.initialProvider, .openai)
        XCTAssertEqual(configuration.initialBaseURL, "https://api.openai.com/v1")
    }

    /// 验证未知 provider 不会把自定义地址误当成 OpenAI 官方地址。
    func testUnknownProviderFallsBackToRelay() {
        let account = makeAccount(authMode: "apikey", providerKind: "custom", baseURL: "https://custom.example/v1")
        let configuration = ConnectionFormConfiguration.readdingAPIKey(for: account)

        XCTAssertEqual(configuration.initialProvider, .relay)
        XCTAssertEqual(configuration.initialBaseURL, "https://custom.example/v1")
    }

    /// 构造不包含密钥原文的连接记录，供纯展示决策测试复用。
    private func makeAccount(
        authMode: String,
        alias: String? = nil,
        providerKind: String? = nil,
        baseURL: String? = nil
    ) -> CodexAccount {
        CodexAccount(
            accountKey: "test-\(authMode)-\(providerKind ?? "none")",
            displayName: alias ?? "测试连接",
            alias: alias,
            email: authMode == "apikey" ? nil : "me@example.com",
            accountName: authMode == "apikey" ? "sk-masked" : nil,
            plan: authMode == "apikey" ? nil : "plus",
            authMode: authMode,
            providerKind: providerKind,
            baseURL: baseURL,
            balance: nil,
            isActive: false,
            usage: UsageInfo(
                fiveHour: nil,
                sevenDay: UsageWindow(
                    status: authMode == "apikey" ? "not_applicable" : "ok",
                    remainingPercent: authMode == "apikey" ? nil : 100,
                    total: authMode == "apikey" ? nil : 100,
                    used: authMode == "apikey" ? nil : 0,
                    resetAt: nil
                )
            ),
            lastUsageAt: nil,
            lastRefreshAt: nil
        )
    }
}
