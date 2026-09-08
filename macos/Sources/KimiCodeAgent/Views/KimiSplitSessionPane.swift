import SwiftUI
import KimiAgentCore

/// 双会话分屏的次列(⌘点击侧栏会话打开):一条完整但精简的会话面板——
/// 时间线(消息+活动+权限/问答卡)+ 与主列同款的完整 composer,按本列会话 ID 路由。
///
/// 数据源与主列不同:state.messages/activities 只承载活跃会话,本列的消息
/// 与活动来自 KimiAppViewModel 的 secondaryMessages/secondaryActivities
/// (kernel.sessionHistory 拉持久历史 + .sessionEvent 直通事件实时追加);
/// 权限/问答卡仍从全局 state 按会话 runtimeID 过滤(与侧聊面板同款)。
struct KimiSplitSessionPane: View {
  @ObservedObject var model: KimiAppViewModel
  let session: KimiSessionSummary

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

  private var runtimeID: String { session.runtimeID ?? session.id.uuidString }
  private var isBusy: Bool { model.state.busySessionIDs.contains(runtimeID) }

  private var timeline: [TimelineItem] {
    // 权限/问答是全局列表:本列只取属于本会话的;sessionRuntimeID 为 nil 的
    // 旧事件归主列展示,避免一张卡两列都出现。
    let permissions = model.state.pendingPermissions.filter { $0.sessionRuntimeID == runtimeID }
    let questions = model.state.pendingQuestions.filter { $0.sessionID == runtimeID }
    let items: [TimelineItem] = model.secondaryMessages.map(TimelineItem.message)
      + model.secondaryActivities.map(TimelineItem.activity)
      + permissions.map(TimelineItem.permission)
      + questions.map(TimelineItem.question)
    let sorted = items.sorted {
      $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
    }
    // 与主列一致的精简模式:只留用户/助手消息,权限卡与问答卡始终显示。
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
      HStack(spacing: 8) {
        Image(systemName: "rectangle.split.2x1")
          .font(.caption)
          .foregroundStyle(KimiDesign.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text(session.title)
            .font(.headline)
            .lineLimit(1)
          Text(session.isScratch ? "临时对话 · 不绑定项目文件夹" : (session.workingPath ?? ""))
            .font(.caption2)
            .foregroundStyle(KimiDesign.muted)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        if isBusy {
          ProgressView().controlSize(.small)
          Button("停止", action: model.abortSecondary)
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
        Button(action: model.closeSplit) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(KimiDesign.muted)
        .help("关闭分屏 (⌘\\)")
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if timeline.isEmpty {
              VStack(spacing: 8) {
                Text("分屏会话").font(.title3.weight(.semibold))
                Text("这是「\(session.title)」的独立列,发送的消息只进入该会话。")
                  .font(.caption)
                  .foregroundStyle(KimiDesign.muted)
              }
              .frame(maxWidth: .infinity)
              .padding(.top, 80)
            }
            ForEach(timeline) { item in
              switch item {
              case let .message(message):
                KimiMessageRow(message: message, model: model)
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
            if let error = model.secondaryError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(16)
        }
        .onChange(of: timeline.count) { _, _ in
          if let id = timeline.last?.id {
            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
        .onChange(of: model.secondaryMessages.last?.text) { _, _ in
          if let id = timeline.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
          }
        }
      }

      Divider()
      // 次列 composer 与主列同款(附件/粘贴/拖拽/@提及/斜杠补全),发送按本列
      // 会话 ID 路由;草稿按会话键控,与主列互不串稿。
      KimiComposerView(model: model, scope: .secondary(session.id))
        .padding(12)
    }
    .background(KimiDesign.surface)
  }
}
