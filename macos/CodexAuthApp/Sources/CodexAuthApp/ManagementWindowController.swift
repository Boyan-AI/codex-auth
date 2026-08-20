import AppKit
import SwiftUI

/// 定义统一管理窗口可导航的目标页面。
enum ManagementSection: String, CaseIterable, Identifiable {
    case accounts
    case addAccount
    case usage
    case settings

    var id: String { rawValue }

    /// 仅返回应该出现在窗口侧栏中的稳定页面。
    static var sidebarCases: [ManagementSection] {
        [.accounts, .usage, .settings]
    }

    /// 将“添加账号”入口归一到账号页，并通过 sheet 表达具体动作。
    var sidebarSelection: ManagementSection {
        self == .addAccount ? .accounts : self
    }

    var title: String {
        switch self {
        case .accounts, .addAccount:
            return "账号"
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

/// 提供账号、统计和设置页面的统一侧栏。
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
        case .usage:
            UsageManagementView()
        case .settings:
            SettingsManagementView()
        }
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
    @EnvironmentObject private var appState: AppState
    @State private var newAPITokenDraft = ""
    @State private var isEditingNewAPIToken = false

    var body: some View {
        Form {
            Section("NewAPI 调用 Token") {
                VStack(alignment: .leading, spacing: 10) {
                    if appState.hasSavedNewAPIToken && !isEditingNewAPIToken {
                        Text("••••••••••••")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("粘贴 NewAPI Token", text: $newAPITokenDraft)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text(appState.newAPIServiceStatus.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("打开管理页") {
                            Task { await appState.openNewAPIManagementPage() }
                        }
                        .disabled(appState.newAPIServiceStatus == .notInstalled)
                        Button("保存 Token") {
                            let token = newAPITokenDraft
                            Task { await appState.saveNewAPIToken(token) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            appState.hasSavedNewAPIToken && !isEditingNewAPIToken
                                || newAPITokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        Button("清除") {
                            newAPITokenDraft = ""
                            isEditingNewAPIToken = false
                            Task { await appState.clearNewAPIToken() }
                        }
                        .disabled(!appState.hasSavedNewAPIToken)
                    }
                }
            }

        }
        .formStyle(.grouped)
        .padding(16)
        .navigationTitle("设置")
        .onAppear {
            Task { await appState.refreshNewAPIServiceStatus() }
        }
    }
}
