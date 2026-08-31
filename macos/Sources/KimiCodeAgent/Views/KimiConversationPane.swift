import SwiftUI
import AppKit
import KimiAgentCore

struct KimiWorkspacePane: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    switch model.state.activePane {
    case .conversation:
      KimiConversationPane(model: model)
    case .diff:
      KimiDiffPane(model: model)
    case .browser:
      KimiBrowserPane(model: model)
    case .files:
      KimiFilesPane(model: model)
    case .verification:
      KimiVerificationPane(model: model)
    case .integrations:
      KimiIntegrationsPane(model: model)
    }
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

  private var timeline: [TimelineItem] {
    let questions = model.state.pendingQuestions.filter { $0.sessionID == activeRuntimeID }
    let items: [TimelineItem] = model.state.messages.map(TimelineItem.message)
      + model.state.activities.map(TimelineItem.activity)
      + model.state.pendingPermissions.map(TimelineItem.permission)
      + questions.map(TimelineItem.question)
    return items.sorted {
      $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
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
          Button("Diff") { model.show(.diff) }
          Button("Browser") { model.show(.browser) }
          Button("Files") { model.show(.files) }
          Button("验证") { model.show(.verification) }
          Button("集成") { model.show(.integrations) }
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 18)

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
                  onFork: message.runtimeMessageID != nil ? {
                    if let activeID = model.state.activeSessionID {
                      model.forkSession(activeID, messageID: message.runtimeMessageID)
                    }
                  } : nil
                )
                  .id(message.id)
              case let .activity(activity):
                KimiActivityCard(activity: activity)
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
              Text(error)
                .foregroundStyle(.red)
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
  /// Nil when this message hasn't been durably recorded by the engine yet
  /// (no runtimeMessageID to fork from) — the context menu item is omitted
  /// in that case rather than shown disabled, since a message that just
  /// streamed in usually gets one within moments of the turn finishing.
  var onFork: (() -> Void)? = nil

  var body: some View {
    Group {
      if message.role == .user {
        // User message: gray rounded pill, right-aligned like Claude Code
        HStack {
          Spacer(minLength: 40)
          Text(message.text)
            .font(.body)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(KimiDesign.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
      } else {
        // Assistant message: no card background, icon + text
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "sparkles")
            .font(.caption)
            .foregroundStyle(KimiDesign.primary)
            .frame(width: 16, height: 20)
            .padding(.top, 2)
          Group {
            if let attributed = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
              Text(attributed)
            } else {
              Text(message.text)
            }
          }
          .font(.body)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .contextMenu {
      if let onFork {
        Button("从此消息分支会话", action: onFork)
      }
    }
  }
}

struct KimiActivityCard: View {
  let activity: KimiActivity
  @State private var isExpanded = false

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
        if hasDetail { isExpanded.toggle() }
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
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2)
              .foregroundStyle(KimiDesign.muted)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Expandable detail, indented under the dot with a left rule
      if isExpanded, hasDetail {
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
      HStack {
        Button("拒绝", action: deny).buttonStyle(.bordered)
        Spacer()
        Button("总是允许", action: approveAlways).buttonStyle(.bordered)
        Button("允许一次", action: approve)
          .buttonStyle(.borderedProminent)
          .tint(KimiDesign.primary)
      }
    }
    .padding(14)
    .background(Color.orange.opacity(0.10))
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }
}
