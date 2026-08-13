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

/// 统一管理窗口的默认尺寸，并过滤 SwiftUI sheet 造成的异常内容尺寸。
enum ManagementWindowLayout {
    static let defaultContentSize = NSSize(width: 920, height: 620)
    static let minimumContentSize = NSSize(width: 760, height: 500)

    /// 仅复用合法的历史内容尺寸，任一方向过小时恢复默认尺寸。
    static func normalizedContentSize(_ size: NSSize) -> NSSize {
        guard size.width >= minimumContentSize.width,
              size.height >= minimumContentSize.height
        else {
            return defaultContentSize
        }
        return size
    }
}

/// 分别持有管理窗口和独立登录窗口，避免简单登录操作套用完整管理界面。
@MainActor
final class ManagementWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private var window: NSWindow?
    private var loginWindow: NSWindow?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// 创建或复用管理窗口，并导航到指定页面。
    func show(section: ManagementSection) {
        if section == .addAccount {
            showAddAccountWindow()
            return
        }

        loginWindow?.orderOut(nil)
        let rootView = ManagementRootView(initialSection: section)
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: rootView)

        if let window {
            let contentSize = ManagementWindowLayout.normalizedContentSize(window.contentLayoutRect.size)
            if let attachedSheet = window.attachedSheet {
                window.endSheet(attachedSheet)
                attachedSheet.orderOut(nil)
            }
            window.contentViewController = hostingController
            window.contentMinSize = ManagementWindowLayout.minimumContentSize
            window.setContentSize(contentSize)
            window.title = section.sidebarSelection.title
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentViewController: hostingController)
            window.title = section.sidebarSelection.title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = ManagementWindowLayout.minimumContentSize
            window.setContentSize(ManagementWindowLayout.defaultContentSize)
            window.center()
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 创建或复用固定尺寸的独立添加账号窗口。
    private func showAddAccountWindow() {
        window?.attachedSheet?.orderOut(nil)
        window?.orderOut(nil)

        let rootView = AddConnectionForm(
            onCancel: { [weak self] in self?.loginWindow?.orderOut(nil) },
            onAccount: { [weak self] alias in
                guard let self else { return }
                self.loginWindow?.orderOut(nil)
                Task { await self.appState.login(alias: alias) }
            },
            onAPIKey: { [weak self] alias, provider, baseURL, apiKey in
                guard let self else { return }
                self.loginWindow?.orderOut(nil)
                Task { await self.appState.addAPIKey(alias: alias, provider: provider, baseURL: baseURL, apiKey: apiKey) }
            }
        )
        let hostingController = NSHostingController(rootView: rootView)

        if let loginWindow {
            loginWindow.contentViewController = hostingController
            loginWindow.setContentSize(NSSize(width: 460, height: 300))
            loginWindow.center()
            loginWindow.makeKeyAndOrderFront(nil)
        } else {
            let loginWindow = NSWindow(contentViewController: hostingController)
            loginWindow.title = "添加账号"
            loginWindow.styleMask = [.titled, .closable]
            loginWindow.setContentSize(NSSize(width: 460, height: 300))
            loginWindow.center()
            loginWindow.isReleasedWhenClosed = false
            loginWindow.hidesOnDeactivate = false
            loginWindow.level = .floating
            self.loginWindow = loginWindow
            loginWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单栏弹出前暂时隐藏所有独立窗口，避免激活 App 时一并前置。
    func hideForPopover() {
        window?.attachedSheet?.orderOut(nil)
        window?.orderOut(nil)
        loginWindow?.orderOut(nil)
    }
}

/// 提供账号、路由、统计和设置四个页面的统一侧栏。
private struct ManagementRootView: View {
    @State private var selection: ManagementSection

    init(initialSection: ManagementSection) {
        _selection = State(initialValue: initialSection.sidebarSelection)
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
            ManageAccountsView()
        case .routing:
            RoutingManagementView()
        case .usage:
            UsageManagementView()
        case .settings:
            SettingsManagementView()
        }
    }
}

/// 展示 CPA 独立服务状态、全局开关和 CPAMP Full Mode 管理页入口。
private struct RoutingManagementView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPA 服务")
                        .font(.title2.weight(.semibold))
                    Text(appState.cpaServiceStatus.label)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "全局路由",
                    isOn: Binding(
                        get: { appState.isCPAEnabled },
                        set: { enabled in Task { await appState.setCPAEnabled(enabled) } }
                    )
                )
                .toggleStyle(.switch)
                .disabled(appState.isCPAOperationInProgress || appState.isAccountSwitchInProgress)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 14) {
                GridRow {
                    Text("服务地址")
                    Text("http://127.0.0.1:8317")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("管理地址")
                    Text("http://127.0.0.1:18317")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("当前路由")
                    Text(appState.isCPAEnabled ? "CPA" : "直连")
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("备用连接")
                    Text(appState.state?.activeAccount?.primaryLabel ?? "未选择")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    Task { await appState.refreshCPAServiceStatus() }
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                Button {
                    appState.copyCPAManagementKey()
                } label: {
                    Label("复制 CPAMP 管理员密钥", systemImage: "doc.on.doc")
                }
                .disabled(appState.cpaServiceStatus == .notInstalled || appState.isCPAOperationInProgress)
                Spacer()
                Button {
                    Task { await appState.openCPAManagementPage() }
                } label: {
                    Label("打开管理页", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.cpaServiceStatus != .running || appState.isCPAOperationInProgress)
            }

            Spacer()
        }
        .padding(24)
        .navigationTitle("路由")
        .task { await appState.refreshCPAServiceStatus() }
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
                    Task { await appState.refreshUsage() }
                }
            }
            TokenUsageView(info: appState.tokenUsage)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(24)
        .navigationTitle("统计")
    }
}

/// 仅保留真正可编辑的额度代理，并用简短说明标注生效范围。
private struct SettingsManagementView: View {
    @AppStorage(QuotaProxyConfiguration.userDefaultsKey) private var savedQuotaProxyURL = ""
    @State private var quotaProxyDraft = ""

    var body: some View {
        Form {
            Section("额度刷新代理") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("例如 http://127.0.0.1:7897", text: $quotaProxyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveProxy)

                    HStack {
                        Text(proxyStatusText)
                            .font(.caption)
                            .foregroundStyle(isProxyInvalid ? Color.red : Color.secondary)
                        Spacer()
                        Button("清除", action: clearProxy)
                            .disabled(savedQuotaProxyURL.isEmpty && normalizedProxyDraft.isEmpty)
                        Button("保存", action: saveProxy)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSaveProxy)
                    }
                }
            }

            Section("生效范围") {
                LabeledContent("用途", value: "仅账号额度刷新")
                LabeledContent("未配置时", value: "使用系统网络")
                LabeledContent("不会影响", value: "CPA 与官方 CLI 会话")
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .navigationTitle("设置")
        .onAppear {
            quotaProxyDraft = savedQuotaProxyURL
        }
    }

    private var normalizedProxyDraft: String {
        quotaProxyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isProxyInvalid: Bool {
        !normalizedProxyDraft.isEmpty &&
            QuotaProxyConfiguration.environment(proxyURL: normalizedProxyDraft) == nil
    }

    private var canSaveProxy: Bool {
        !normalizedProxyDraft.isEmpty &&
            !isProxyInvalid &&
            normalizedProxyDraft != savedQuotaProxyURL
    }

    private var proxyStatusText: String {
        if isProxyInvalid {
            return "地址格式无效，支持 http、https、socks5 和 socks5h"
        }
        if normalizedProxyDraft == savedQuotaProxyURL, !savedQuotaProxyURL.isEmpty {
            return "已保存"
        }
        if normalizedProxyDraft.isEmpty {
            return "未配置"
        }
        return "修改后点击保存"
    }

    /// 校验通过后一次性持久化代理，避免输入过程立即影响后台刷新。
    private func saveProxy() {
        guard canSaveProxy else { return }
        savedQuotaProxyURL = normalizedProxyDraft
        quotaProxyDraft = normalizedProxyDraft
    }

    /// 同时清空编辑值和已保存值，恢复使用系统网络。
    private func clearProxy() {
        quotaProxyDraft = ""
        savedQuotaProxyURL = ""
    }
}
