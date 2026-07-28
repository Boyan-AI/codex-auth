import SwiftUI

struct AccountRow: View {
    @EnvironmentObject private var appState: AppState
    let account: CodexAccount
    let isManaging: Bool
    @State private var isEditingAlias = false
    @State private var aliasText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: account.isActive ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(account.isActive ? .blue : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(account.primaryLabel)
                            .fontWeight(account.isActive ? .semibold : .regular)
                        Text(account.planLabel)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if !account.secondaryLabel.isEmpty {
                        Text(account.secondaryLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    usageLine
                    resetCreditsLine
                }

                Spacer()

                rowActions
            }

            if isManaging && isEditingAlias {
                aliasEditor
            }
        }
        .padding(8)
        .background(account.isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            aliasText = account.alias ?? ""
        }
        .onChange(of: account.accountKey) { _ in
            aliasText = account.alias ?? ""
            isEditingAlias = false
        }
        .onChange(of: account.alias ?? "") { newValue in
            aliasText = newValue
        }
    }

    private var usageLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let fiveHour = account.usage.fiveHour {
                usageText(prefix: "5小时", window: fiveHour)
            }
            usageText(prefix: "7天", window: account.usage.sevenDay)
        }
        .font(.caption)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 展示 reset 查询状态，避免空白让用户误以为功能未生效。
    private var resetCreditsLine: some View {
        let text: String
        if let resetCredits = account.resetCredits {
            text = resetCredits.accountDetailText
        } else if appState.isLoading || appState.state?.refresh.attempted != true {
            text = "重置: 查询中"
        } else {
            text = "重置: 查询失败"
        }
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func usageText(prefix: String, window: UsageWindow) -> Text {
        Text("\(prefix) ")
            .foregroundColor(.secondary)
            + Text(window.displayText)
            .foregroundColor(usageColor(for: window))
            + Text(window.resetLabel.map { " \($0)" } ?? "")
            .foregroundColor(.secondary)
    }

    private func usageColor(for window: UsageWindow) -> Color {
        window.menuBarUsageTone.usageColor
    }

    /// 非管理态统一占用固定宽度，确保“使用中”与“切换”的字号和中心线一致。
    @ViewBuilder
    private var rowActions: some View {
        if isManaging {
            HStack(spacing: 8) {
                Button("设置别名") {
                    aliasText = account.alias ?? ""
                    withAnimation(.snappy) {
                        isEditingAlias.toggle()
                    }
                }
                Button("删除", role: .destructive) {
                    appState.requestDelete(account)
                }
            }
        } else {
            Group {
                if account.isActive {
                    Text("使用中")
                        .foregroundStyle(.secondary)
                } else {
                    Button("切换") {
                        Task { await appState.switchAccount(accountKey: account.accountKey) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .font(.body)
            .frame(width: 76, alignment: .center)
        }
    }

    private var aliasEditor: some View {
        HStack(spacing: 8) {
            TextField("输入别名", text: $aliasText)
                .textFieldStyle(.roundedBorder)

            Button("保存") {
                let alias = aliasText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await appState.setAlias(accountKey: account.accountKey, alias: alias)
                    isEditingAlias = false
                }
            }
            .disabled(aliasText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("清除") {
                Task {
                    await appState.clearAlias(accountKey: account.accountKey)
                    isEditingAlias = false
                }
            }

            Button("取消") {
                aliasText = account.alias ?? ""
                isEditingAlias = false
            }
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 34)
    }
}
