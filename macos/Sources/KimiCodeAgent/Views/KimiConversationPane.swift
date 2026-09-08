import SwiftUI
import AppKit
import KimiAgentCore

struct KimiWorkspacePane: View {
  @ObservedObject var model: KimiAppViewModel
  @AppStorage("kimi.layout.secondaryPaneWidth") private var secondaryPaneWidth: Double = 420
  @AppStorage("kimi.layout.secondaryPaneHeight") private var secondaryPaneHeight: Double = 320

  var body: some View {
    Group {
      if let secondary = model.secondarySession {
        splitWorkspace(secondary: secondary)
      } else {
        panelWorkspace
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 双会话分屏(⌘点击侧栏会话):左右两列各一条完整会话,时间线与
  /// composer 各自独立;固定等宽,焦点列顶部有高亮条。面板区(主区面板 +
  /// 次面板槽)在分屏下隐藏——面板属于单会话工作区,分屏中从菜单打开面板
  /// 会退出分屏(见 KimiAppViewModel.show)。
  private func splitWorkspace(secondary: KimiSessionSummary) -> some View {
    HStack(spacing: 0) {
      splitColumn(focus: .primary) { KimiConversationPane(model: model) }
      Divider()
      splitColumn(focus: .secondary) { KimiSplitSessionPane(model: model, session: secondary) }
    }
  }

  private func splitColumn<Content: View>(focus: KimiSplitFocus, @ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .top) {
        if model.splitFocus == focus {
          Rectangle().fill(KimiDesign.primary).frame(height: 3)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { model.splitFocus = focus }
  }

  /// 面板区:主槽(会话或 activePane 面板)+ 可选次面板槽;左右/上下方向
  /// 可选,槽位大小拖拽可调(@AppStorage 直接持久化)。次槽与主区同面板时
  /// 不渲染(ViewModel 已避免,这里兜底)。
  @ViewBuilder private var panelWorkspace: some View {
    let secondary = model.secondaryPane
      .flatMap { $0 == .conversation || $0 == model.state.activePane ? nil : $0 }
    if let secondary {
      if model.panelSplitHorizontal {
        HStack(spacing: 0) {
          primarySlot
          KimiResizeDivider(width: $secondaryPaneWidth, range: 280...720, inverted: true)
          KimiAuxPaneHost(model: model, pane: secondary, slot: .secondary)
            .frame(width: secondaryPaneWidth)
        }
      } else {
        VStack(spacing: 0) {
          primarySlot
          KimiHorizontalResizeDivider(height: $secondaryPaneHeight, range: 200...600, inverted: true)
          KimiAuxPaneHost(model: model, pane: secondary, slot: .secondary)
            .frame(height: secondaryPaneHeight)
        }
      }
    } else {
      primarySlot
    }
  }

  private var primarySlot: some View {
    Group {
      if model.state.activePane == .conversation {
        KimiConversationPane(model: model)
      } else {
        KimiAuxPaneHost(model: model, pane: model.state.activePane, slot: .primary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct KimiConversationPane: View {
  @ObservedObject var model: KimiAppViewModel

  private var activeSession: KimiSessionSummary? {
    model.state.sessions.first(where: { $0.id == model.state.activeSessionID })
  }

  /// Messages, tool activities and approval cards share one chronological
  /// timeline so tool cards sit between the bubbles that produced them,
  /// instead of all bubbles followed by all cards.
  private enum TimelineItem: Identifiable {
    case message(KimiMessage)
    case activity(KimiActivity)
    case permission(KimiPermissionRequest)
    case question(KimiQuestionRequest)

    var id: UUID {
      switch self {
      case let .message(message): message.id
      case let .activity(activity): activity.id
      case let .permission(permission): permission.id
      case let .question(request): request.id
      }
    }

    var createdAt: Date {
      switch self {
      case let .message(message): message.createdAt
      case let .activity(activity): activity.createdAt
      case let .permission(permission): permission.createdAt
      case let .question(request): request.createdAt
      }
    }
  }

  private var activeRuntimeID: String? {
    guard let session = activeSession else { return nil }
    return session.runtimeID ?? session.id.uuidString
  }

  /// 该条消息之前最近的一条用户消息文本，供「重新生成」判断可用性。
  private func messageBeforeUserText(_ messageID: UUID) -> String? {
    guard let index = model.state.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
    return model.state.messages[..<index].last(where: { $0.role == .user })?.text
  }

  private var timeline: [TimelineItem] {
    let questions = model.state.pendingQuestions.filter { $0.sessionID == activeRuntimeID }
    // 权限卡按会话过滤:侧聊线程的权限请求由侧聊面板展示,不能漏进主时间线
    // (sessionRuntimeID 为 nil 的旧事件保持原行为,始终展示)。
    let permissions = model.state.pendingPermissions.filter {
      $0.sessionRuntimeID == nil || $0.sessionRuntimeID == activeRuntimeID
    }
    let items: [TimelineItem] = model.state.messages.map(TimelineItem.message)
      + model.state.activities.map(TimelineItem.activity)
      + permissions.map(TimelineItem.permission)
      + questions.map(TimelineItem.question)
    let sorted = items.sorted {
      $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
    }
    // 精简模式只保留用户/助手消息；权限卡和问答卡始终显示，否则会出现
    // 「会话卡住但没有可操作卡片」的死锁观感。
    guard model.viewMode == .summary else { return sorted }
    return sorted.filter { item in
      switch item {
      case let .message(message): return message.role == .user || message.role == .assistant
      case .permission, .question: return true
      case .activity: return false
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(activeSession?.title ?? "会话")
            .font(.title3.weight(.semibold))
            .lineLimit(1)
          // Scratch sessions bind to the app's private sandbox directory,
          // not a project the user picked — showing that internal path here
          // would look like a real project binding (the exact "Playground"
          // confusion Codex Desktop's users reported). Say what it actually
          // is instead.
          if activeSession?.isScratch == true {
            Text("临时对话 · 不绑定项目文件夹")
              .font(.caption)
              .foregroundStyle(KimiDesign.muted)
              .lineLimit(1)
          } else {
            Text(activeSession?.projectPath ?? "把想法变成可验证的代码")
              .font(.caption)
              .foregroundStyle(KimiDesign.muted)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer()
        Picker("", selection: $model.viewMode) {
          ForEach(KimiTimelineViewMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .help("视图模式：标准 / 详细 / 精简（⌃O 循环切换）")
        if let usage = model.activeSessionUsage {
          Text(usage)
            .font(.caption)
            .foregroundStyle(KimiDesign.muted)
        }
        if model.isActiveSessionBusy {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Button("停止", action: model.abortActive)
              .buttonStyle(.bordered)
              .tint(.red)
          }
        }
        Menu {
          if let runtimeID = activeRuntimeID, model.state.revertedSessionIDs.contains(runtimeID) {
            Button("恢复撤销", action: model.unrevert)
          } else {
            Button("撤销上一轮", action: model.revertLastTurn)
              .disabled(!model.canRevertActive)
          }
          Button("压缩上下文", action: model.compact)
          Divider()
          Section("在主区显示") {
            ForEach(kimiAuxPaneMenu, id: \.pane) { entry in
              Button {
                model.show(entry.pane)
              } label: {
                Label(entry.title, systemImage: model.state.activePane == entry.pane ? "checkmark" : "rectangle.lefthalf.inset.filled")
              }
            }
          }
          Section("在次面板显示") {
            ForEach(kimiAuxPaneMenu, id: \.pane) { entry in
              Button {
                model.showInSecondary(entry.pane)
              } label: {
                Label(entry.title, systemImage: model.secondaryPane == entry.pane ? "checkmark" : "rectangle.righthalf.inset.filled")
              }
            }
            if model.secondaryPane != nil {
              Divider()
              Button(model.panelSplitHorizontal ? "次面板改为上下分屏" : "次面板改为左右分屏", action: model.togglePanelSplitOrientation)
              Button("关闭次面板", action: model.closeSecondaryPane)
            }
          }
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)

      if model.pullRequestMonitor.isBarVisible {
        KimiPullRequestBar(monitor: model.pullRequestMonitor)
          .padding(.horizontal, 24)
          .padding(.bottom, 10)
      }

      if !model.state.todos.isEmpty {
        KimiTodoListView(todos: model.state.todos)
          .padding(.horizontal, 24)
          .padding(.bottom, 10)
      }

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            if timeline.isEmpty {
              VStack(spacing: 10) {
                Text("你好，我是 Kimi Code Agent").font(.title2.weight(.semibold))
                Text("描述你的目标，我会分析、执行、验证并把结果交给你。").foregroundStyle(KimiDesign.muted)
              }
              .frame(maxWidth: .infinity)
              .padding(.top, 120)
            }
            ForEach(timeline) { item in
              switch item {
              case let .message(message):
                KimiMessageRow(
                  message: message,
                  model: model,
                  onFork: message.runtimeMessageID != nil ? {
                    if let activeID = model.state.activeSessionID {
                      model.forkSession(activeID, messageID: message.runtimeMessageID)
                    }
                  } : nil,
                  onRegenerate: message.role == .assistant && messageBeforeUserText(message.id) != nil ? {
                    model.regenerateResponse(to: message.id)
                  } : nil
                )
                  .id(message.id)
              case let .activity(activity):
                KimiActivityCard(activity: activity, forceExpanded: model.viewMode == .verbose)
                  .id(activity.id)
              case let .permission(permission):
                KimiPermissionCard(
                  permission: permission,
                  approve: { model.approve(permission.id) },
                  approveAlways: { model.approveAlways(permission.id) },
                  deny: { model.deny(permission.id) }
                )
                .id(permission.id)
              case let .question(request):
                KimiQuestionCard(
                  request: request,
                  answer: { answers in model.answerQuestion(request.id, answers) },
                  reject: { model.rejectQuestion(request.id) }
                )
                .id(request.id)
              }
            }
            if let error = model.state.lastError {
              HStack(spacing: 10) {
                Text(error)
                  .foregroundStyle(.red)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Button("重试", action: model.retryLastFailure)
                  .buttonStyle(.bordered)
              }
              .padding(12)
              .background(Color.red.opacity(0.08))
              .clipShape(RoundedRectangle(cornerRadius: 10))
            }
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 24)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
        }
        .onChange(of: timeline.count) { _, _ in
          if let id = timeline.last?.id {
            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
        .onChange(of: model.state.messages.last?.text) { _, _ in
          if let id = timeline.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
          }
        }
      }

      KimiComposerView(model: model)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
    .background(KimiDesign.surface)
  }
}

struct KimiMessageRow: View {
  let message: KimiMessage
  /// 助手消息传入以启用文件路径链接化与路径右键菜单；用户消息保持纯文本。
  var model: KimiAppViewModel? = nil
  /// Nil when this message hasn't been durably recorded by the engine yet
  /// (no runtimeMessageID to fork from) — the context menu item is omitted
  /// in that case rather than shown disabled, since a message that just
  /// streamed in usually gets one within moments of the turn finishing.
  var onFork: (() -> Void)? = nil
  /// Nil when no earlier user message exists to regenerate from.
  var onRegenerate: (() -> Void)? = nil
  @State private var isHovering = false

  private func copyText() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(message.text, forType: .string)
  }

  private var hoverButtons: some View {
    HStack(spacing: 2) {
      Button(action: copyText) {
        Image(systemName: "doc.on.doc")
      }
      .help("复制")
      if let onRegenerate {
        Button(action: onRegenerate) {
          Image(systemName: "arrow.clockwise")
        }
        .help("重新生成")
      }
    }
    .font(.caption)
    .buttonStyle(.plain)
    .foregroundStyle(KimiDesign.muted)
    .padding(5)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(KimiDesign.border, lineWidth: 1)
    )
    .shadow(radius: 2)
  }

  var body: some View {
    Group {
      if message.role == .user {
        // User message: gray rounded pill, right-aligned like Claude Code
        HStack {
          Spacer(minLength: 40)
          VStack(alignment: .trailing, spacing: 8) {
            if !message.attachments.isEmpty {
              HStack(spacing: 8) {
                ForEach(message.attachments) { attachment in
                  KimiMessageAttachmentView(attachment: attachment)
                }
              }
            }
            if !message.text.isEmpty {
              Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(KimiDesign.surfaceSecondary)
          .clipShape(RoundedRectangle(cornerRadius: 14))
        }
      } else {
        // Assistant message: no card background, icon + markdown blocks
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "sparkles")
            .font(.caption)
            .foregroundStyle(KimiDesign.primary)
            .frame(width: 16, height: 20)
            .padding(.top, 2)
          KimiMarkdownView(text: message.text, model: message.role == .assistant ? model : nil)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .overlay(alignment: .topTrailing) {
      if isHovering {
        hoverButtons
          .offset(y: -10)
      }
    }
    .onHover { isHovering = $0 }
    .contextMenu {
      Button("复制", action: copyText)
      if let onRegenerate {
        Button("重新生成", action: onRegenerate)
      }
      if let onFork {
        Button("从此消息分支会话", action: onFork)
      }
    }
  }
}

/// 用户消息气泡里的附件展示：图片缩略图（data URL 解码），文件引用文件名 chip。
struct KimiMessageAttachmentView: View {
  let attachment: KimiPromptAttachment

  var body: some View {
    if attachment.isImage, let data = attachment.imageData, let image = NSImage(data: data) {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: 240, maxHeight: 160)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(attachment.filename)
    } else {
      HStack(spacing: 5) {
        Image(systemName: attachment.isImage ? "photo" : "doc")
          .font(.caption2)
        Text(attachment.filename)
          .font(.caption.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle(KimiDesign.muted)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(KimiDesign.surface)
      .clipShape(Capsule())
    }
  }
}

struct KimiActivityCard: View {
  let activity: KimiActivity
  /// 「详细」视图模式：所有活动卡强制展开，展示全部工具细节。
  var forceExpanded: Bool = false
  @State private var isExpanded = false

  private var effectiveExpanded: Bool { forceExpanded || isExpanded }

  private var imageArtifacts: [URL] {
    guard let detail = activity.detail else { return [] }
    return KimiArtifactImages.extract(from: [detail])
  }

  private var dotColor: Color {
    switch activity.state {
    case .failed: return .red
    case .completed: return KimiDesign.primary
    default: return KimiDesign.muted
    }
  }

  private var hasDetail: Bool {
    (activity.detail?.isEmpty == false) || !imageArtifacts.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Compact header row: dot + tool name, like Claude Code's ⏺ tool()
      Button {
        if hasDetail, !forceExpanded { isExpanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
          Text(activity.title)
            .font(.callout.weight(.medium))
            .foregroundStyle(KimiDesign.text)
          if activity.state != .completed {
            Text(activity.state.rawValue)
              .font(.caption2)
              .foregroundStyle(KimiDesign.muted)
          }
          Spacer()
          if hasDetail {
            Image(systemName: effectiveExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2)
              .foregroundStyle(KimiDesign.muted)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Expandable detail, indented under the dot with a left rule
      if effectiveExpanded, hasDetail {
        VStack(alignment: .leading, spacing: 8) {
          if let detail = activity.detail, !detail.isEmpty {
            Text(detail)
              .font(.caption)
              .foregroundStyle(KimiDesign.muted)
              .textSelection(.enabled)
          }
          ForEach(imageArtifacts, id: \.self) { url in
            if let image = NSImage(contentsOf: url) {
              Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 480)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
          }
        }
        .padding(.leading, 15)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(KimiDesign.border)
            .frame(width: 1)
            .padding(.leading, 3)
        }
      }
    }
    .padding(.vertical, 2)
  }
}

struct KimiPermissionCard: View {
  let permission: KimiPermissionRequest
  let approve: () -> Void
  let approveAlways: () -> Void
  let deny: () -> Void

  /// 预览行数上限：超大写入（如新成长文件）只展示开头，避免审批卡撑爆时间线。
  private let previewRowLimit = 60

  /// edit/write 权限请求 metadata 携带待写入 unified diff 时解析为渲染模型，
  /// 让用户在批准前看清改动；无 diff 的权限类型返回 nil，不展示预览。
  private var previewDiff: FileDiff? {
    guard let diff = permission.metadataDiff, !diff.isEmpty else { return nil }
    return DiffEngine.parseUnifiedDiff(
      diff,
      fallbackPath: permission.metadataFilePath ?? permission.patterns.first ?? "file"
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("需要你的确认", systemImage: "hand.raised.fill")
        .font(.subheadline.weight(.semibold))
      Text(permission.reason).font(.subheadline)
      if permission.toolID != "unknown" {
        Text(permission.toolID)
          .font(.caption.monospaced())
          .foregroundStyle(KimiDesign.muted)
      }
      if !permission.patterns.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(permission.patterns, id: \.self) { pattern in
            Text(pattern)
              .font(.caption.monospaced())
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Color.orange.opacity(0.08))
              .clipShape(RoundedRectangle(cornerRadius: 6))
          }
        }
      }
      if let file = previewDiff {
        KimiPermissionDiffPreview(file: file, rowLimit: previewRowLimit)
      }
      HStack {
        Button("拒绝", action: deny).buttonStyle(.bordered)
        Spacer()
        Button("总是允许", action: approveAlways).buttonStyle(.bordered)
        Button("允许一次", action: approve)
          .buttonStyle(.borderedProminent)
          .tint(KimiDesign.primary)
      }
      Text("“总是允许”会对上面列出的同类操作永久放行，后续不再询问。")
        .font(.caption2)
        .foregroundStyle(KimiDesign.muted)
    }
    .padding(14)
    .background(Color.orange.opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }
}

/// 权限卡内嵌的紧凑 diff 预览：文件头（路径 + 增删统计）+ 带双态色的 +/- 行，
/// 渲染风格与 diff 面板一致，但只读、不可评论。
private struct KimiPermissionDiffPreview: View {
  let file: FileDiff
  let rowLimit: Int

  var body: some View {
    let rows = file.displayRows()
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "doc.text")
          .font(.caption2)
          .foregroundStyle(KimiDesign.muted)
        Text(file.path)
          .font(.caption.monospaced().weight(.medium))
          .lineLimit(1)
          .truncationMode(.middle)
        if file.status == .added {
          Text("新文件")
            .font(.caption2)
            .foregroundStyle(KimiDesign.diffAddedText)
        }
        Spacer(minLength: 4)
        Text("+\(file.additions)").font(.caption).foregroundStyle(.green)
        Text("−\(file.deletions)").font(.caption).foregroundStyle(.red)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(KimiDesign.surfaceSecondary.opacity(0.6))

      VStack(alignment: .leading, spacing: 0) {
        ForEach(rows.prefix(rowLimit)) { row in
          switch row.kind {
          case .hunkHeader(let title):
            Text(title)
              .font(.caption2.monospaced())
              .foregroundStyle(KimiDesign.accent)
              .padding(.horizontal, 10)
              .padding(.vertical, 3)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(KimiDesign.surfaceSecondary.opacity(0.4))
          case .line:
            Text(row.text.isEmpty ? " " : row.text)
              .font(.caption2.monospaced())
              .foregroundStyle(color(for: row.text))
              .lineLimit(1)
              .padding(.horizontal, 10)
              .padding(.vertical, 1)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(background(for: row.text))
          }
        }
        if rows.count > rowLimit {
          Text("… 仅预览前 \(rowLimit) 行，共 \(rows.count) 行")
            .font(.caption2)
            .foregroundStyle(KimiDesign.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
      }
    }
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(KimiDesign.border, lineWidth: 1))
  }

  private func color(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") { return KimiDesign.diffAddedText }
    if line.hasPrefix("-") && !line.hasPrefix("---") { return KimiDesign.diffRemovedText }
    return KimiDesign.text
  }

  private func background(for line: String) -> Color {
    if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.08) }
    if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.08) }
    return .clear
  }
}
