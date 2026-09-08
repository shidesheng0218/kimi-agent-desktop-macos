import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KimiAgentCore

/// 会话输入区：上下文信息条（项目、模型、权限提示）+ 附件条 + 输入框。
/// 通过 scope 参数化:主列(.primary,默认)用活跃会话单例状态,分屏次列
/// (.secondary)按会话 ID 键控,两列能力一致、互不串稿。
struct KimiComposerView: View {
  @ObservedObject var model: KimiAppViewModel
  var scope: KimiComposerScope = .primary
  /// Esc 关闭 @提及浮层后，在 query 变化前保持隐藏。
  @State private var mentionSuppressed = false
  @State private var isDropTargeted = false
  @State private var pasteMonitor: Any?
  /// ⌘V 图片粘贴监听按列路由:只有输入框聚焦的列才认领剪贴板图片。
  @FocusState private var fieldFocused: Bool

  private var draft: KimiComposerDraft { model.composerDraft(for: scope) }
  private var projectPath: String? { model.composerProjectPath(for: scope) }
  private var isBusy: Bool { model.isComposerSessionBusy(for: scope) }

  private var activeProject: String? {
    // 主列沿用会话的 projectPath 展示(与历史一致);次列显示自己会话的目录名。
    switch scope {
    case .primary:
      return model.state.sessions
        .first(where: { $0.id == model.state.activeSessionID })
        .flatMap { $0.projectPath }
        .map { URL(fileURLWithPath: $0).lastPathComponent }
    case .secondary:
      return projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
  }

  private var slashSuggestions: [KimiSlashCommand] {
    let text = draft.text
    guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
    let query = String(text.dropFirst()).lowercased()
    guard !query.isEmpty else { return Array(model.state.availableCommands.prefix(6)) }
    return Array(model.state.availableCommands.filter { $0.name.lowercased().hasPrefix(query) }.prefix(6))
  }

  /// 输入末尾的 @query：@ 位于行首或空白之后，且其后不含空白时处于提及输入态。
  private var mentionQuery: String? {
    let text = draft.text
    guard let atIndex = text.lastIndex(of: "@") else { return nil }
    if let preceding = text[..<atIndex].last, !preceding.isWhitespace { return nil }
    let tail = text[text.index(after: atIndex)...]
    guard !tail.contains(where: { $0.isWhitespace }) else { return nil }
    return String(tail)
  }

  private var mentionCandidates: [String] {
    guard !mentionSuppressed, let query = mentionQuery else { return [] }
    return model.mentionCandidates(for: query, project: projectPath)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !mentionCandidates.isEmpty {
        mentionPopup
      } else if !slashSuggestions.isEmpty {
        slashPopup
      }
      if !draft.attachments.isEmpty {
        attachmentStrip
      }
      if let notice = draft.notice {
        Text(notice)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
      HStack(spacing: 8) {
        if let activeProject {
          // Clickable project chip — lets the user re-bind the active session
          // to a different directory without creating a brand-new session.
          // 次列隐藏重绑定动作(只换活跃会话的目录),仅展示目录名。
          if scope == .primary {
            Button(action: model.changeProjectDirectory) {
              chipContent(icon: "folder", text: activeProject)
            }
            .buttonStyle(.plain)
            .help("点击更换项目文件夹")
          } else {
            chipContent(icon: "folder", text: activeProject)
          }
        }
        // 模型/力度/权限模式是全局状态(非活跃会话单例):两列发送都生效,故都展示。
        modelMenu
        thinkingEffortMenu
        permissionModeMenu
        Spacer()
        HStack(spacing: 4) {
          Image(systemName: model.permissionMode.icon)
            .font(.caption2)
          Text(isBusy ? "执行中：回车可插入指令" : model.permissionMode.composerHint)
            .font(.caption2)
        }
        .foregroundStyle(KimiDesign.muted)
      }
      // Input box with send button embedded inside, right side
      ZStack(alignment: .trailing) {
        TextField("描述你想完成的任务…", text: model.composerTextBinding(for: scope), axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .focused($fieldFocused)
          .padding(.leading, 14)
          .padding(.trailing, 46)   // room for the inline button
          .padding(.vertical, 12)
          .background(KimiDesign.surface)
          .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
          .overlay(
            RoundedRectangle(cornerRadius: KimiDesign.radius)
              .stroke(isDropTargeted ? KimiDesign.primary : KimiDesign.border, lineWidth: 1)
          )
          .onSubmit { model.sendComposerPrompt(for: scope) }
          .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
            handleMentionKey(press)
          }

        // Inline send / stop button
        if isBusy {
          Button(action: { model.abortComposerSession(for: scope) }) {
            Image(systemName: "stop.fill")
              .font(.caption)
              .foregroundStyle(.white)
              .frame(width: 26, height: 26)
              .background(Color.red)
              .clipShape(RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .padding(.trailing, 10)
          .help("停止当前执行")
        } else {
          let isEmpty = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.attachments.isEmpty
          Button(action: { model.sendComposerPrompt(for: scope) }) {
            Image(systemName: "arrow.up")
              .font(.caption)
              .foregroundStyle(.white)
              .frame(width: 26, height: 26)
              .background(isEmpty ? KimiDesign.border : KimiDesign.primary)
              .clipShape(RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .disabled(isEmpty)
          .padding(.trailing, 10)
          .help("发送")
        }
      }
    }
    .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDropTargeted) { providers in
      handleDrop(providers)
      return true
    }
    .onAppear {
      model.refreshMentionIndex(project: projectPath)
      installPasteMonitor()
    }
    .onDisappear {
      if let pasteMonitor {
        NSEvent.removeMonitor(pasteMonitor)
        self.pasteMonitor = nil
      }
      if model.focusedComposerScope == scope { model.focusedComposerScope = .primary }
    }
    .onChange(of: projectPath) { _, _ in model.refreshMentionIndex(project: projectPath) }
    .onChange(of: fieldFocused) { _, focused in
      if focused { model.focusedComposerScope = scope }
    }
    .onChange(of: mentionQuery) { _, _ in
      mentionSuppressed = false
      var draft = draft
      draft.mentionSelection = 0
      model.updateComposerDraft(draft, for: scope)
    }
  }

  // MARK: - @提及浮层

  private var mentionPopup: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(mentionCandidates.enumerated()), id: \.element) { index, path in
        Button {
          model.applyMention(path, replacingQuery: mentionQuery ?? "", scope: scope)
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "doc.text")
              .font(.caption)
              .foregroundStyle(KimiDesign.muted)
            Text("@\((path as NSString).lastPathComponent)")
              .font(.subheadline.monospaced().weight(.medium))
            Text(path)
              .font(.caption)
              .foregroundStyle(KimiDesign.muted)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(index == draft.mentionSelection ? KimiDesign.primary.opacity(0.12) : .clear)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(KimiDesign.border, lineWidth: 1))
  }

  private func handleMentionKey(_ press: KeyPress) -> KeyPress.Result {
    guard !mentionCandidates.isEmpty else { return .ignored }
    var draft = draft
    switch press.key {
    case .upArrow:
      draft.mentionSelection = max(0, draft.mentionSelection - 1)
    case .downArrow:
      draft.mentionSelection = min(mentionCandidates.count - 1, draft.mentionSelection + 1)
    case .return:
      let index = min(draft.mentionSelection, mentionCandidates.count - 1)
      model.applyMention(mentionCandidates[index], replacingQuery: mentionQuery ?? "", scope: scope)
      return .handled
    case .escape:
      mentionSuppressed = true
      return .handled
    default:
      return .ignored
    }
    model.updateComposerDraft(draft, for: scope)
    return .handled
  }

  // MARK: - 斜杠命令浮层

  private var slashPopup: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(slashSuggestions) { command in
        Button {
          var draft = draft
          draft.text = "/\(command.name) "
          model.updateComposerDraft(draft, for: scope)
        } label: {
          HStack(spacing: 8) {
            Text("/\(command.name)")
              .font(.subheadline.monospaced().weight(.medium))
            if let description = command.description, !description.isEmpty {
              Text(description)
                .font(.caption)
                .foregroundStyle(KimiDesign.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(KimiDesign.border, lineWidth: 1))
  }

  // MARK: - 附件条

  private var attachmentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(draft.attachments) { attachment in
          KimiAttachmentChip(attachment: attachment) {
            model.removeComposerAttachment(attachment.id, scope: scope)
          }
        }
      }
    }
  }

  // MARK: - 粘贴与拖拽

  /// ⌘V 时若剪贴板是图片则转为附件，文本粘贴不拦截。
  /// TextField 的 field editor 会自己消化 ⌘V，SwiftUI 的 onPasteCommand 到不了，
  /// 所以用与 Esc 监听相同的本地事件监听方案，只认图片数据、其余原样放行。
  /// 分屏两列各装一个监听,靠 focusedComposerScope 把图片路由到正在输入的列。
  private func installPasteMonitor() {
    guard pasteMonitor == nil else { return }
    pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 9, // V
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
            event.window?.firstResponder is NSTextView,
            model.focusedComposerScope == scope
      else { return event }
      return model.pasteComposerImage(from: .general, scope: scope) ? nil : event
    }
  }

  private func handleDrop(_ providers: [NSItemProvider]) {
    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in model.addComposerFileURLs([url], scope: scope) }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
          guard let data else { return }
          Task { @MainActor in model.addComposerImageData(data, suggestedName: nil, scope: scope) }
        }
      }
    }
  }

  private var modelMenu: some View {
    HoverableMenu(icon: "cpu", text: model.state.selectedModel) {
      ForEach(model.state.modelCatalog, id: \.self) { item in
        Button {
          model.changeModel(item)
        } label: {
          HStack {
            Text(item)
            if item == model.state.selectedModel {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    }
  }

  private var thinkingEffortMenu: some View {
    HoverableMenu(icon: "brain", text: model.state.thinkingEffort) {
      ForEach(["Low", "Medium", "High"], id: \.self) { effort in
        Button {
          model.changeThinkingEffort(effort)
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(effort)
                .font(.subheadline.weight(.medium))
              Text(effortDescription(effort))
                .font(.caption2)
                .foregroundStyle(KimiDesign.muted)
            }
            Spacer()
            if effort == model.state.thinkingEffort {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    }
  }

  private var permissionModeMenu: some View {
    HoverableMenu(icon: model.permissionMode.icon, text: model.permissionMode.title) {
      ForEach(KimiSessionPermissionMode.allCases, id: \.self) { mode in
        Button {
          model.changePermissionMode(mode)
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(mode.title)
                .font(.subheadline.weight(.medium))
              Text(mode.summary)
                .font(.caption2)
                .foregroundStyle(KimiDesign.muted)
            }
            Spacer()
            if mode == model.permissionMode {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    }
    .help("权限模式：计划模式下只规划不改动文件")
  }

  private func effortDescription(_ effort: String) -> String {
    switch effort {
    case "Low": return "快速响应，适合简单任务"
    case "Medium": return "平衡速度与质量"
    case "High": return "深度思考，适合复杂问题"
    default: return ""
    }
  }

  private func chip(icon: String, text: String) -> some View {
    chipContent(icon: icon, text: text)
  }

  private func chipContent(icon: String, text: String) -> some View {
    HoverableChip(icon: icon, text: text)
  }
}

/// 附件条里的一项：图片显示缩略图，文件显示文件名 chip，右上角 × 删除。
private struct KimiAttachmentChip: View {
  let attachment: KimiPromptAttachment
  let onRemove: () -> Void

  var body: some View {
    Group {
      if attachment.isImage, let data = attachment.imageData, let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 44, height: 44)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      } else {
        HStack(spacing: 5) {
          Image(systemName: attachment.isImage ? "photo" : "doc")
            .font(.caption2)
          Text(attachment.filename)
            .font(.caption.weight(.medium))
            .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
      }
    }
    .foregroundStyle(KimiDesign.muted)
    .background(KimiDesign.surfaceSecondary)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(alignment: .topTrailing) {
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(KimiDesign.muted)
      }
      .buttonStyle(.plain)
      .offset(x: 4, y: -4)
      .help("移除附件")
    }
    .help(attachment.filename)
  }
}

/// Hoverable chip with visual feedback
private struct HoverableChip: View {
  let icon: String
  let text: String
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.caption2)
      Text(text)
        .font(.caption.weight(.medium))
        .lineLimit(1)
    }
    .foregroundStyle(KimiDesign.muted)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(isHovered ? Color.gray.opacity(0.25) : KimiDesign.surfaceSecondary)
    .clipShape(Capsule())
    .animation(.easeInOut(duration: 0.15), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
    }
  }
}

/// Hoverable menu with chip appearance
private struct HoverableMenu<Content: View>: View {
  let icon: String
  let text: String
  @ViewBuilder let content: Content
  @State private var isHovered = false

  var body: some View {
    Menu {
      content
    } label: {
      HStack(spacing: 5) {
        Image(systemName: icon).font(.caption2)
        Text(text)
          .font(.caption.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle(KimiDesign.muted)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(isHovered ? Color.gray.opacity(0.25) : KimiDesign.surfaceSecondary)
      .clipShape(Capsule())
      .animation(.easeInOut(duration: 0.15), value: isHovered)
      .onHover { hovering in
        isHovered = hovering
      }
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
  }
}
