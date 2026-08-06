import SwiftUI

@main
struct CodexAuthMenuApp: App {
    private let appState: AppState
    private let statusItemController: StatusItemController

    /// 创建真实系统提醒展示器，并启动周期刷新和首次用量加载。
    init() {
        let appState = AppState(usageAlertPresenter: SystemUsageAlertPresenter())
        self.appState = appState
        self.statusItemController = StatusItemController(appState: appState)
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
