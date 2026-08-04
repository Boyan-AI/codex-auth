import SwiftUI

/// 展示统一连接摘要；整行点击只修改下一次官方直连会话使用的连接。
struct AccountRow: View {
    @EnvironmentObject private var appState: AppState
    let account: CodexAccount

    var body: some View {
        Button {
            guard !account.isActive else { return }
            Task { await appState.switchAccount(accountKey: account.accountKey) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                connectionIcon
                    .frame(width: 28, height: 28)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(account.primaryLabel)
                            .font(.system(size: 15, weight: account.isActive ? .semibold : .medium))
                            .foregroundStyle(.primary)
                        Text(account.isAPIKey ? "Key" : account.planLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Text(account.secondaryLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if account.isAPIKey {
                        if let balance = account.balanceText {
                            Text("余额 \(balance)")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    } else {
                        usageLines
                        resetCreditsLine
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 后台额度刷新不应锁住直连账号选择，只阻止重复账号切换。
        .disabled(appState.isAccountSwitchInProgress)
        .background(selectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 账号与 Key 都使用系统图标；选择状态只由背景表达。
    @ViewBuilder
    private var connectionIcon: some View {
        if account.isAPIKey {
            Image(systemName: "key.fill")
                .font(.title3)
                .foregroundStyle(Color.orange)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    /// 只有当前选中行显示状态底色，避免额外的“直连”或“不可用”标签。
    private var selectionBackground: Color {
        guard account.isActive else { return .clear }
        return account.isAvailable ? Color.accentColor.opacity(0.16) : Color.red.opacity(0.15)
    }

    /// 分别展示实际存在的 5 小时窗口和始终存在的 7 天窗口。
    private var usageLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fiveHour = account.usage.fiveHour {
                usageText(prefix: "5小时", window: fiveHour)
            }
            usageText(prefix: "7天", window: account.usage.sevenDay)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 重置机会始终显示次数；查询未完成或失败时保留明确状态。
    private var resetCreditsLine: some View {
        let text: String
        if let resetCredits = account.resetCredits {
            text = resetCredits.accountDetailText
        } else if appState.isLoading || appState.state?.refresh.attempted != true {
            text = "重置 查询中"
        } else {
            text = "重置 查询失败"
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 将剩余额度、错误状态和独立刷新时间组合为一行。
    private func usageText(prefix: String, window: UsageWindow) -> Text {
        Text("\(prefix) ")
            .foregroundColor(.secondary)
            + Text(window.displayText)
            .foregroundColor(window.menuBarUsageTone.usageColor)
            + Text(window.resetLabel.map { " \($0)" } ?? "")
            .foregroundColor(.secondary)
    }
}
