import AppKit
import SwiftUI

/// 定义统一管理窗口可导航的目标页面。
enum ManagementSection: String, CaseIterable, Identifiable {
    case accounts
    case addAccount
    case routing
    case usage
    case settings

    var id: String { rawValue }

    /// 仅返回应该出现在窗口侧栏中的稳定页面。
    static var sidebarCases: [ManagementSection] {
        [.accounts, .routing, .usage, .settings]
    }

    /// 将“添加账号”入口归一到账号页，并通过 sheet 表达具体动作。
    var sidebarSelection: ManagementSection {
        self == .addAccount ? .accounts : self
    }

    var title: String {
        switch self {
        case .accounts, .addAccount:
            return "账号"
        case .routing:
            return "路由"
        case .usage:
            return "统计"
        case .settings:
            return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts, .addAccount:
            return "person.2"
        case .routing:
            return "point.3.connected.trianglepath.dotted"
        case .usage:
            return "chart.bar"
        case .settings:
            return "gearshape"
        }
    }
}

/// 持有并复用唯一管理窗口，重复入口只切换内容和前置窗口。
@MainActor
final class ManagementWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var window: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// 创建或复用管理窗口，并导航到指定页面。
    func show(section: ManagementSection) {
        let rootView = ManagementRootView(initialSection: section)
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: rootView)

        if let window {
            window.contentViewController = hostingController
            window.title = section.sidebarSelection.title
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: hostingController)
            window.title = section.sidebarSelection.title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 920, height: 620))
            window.minSize = NSSize(width: 760, height: 500)
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 提供账号、路由、统计和设置四个页面的统一侧栏。
private struct ManagementRootView: View {
    @State private var selection: ManagementSection
    private let opensAddAccountOnAppear: Bool

    init(initialSection: ManagementSection) {
        _selection = State(initialValue: initialSection.sidebarSelection)
        opensAddAccountOnAppear = initialSection == .addAccount
    }

    var body: some View {
        NavigationSplitView {
            List(ManagementSection.sidebarCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Codex Auth")
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 190)
        } detail: {
            selectedPage
        }
    }

    /// 根据侧栏选择装载页面，账号内部继续使用列表与详情双栏。
    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .accounts, .addAccount:
            ManageAccountsView(opensAddAccountOnAppear: opensAddAccountOnAppear)
        case .routing:
            RoutingManagementView()
        case .usage:
            UsageManagementView()
        case .settings:
            SettingsManagementView()
        }
    }
}

/// 展示 CPA 连接、固定路由策略和当前智能池成员。
private struct RoutingManagementView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("智能路由")
                        .font(.title2.weight(.semibold))
                    Text(appState.cpaConnectionStatus.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("检查连接") {
                    Task { await appState.refreshCPAConnection() }
                }
            }

            HStack(spacing: 12) {
                routingMetric(title: "服务地址", value: "127.0.0.1:8317")
                routingMetric(title: "策略", value: "轮询")
                routingMetric(title: "会话黏性", value: "1 小时")
                routingMetric(title: "可用账号", value: "\(availableAccounts.count) / \(poolAccounts.count)")
            }

            List(poolAccounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.primaryLabel)
                        Text(account.secondaryLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(account.usage.sevenDay.displayText)
                        .monospacedDigit()
                    Circle()
                        .fill(account.isAvailable ? Color.accentColor : Color.red)
                        .frame(width: 8, height: 8)
                }
            }
            .overlay {
                if poolAccounts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.slash")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("智能池为空")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle("路由")
    }

    /// 统一路由摘要卡片的标题和值样式。
    private func routingMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var poolAccounts: [CodexAccount] {
        (appState.state?.accounts ?? []).filter(\.participatesInSmartPool)
    }

    private var availableAccounts: [CodexAccount] {
        poolAccounts.filter(\.isAvailable)
    }
}

/// 在管理窗口中承载完整 Token 汇总和刷新入口。
private struct UsageManagementView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Token 统计")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("刷新") {
                    Task { await appState.refreshOnMenuOpen() }
                }
            }
            TokenUsageView(info: appState.tokenUsage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .navigationTitle("统计")
    }
}

/// 展示当前生效的安全边界和刷新行为，不提供尚未接入的伪设置项。
private struct SettingsManagementView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("CPA") {
                LabeledContent("连接状态", value: appState.cpaConnectionStatus.label)
                LabeledContent("默认地址", value: CPAConfiguration.defaultBaseURL)
                LabeledContent("访问范围", value: "仅本机")
            }
            Section("刷新") {
                LabeledContent("打开菜单", value: "全量刷新")
                LabeledContent("周期任务", value: "额度刷新")
                LabeledContent("CPA 请求事件", value: "Token 增量刷新")
            }
            Section("账号") {
                LabeledContent("智能池默认值", value: "加入")
                LabeledContent("官方 CLI 直连", value: "仅影响新会话")
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .navigationTitle("设置")
    }
}
