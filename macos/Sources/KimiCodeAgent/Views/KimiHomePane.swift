import SwiftUI
import KimiAgentCore

private enum KimiHomeTab: String, CaseIterable {
  case overview = "概览"
  case models = "模型"
}

/// Claude Code 风格的首页：问候、快捷任务入口、统计卡片、活动热力图、
/// 模型使用分布和最近会话。所有数字来自 activity.jsonl、Harness 事件日志
/// 与真实会话列表，不做任何虚构。
struct KimiHomePane: View {
  @ObservedObject var model: KimiAppViewModel
  @State private var range: KimiUsageStatsRange = .all
  @State private var tab: KimiHomeTab = .overview

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        header
        if let error = model.state.lastError {
          errorBanner(error)
        }
        recentSessions
        controls
        if tab == .overview {
          statsGrid
          heatmapCard
        } else {
          modelsCard
        }
        quickComposer
      }
      .padding(32)
      .frame(maxWidth: 960)
      .frame(maxWidth: .infinity)
    }
    .background(KimiDesign.background)
    .task(id: range) {
      await model.loadHomeStats(range: range)
    }
    .task(id: model.state.sessions.count) {
      await model.loadHomeStats(range: range)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 6) {
        Text(greeting)
          .font(.system(size: 30, weight: .bold))
          .foregroundStyle(KimiDesign.text)
        Text("已累计处理 \(model.homeStats.messageCount) 条消息 · \(model.homeStats.toolCallCount) 次工具调用")
          .font(.subheadline)
          .foregroundStyle(KimiDesign.muted)
      }
      Spacer()
      Button(action: model.createSession) {
        Label("开始新任务", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
      .tint(KimiDesign.primary)
      .controlSize(.large)
    }
  }

  private var greeting: String {
    let hour = Calendar.current.component(.hour, from: .now)
    let phase: String
    switch hour {
    case 5..<12: phase = "早上好"
    case 12..<14: phase = "中午好"
    case 14..<18: phase = "下午好"
    default: phase = "晚上好"
    }
    let name = NSFullUserName()
    return name.isEmpty ? "\(phase)，接下来做点什么？" : "\(phase)，\(name)"
  }

  // MARK: - Error banner

  /// Engine/runtime failures must be visible on the home pane too — this is
  /// where "开始新任务" lives, and a silent failure here previously read as
  /// a dead button.
  private func errorBanner(_ error: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      Text(error)
        .font(.subheadline)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("重试", action: model.retryLastFailure)
        .buttonStyle(.bordered)
    }
    .padding(12)
    .background(Color.red.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Quick composer

  private var quickComposer: some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .foregroundStyle(KimiDesign.primary)
      TextField("描述一个任务，Kimi 立即开始…", text: $model.composerText)
        .textFieldStyle(.plain)
        .font(.body)
        .onSubmit { model.sendPrompt() }
      Button(action: model.sendPrompt) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
      }
      .buttonStyle(.plain)
      .foregroundStyle(KimiDesign.primary)
      .disabled(model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
    .overlay(
      RoundedRectangle(cornerRadius: KimiDesign.radius)
        .stroke(KimiDesign.border, lineWidth: 1)
    )
  }

  // MARK: - Tabs & range

  private var controls: some View {
    HStack {
      Picker("", selection: $tab) {
        ForEach(KimiHomeTab.allCases, id: \.self) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 170)
      Spacer()
      Picker("", selection: $range) {
        Text("全部").tag(KimiUsageStatsRange.all)
        Text("30 天").tag(KimiUsageStatsRange.thirtyDays)
        Text("7 天").tag(KimiUsageStatsRange.sevenDays)
      }
      .pickerStyle(.segmented)
      .frame(width: 210)
    }
  }

  // MARK: - Stat cards

  private struct StatCardData: Identifiable {
    let id: String
    let title: String
    let value: String
    let icon: String
    let tint: Color
  }

  private var statsGrid: some View {
    let stats = model.homeStats
    let cards: [StatCardData] = [
      StatCardData(id: "sessions", title: "会话", value: "\(stats.sessionCount)",
                   icon: "bubble.left.and.bubble.right.fill", tint: KimiDesign.primary),
      StatCardData(id: "messages", title: "消息", value: "\(stats.messageCount)",
                   icon: "text.bubble.fill", tint: KimiDesign.accent),
      StatCardData(id: "tools", title: "工具调用", value: "\(stats.toolCallCount)",
                   icon: "wrench.and.screwdriver.fill", tint: .orange),
      StatCardData(id: "days", title: "活跃天数", value: "\(stats.activeDays)",
                   icon: "calendar", tint: .green),
      StatCardData(id: "streak", title: "当前连续", value: "\(stats.currentStreak) 天",
                   icon: "flame.fill", tint: .red),
      StatCardData(id: "best", title: "最长连续", value: "\(stats.longestStreak) 天",
                   icon: "trophy.fill", tint: .yellow),
      StatCardData(id: "peak", title: "高峰时段", value: stats.peakHour.map { "\($0):00" } ?? "—",
                   icon: "clock.fill", tint: KimiDesign.primary),
      StatCardData(id: "model", title: "常用模型", value: stats.favoriteModel ?? "—",
                   icon: "cpu", tint: KimiDesign.accent),
    ]
    return LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
      spacing: 8
    ) {
      ForEach(cards) { card in
        VStack(alignment: .leading, spacing: 6) {
          Image(systemName: card.icon)
            .font(.caption)
            .foregroundStyle(card.tint)
            .frame(width: 24, height: 24)
            .background(card.tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
          Text(card.value)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(KimiDesign.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
          Text(card.title)
            .font(.caption2)
            .foregroundStyle(KimiDesign.muted)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KimiDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .stroke(KimiDesign.border, lineWidth: 1)
        )
      }
    }
  }

  // MARK: - Heatmap

  private var heatmapWeeks: Int {
    switch range {
    case .all: return 20
    case .thirtyDays: return 6
    case .sevenDays: return 2
    }
  }

  private var heatmapCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("活动热力", systemImage: "square.grid.3x3.fill")
          .font(.headline)
          .foregroundStyle(KimiDesign.text)
        Spacer()
        if let busiest = model.homeStats.busiestDayCount, busiest > 0 {
          Text("最忙的一天完成了 \(busiest) 次活动")
            .font(.caption)
            .foregroundStyle(KimiDesign.muted)
        }
      }
      KimiHeatmapView(dailyCounts: model.homeStats.dailyCounts, weeks: heatmapWeeks)
      HStack(spacing: 5) {
        Spacer()
        Text("少").font(.caption2).foregroundStyle(KimiDesign.muted)
        ForEach([0, 2, 4, 7, 12], id: \.self) { level in
          RoundedRectangle(cornerRadius: 2.5)
            .fill(KimiHeatmapView.color(for: level))
            .frame(width: 11, height: 11)
        }
        Text("多").font(.caption2).foregroundStyle(KimiDesign.muted)
      }
    }
    .padding(20)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
    .overlay(
      RoundedRectangle(cornerRadius: KimiDesign.radius)
        .stroke(KimiDesign.border, lineWidth: 1)
    )
  }

  // MARK: - Models tab

  private var modelsCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("模型使用", systemImage: "cpu")
        .font(.headline)
        .foregroundStyle(KimiDesign.text)
      if model.homeStats.modelUsage.isEmpty {
        VStack(spacing: 8) {
          Text("模型调用数据会随真实任务累积")
            .font(.subheadline)
            .foregroundStyle(KimiDesign.muted)
          Text("当前模型：\(model.state.selectedModel)")
            .font(.caption)
            .foregroundStyle(KimiDesign.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
      } else {
        let entries = model.homeStats.modelUsage.sorted { $0.value > $1.value }
        let maxCount = max(entries.map(\.value).max() ?? 1, 1)
        ForEach(entries, id: \.key) { name, count in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(name).font(.subheadline.weight(.medium)).foregroundStyle(KimiDesign.text)
              if name == model.state.selectedModel {
                Text("当前")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(KimiDesign.primary)
                  .padding(.horizontal, 7)
                  .padding(.vertical, 2)
                  .background(KimiDesign.primary.opacity(0.10))
                  .clipShape(Capsule())
              }
              Spacer()
              Text("\(count) 次")
                .font(.caption)
                .foregroundStyle(KimiDesign.muted)
            }
            GeometryReader { geometry in
              ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(KimiDesign.surfaceSecondary)
                RoundedRectangle(cornerRadius: 4)
                  .fill(name == model.state.selectedModel ? KimiDesign.primary : KimiDesign.accent.opacity(0.7))
                  .frame(width: geometry.size.width * CGFloat(count) / CGFloat(maxCount))
              }
            }
            .frame(height: 8)
          }
        }
      }
    }
    .padding(20)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
    .overlay(
      RoundedRectangle(cornerRadius: KimiDesign.radius)
        .stroke(KimiDesign.border, lineWidth: 1)
    )
  }

  // MARK: - Recent sessions

  private var recentSessions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("最近会话", systemImage: "clock.arrow.circlepath")
        .font(.headline)
        .foregroundStyle(KimiDesign.text)
      if model.state.sessions.isEmpty {
        Text("还没有会话。在上方输入第一个任务即可开始。")
          .font(.subheadline)
          .foregroundStyle(KimiDesign.muted)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 24)
      } else {
        ForEach(model.state.sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(5)) { session in
          Button { model.select(session.id) } label: {
            HStack(spacing: 12) {
              Circle()
                .fill(KimiDesign.statusColor(session.status))
                .frame(width: 8, height: 8)
              VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                  .font(.subheadline.weight(.medium))
                  .foregroundStyle(KimiDesign.text)
                  .lineLimit(1)
                Text(session.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未分组")
                  .font(.caption)
                  .foregroundStyle(KimiDesign.muted)
              }
              Spacer()
              Text(session.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(KimiDesign.muted)
              Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(KimiDesign.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(KimiDesign.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .stroke(KimiDesign.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}

/// GitHub 风格的周 × 星期热力图，颜色使用 Kimi 主色的不同不透明度。
struct KimiHeatmapView: View {
  let dailyCounts: [Date: Int]
  let weeks: Int
  private let calendar = Calendar.current

  var body: some View {
    HStack(alignment: .top, spacing: 3) {
      VStack(spacing: 3) {
        ForEach(0..<7, id: \.self) { row in
          Text(rowLabel(row))
            .font(.system(size: 8))
            .foregroundStyle(KimiDesign.muted)
            .frame(width: 12, height: 12)
        }
      }
      ForEach(columns.indices, id: \.self) { columnIndex in
        VStack(spacing: 3) {
          ForEach(0..<7, id: \.self) { row in
            cell(for: columns[columnIndex][row])
          }
        }
      }
    }
  }

  private func rowLabel(_ row: Int) -> String {
    ["一", "", "三", "", "五", "", "日"][row]
  }

  @ViewBuilder
  private func cell(for date: Date?) -> some View {
    if let date {
      let count = dailyCounts[calendar.startOfDay(for: date)] ?? 0
      RoundedRectangle(cornerRadius: 2.5)
        .fill(Self.color(for: count))
        .frame(width: 12, height: 12)
        .help("\(date.formatted(date: .abbreviated, time: .omitted)) · \(count) 次活动")
    } else {
      RoundedRectangle(cornerRadius: 2.5)
        .fill(.clear)
        .frame(width: 12, height: 12)
    }
  }

  static func color(for count: Int) -> Color {
    switch count {
    case 0: return KimiDesign.surfaceSecondary
    case 1...2: return KimiDesign.primary.opacity(0.25)
    case 3...5: return KimiDesign.primary.opacity(0.5)
    case 6...9: return KimiDesign.primary.opacity(0.75)
    default: return KimiDesign.primary
    }
  }

  /// Columns are weeks (Mon...Sun), oldest first, ending at the current
  /// week. Future days render as empty placeholders to keep the grid aligned.
  private var columns: [[Date?]] {
    let today = calendar.startOfDay(for: .now)
    let weekday = calendar.component(.weekday, from: today) // 1 = Sunday
    let daysSinceMonday = (weekday + 5) % 7
    guard let thisMonday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) else {
      return []
    }
    return (0..<weeks).map { weekIndex in
      (0..<7).map { dayIndex in
        guard let date = calendar.date(
          byAdding: .day,
          value: dayIndex - (weeks - 1 - weekIndex) * 7,
          to: thisMonday
        ) else { return nil }
        return date <= today ? date : nil
      }
    }
  }
}
