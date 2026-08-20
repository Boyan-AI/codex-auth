import SwiftUI

/// 接管菜单栏 App 的退出确认，确保异步恢复直连和停服完成后再终止进程。
final class CodexAuthAppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var isTerminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        // AppKit 可能在异步清理期间重复询问；清理已经启动时直接放行，避免返回 terminateLater 却没有新的 reply。
        guard !isTerminationInProgress else { return .terminateNow }
        isTerminationInProgress = true
        let application = sender
        let state = appState
        Task { @MainActor [weak self] in
            let canTerminate = await state.shutdown()
            application.reply(toApplicationShouldTerminate: canTerminate)
            self?.isTerminationInProgress = false
        }
        return .terminateLater
    }
}

@main
struct CodexAuthMenuApp: App {
    @NSApplicationDelegateAdaptor(CodexAuthAppDelegate.self) private var appDelegate
    private let appState: AppState
    private let statusItemController: StatusItemController

    /// 创建真实系统提醒展示器，并启动周期刷新和首次用量加载。
    init() {
        let appState = AppState(usageAlertPresenter: SystemUsageAlertPresenter())
        self.appState = appState
        self.statusItemController = StatusItemController(appState: appState)
        appDelegate.appState = appState
        Task { @MainActor in
            appState.prepareUsageAlerts()
            appState.startPeriodicRefresh()
            await appState.refreshOnAppLaunch()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
                // 显式绑定菜单栏控制器的生命周期，避免无窗口 App 启动后被系统回收。
                .environmentObject(statusItemController)
        }
    }
}
