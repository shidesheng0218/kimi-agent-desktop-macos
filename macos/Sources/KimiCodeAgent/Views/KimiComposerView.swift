import SwiftUI
import KimiAgentCore

/// 会话输入区：上下文信息条（项目、模型、权限提示）+ 输入框。
struct KimiComposerView: View {
  @ObservedObject var model: KimiAppViewModel

  private var activeProject: String? {
    model.state.sessions
      .first(where: { $0.id == model.state.activeSessionID })
      .flatMap { $0.projectPath }
      .map { URL(fileURLWithPath: $0).lastPathComponent }
  }

  private var slashSuggestions: [KimiSlashCommand] {
    let text = model.composerText
    guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
    let query = String(text.dropFirst()).lowercased()
    guard !query.isEmpty else { return Array(model.state.availableCommands.prefix(6)) }
    return Array(model.state.availableCommands.filter { $0.name.lowercased().hasPrefix(query) }.prefix(6))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !slashSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(slashSuggestions) { command in
            Button {
              model.composerText = "/\(command.name) "
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
      HStack(spacing: 8) {
        if let activeProject {
          // Clickable project chip — lets the user re-bind the active session
          // to a different directory without creating a brand-new session.
          Button(action: model.changeProjectDirectory) {
            chipContent(icon: "folder", text: activeProject)
          }
          .buttonStyle(.plain)
          .help("点击更换项目文件夹")
        }
        modelMenu
        thinkingEffortMenu
        Spacer()
        HStack(spacing: 4) {
          Image(systemName: "hand.raised")
            .font(.caption2)
          Text(model.isActiveSessionBusy ? "执行中：回车可插入指令" : "高风险操作需逐次确认")
            .font(.caption2)
        }
        .foregroundStyle(KimiDesign.muted)
      }
      // Input box with send button embedded inside, right side
      ZStack(alignment: .trailing) {
        TextField("描述你想完成的任务…", text: $model.composerText, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .padding(.leading, 14)
          .padding(.trailing, 46)   // room for the inline button
          .padding(.vertical, 12)
          .background(KimiDesign.surface)
          .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
          .overlay(
            RoundedRectangle(cornerRadius: KimiDesign.radius)
              .stroke(KimiDesign.border, lineWidth: 1)
          )
          .onSubmit { model.sendPrompt() }

        // Inline send / stop button
        if model.isActiveSessionBusy {
          Button(action: model.abortActive) {
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
          let isEmpty = model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          Button(action: model.sendPrompt) {
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
