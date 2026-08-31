import SwiftUI
import KimiAgentCore

struct KimiSidebarView: View {
  @ObservedObject var model: KimiAppViewModel
  var onConfigureAPIKey: (() -> Void)? = nil
  var onConfigureProviders: (() -> Void)? = nil
  var onConfigureMCPServers: (() -> Void)? = nil

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
              Text("\(group.sessionCount)").font(.caption2)
            }
            .foregroundStyle(KimiDesign.muted)
            .padding(.horizontal, 4)
            // Root sessions render at top level; forked sessions nest under
            // their parent via OutlineGroup so the sidebar reads as a branch
            // tree instead of a flat, chronologically-sorted list.
            ForEach(group.roots) { node in
              OutlineGroup(node, children: \.children) { node in
                sessionRow(node.session)
              }
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
        if session.parentRuntimeID != nil {
          Image(systemName: "arrow.triangle.branch")
            .font(.caption2)
            .foregroundStyle(KimiDesign.muted)
        }
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
    .contextMenu {
      Button("从此会话分支") { model.forkSession(session.id, messageID: nil) }
    }
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
        Button("模型提供商") { onConfigureProviders?() }
        Button("MCP 服务器") { onConfigureMCPServers?() }
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

  /// A session and its forked children, for OutlineGroup's tree rendering.
  /// Reference type because OutlineGroup needs stable identity across a
  /// recursive `children` keypath; a value-type struct would need indirect
  /// enum boxing for the same recursive shape.
  private final class SessionNode: Identifiable {
    let session: KimiSessionSummary
    var children: [SessionNode]?

    init(session: KimiSessionSummary, children: [SessionNode]? = nil) {
      self.session = session
      self.children = children
    }

    var id: UUID { session.id }
  }

  private struct SessionGroup {
    let project: String
    let name: String
    let sessionCount: Int
    let roots: [SessionNode]
  }

  private var groupedSessions: [SessionGroup] {
    let grouped = Dictionary(grouping: model.state.sessions) { $0.projectPath ?? "" }
    return grouped.map { path, sessions in
      SessionGroup(
        project: path.isEmpty ? "ungrouped" : path,
        name: path.isEmpty ? "未分组" : URL(fileURLWithPath: path).lastPathComponent,
        sessionCount: sessions.count,
        roots: Self.buildTree(from: sessions)
      )
    }
    .sorted {
      (mostRecentUpdate(in: $0.roots) ?? .distantPast) > (mostRecentUpdate(in: $1.roots) ?? .distantPast)
    }
  }

  /// Builds a forest from a flat session list using parentRuntimeID. A
  /// session whose parent isn't present in this same list (parent lives in a
  /// different project group, or the parent was deleted) renders as its own
  /// root rather than being dropped — every session must stay reachable.
  private static func buildTree(from sessions: [KimiSessionSummary]) -> [SessionNode] {
    var nodesByRuntimeID: [String: SessionNode] = [:]
    for session in sessions {
      nodesByRuntimeID[session.runtimeID ?? session.id.uuidString] = SessionNode(session: session)
    }
    var roots: [SessionNode] = []
    for session in sessions {
      let node = nodesByRuntimeID[session.runtimeID ?? session.id.uuidString]!
      if let parentRuntimeID = session.parentRuntimeID, let parent = nodesByRuntimeID[parentRuntimeID] {
        parent.children = (parent.children ?? []) + [node]
      } else {
        roots.append(node)
      }
    }
    // Sort every level (roots and each parent's children) newest first, so
    // branch trees read the same top-to-bottom order as the old flat list.
    func sortRecursively(_ nodes: [SessionNode]) -> [SessionNode] {
      let sorted = nodes.sorted { $0.session.updatedAt > $1.session.updatedAt }
      for node in sorted {
        if let children = node.children {
          node.children = sortRecursively(children)
        }
      }
      return sorted
    }
    return sortRecursively(roots)
  }

  private func mostRecentUpdate(in nodes: [SessionNode]) -> Date? {
    nodes.map { node -> Date in
      let childMax = node.children.flatMap(mostRecentUpdate) ?? .distantPast
      return max(node.session.updatedAt, childMax)
    }.max()
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
