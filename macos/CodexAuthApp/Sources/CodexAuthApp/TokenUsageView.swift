import SwiftUI

private struct TokenUsageMetric: Identifiable {
    let value: String
    let detail: String
    let icon: String
    let color: Color

    var id: String { detail }
}

private enum TokenUsagePeriod {
    case day
    case week
    case month
}

/// 展示今日、本周和本月的 Token 消耗摘要。
struct TokenUsageView: View {
    let info: TokenUsageInfo?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Token 消耗")
                .font(.title3.weight(.semibold))

            if let info {
                summaryCards(info)
            } else {
                emptyState
            }
        }
        .padding(14)
        .frame(width: compact ? 400 : 560)
        .background(Color(red: 0.93, green: 0.96, blue: 1.0))
    }

    /// 无统计数据时保持页面结构完整，避免弹窗高度跳变。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("暂无 Token 数据")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    /// 使用三张卡片展示三个自然时间范围的真实 Token 汇总。
    private func summaryCards(_ info: TokenUsageInfo) -> some View {
        let metrics = [
            TokenUsageMetric(value: compact(periodTotal(info, period: .day)), detail: "今日消耗", icon: "sun.max", color: .teal),
            TokenUsageMetric(value: compact(periodTotal(info, period: .week)), detail: "近 7 天消耗", icon: "calendar", color: .blue),
            TokenUsageMetric(value: compact(periodTotal(info, period: .month)), detail: "本月消耗", icon: "calendar.badge.clock", color: .indigo)
        ]

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(metrics) { metric in
                metricCard(metric)
            }
        }
    }

    /// 按本地统计日明细聚合今日、本周、本月和本年总 Token。
    private func periodTotal(_ info: TokenUsageInfo, period: TokenUsagePeriod) -> Int64 {
        guard let latestDate = info.days.compactMap({ parseDate($0.date) }).max() else {
            return 0
        }

        if period == .day, let today = info.today {
            return today.totals.totalTokens
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return info.days.reduce(0) { total, day in
            guard let date = parseDate(day.date) else { return total }
            let matches: Bool
            switch period {
            case .day:
                matches = false
            case .week:
                matches = date >= (calendar.date(byAdding: .day, value: -6, to: latestDate) ?? latestDate)
            case .month:
                matches = calendar.component(.year, from: date) == calendar.component(.year, from: latestDate)
                    && calendar.component(.month, from: date) == calendar.component(.month, from: latestDate)
            }
            return matches ? total + day.totals.totalTokens : total
        }
    }

    /// 统一三张 Token 摘要卡片的图标、周期说明和主数值样式。
    private func metricCard(_ metric: TokenUsageMetric) -> some View {
        HStack(spacing: 8) {
            Image(systemName: metric.icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(metric.color)
                .frame(width: 24, height: 24)
                .background(metric.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(metric.value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 解析本地统计接口使用的 ISO 日期。
    private func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }

    private func compact(_ value: Int64) -> String {
        TokenUsageFormatter.compact(value)
    }
}
