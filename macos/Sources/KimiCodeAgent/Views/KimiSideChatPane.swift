import SwiftUI
import KimiAgentCore

/// ⌘; 侧聊面板:当前会话的临时 fork 线程。能读到主会话上下文(引擎侧
/// fork 携带完整历史),但消息不写入主会话;关闭面板即删除该临时会话。
/// 只发文本,不支持附件。
struct KimiSideChatPane: View {
  @ObservedObject var model: KimiAppViewModel
  let sideChat: KimiSideChatState

  /// 侧聊会话产生的权限请求(主时间线按会话过滤后不再展示它们)。
  private var pendingPermissions: [KimiPermissionRequest] {
    model.state.pendingPermissions.filter { $0.sessionRuntimeID == sideChat.sessionRuntimeID }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("侧聊", systemImage: "bubble.left.and.bubble.right")
          .font(.headline)
        Spacer()
        if sideChat.busy {
          ProgressView().controlSize(.small)
          Button("停止", action: model.abortSideChat)
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
        }
        Button(action: model.toggleSideChat) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(KimiDesign.muted)
        .help("关闭侧聊 (⌘;),临时会话将被删除")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      Text("独立线程 · 携带主会话上下文,不写入主会话")
        .font(.caption2)
        .foregroundStyle(KimiDesign.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if sideChat.messages.isEmpty {
              Text("围绕当前会话随便问:解释改动、讨论方案、查漏补缺,都不会打扰主会话。")
                .font(.caption)
                .foregroundStyle(KimiDesign.muted)
                .padding(.top, 12)
            }
            ForEach(sideChat.messages) { message in
              KimiMessageRow(message: message, model: model)
                .id(message.id)
            }
            ForEach(pendingPermissions) { permission in
              KimiPermissionCard(
                permission: permission,
                approve: { model.approve(permission.id) },
                approveAlways: { model.approveAlways(permission.id) },
                deny: { model.deny(permission.id) }
              )
              .id(permission.id)
            }
            if let error = sideChat.error {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(14)
        }
        .onChange(of: sideChat.messages.count) { _, _ in
          if let id = sideChat.messages.last?.id {
            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
          }
        }
        .onChange(of: sideChat.messages.last?.text) { _, _ in
          if let id = sideChat.messages.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
          }
        }
      }

      Divider()
      HStack(spacing: 8) {
        TextField("就当前会话提问…", text: $model.sideChatDraft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.subheadline)
          .lineLimit(1...5)
          .onSubmit(model.sendSideChat)
        Button(action: model.sendSideChat) {
          Image(systemName: "arrow.up.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(KimiDesign.primary)
        .disabled(sideChatDraftEmpty)
        .help("发送 (Enter)")
      }
      .padding(10)
      .background(KimiDesign.surfaceSecondary)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .padding(12)
    }
    .background(KimiDesign.surface)
  }

  private var sideChatDraftEmpty: Bool {
    model.sideChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
