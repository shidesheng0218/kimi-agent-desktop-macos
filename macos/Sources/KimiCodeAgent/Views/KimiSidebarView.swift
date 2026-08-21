import SwiftUI
import KimiAgentCore

struct KimiSidebarView: View {
  @ObservedObject var model: KimiAppViewModel
  var onConfigureAPIKey: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      newSessionButton
      homeButton
      Text("项目")
        .font(.caption.weight(.semibold))
        .foregroundStyle(KimiDesign.muted)
        .padding(.top, 4)
      sessionGroups
      Divider()
      footer
    }
    .padding(16)
    .background(KimiDesign.surface)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Circle().fill(KimiDesign.primary.gradient).frame(width: 30, height: 30)
        .overlay(Text("K").font(.headline.weight(.bold)).foregroundStyle(.white))
      VStack(alignment: .leading, spacing: 1) {
        Text("Kimi Code Agent").font(.headline)
        Text("原生智能工作台").font(.caption).foregroundStyle(KimiDesign.muted)
      }
    }
  }

  private var newSessionButton: some View {
    Button(action: model.createSession) {
      Label("新建会话", systemImage: "plus")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.borderedProminent)
    .tint(KimiDesign.primary)
  }

  private var homeButton: some View {
    Button(action: model.goHome) {
      Label("首页", systemImage: "house")
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.state.activeSessionID == nil ? KimiDesign.surfaceSecondary : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var sessionGroups: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        ForEach(groupedSessions, id: \.project) { group in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Image(systemName: "folder").font(.caption2)
              Text(group.name).font(.caption.weight(.semibold)).lineLimit(1)
              Spacer()
              Text("\(group.sessions.count)").font(.caption2)
            }
            .foregroundStyle(KimiDesign.muted)
            .padding(.horizontal, 4)
            ForEach(group.sessions) { session in
              sessionRow(session)
            }
          }
        }
        if model.state.sessions.isEmpty {
          Text("还没有会话")
            .font(.caption)
            .foregroundStyle(KimiDesign.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
        }
      }
    }
  }

  private func sessionRow(_ session: KimiSessionSummary) -> some View {
    Button { model.select(session.id) } label: {
      HStack(spacing: 8) {
        Circle()
          .fill(KimiDesign.statusColor(session.status))
          .frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 2) {
          Text(session.title)
            .font(.subheadline)
            .foregroundStyle(KimiDesign.text)
            .lineLimit(1)
          Text(relativeTime(from: session.updatedAt))
            .font(.caption2)
            .foregroundStyle(KimiDesign.muted)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(model.state.activeSessionID == session.id ? KimiDesign.surfaceSecondary : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Circle().fill(KimiDesign.accent.gradient).frame(width: 28, height: 28)
        .overlay(Text(userInitial).font(.caption.weight(.bold)).foregroundStyle(.white))
      VStack(alignment: .leading, spacing: 1) {
        Text(userName).font(.caption.weight(.medium)).lineLimit(1)
        HStack(spacing: 4) {
          Circle()
            .fill(model.state.runtimeState == .ready ? .green : .orange)
            .frame(width: 6, height: 6)
          Text(model.state.runtimeState == .ready ? "运行时已连接" : "正在连接")
            .font(.caption2)
            .foregroundStyle(KimiDesign.muted)
        }
      }
      Spacer()
      Menu {
        Button("配置 API 密钥") { onConfigureAPIKey?() }
        Divider()
        Button("重启运行时", action: model.restartRuntime)
      } label: {
        Image(systemName: "gearshape")
          .foregroundStyle(KimiDesign.muted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
    }
  }

  private struct SessionGroup {
    let project: String
    let name: String
    let sessions: [KimiSessionSummary]
  }

  private var groupedSessions: [SessionGroup] {
    let grouped = Dictionary(grouping: model.state.sessions) { $0.projectPath ?? "" }
    return grouped.map { path, sessions in
      SessionGroup(
        project: path.isEmpty ? "ungrouped" : path,
        name: path.isEmpty ? "未分组" : URL(fileURLWithPath: path).lastPathComponent,
        sessions: sessions.sorted { $0.updatedAt > $1.updatedAt }
      )
    }
    .sorted {
      ($0.sessions.first?.updatedAt ?? .distantPast) > ($1.sessions.first?.updatedAt ?? .distantPast)
    }
  }

  private var userName: String {
    let name = NSFullUserName()
    return name.isEmpty ? "Kimi 用户" : name
  }

  private var userInitial: String {
    String(userName.prefix(1)).uppercased()
  }

  /// 计算静态的相对时间字符串，不会持续更新
  private func relativeTime(from date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "\(seconds)秒" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)分钟" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)小时" }
    let days = hours / 24
    if days < 30 { return "\(days)天" }
    let months = days / 30
    if months < 12 { return "\(months)个月" }
    return "\(months / 12)年"
  }
}
