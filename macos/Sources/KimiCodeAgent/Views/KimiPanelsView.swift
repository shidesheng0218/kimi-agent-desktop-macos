import SwiftUI
import AppKit
import KimiAgentCore

/// 面板槽位:面板视图与所在槽位解耦——同一面板可挂在主区或次面板槽,
/// 槽位只决定「返回会话/关闭面板」按钮的行为与外层布局,面板实现本身
/// 不感知槽位以外的布局。后续扩展更多槽位时只需改 KimiAuxPaneHost。
enum KimiPanelSlot {
  case primary
  case secondary

  /// 面板头部右侧按钮文案:主区面板「返回会话」,次槽面板「关闭面板」。
  var backTitle: String { self == .primary ? "返回会话" : "关闭面板" }
}

/// 会话头部面板菜单的清单:(面板, 标题)。会话不是面板,不在其中;
/// 「在主区显示」与「在次面板显示」两组菜单项共用这份顺序。
let kimiAuxPaneMenu: [(pane: KimiActivePane, title: String)] = [
  (.diff, "Diff"),
  (.browser, "Browser"),
  (.files, "Files"),
  (.tasks, "后台任务"),
  (.verification, "验证"),
  (.integrations, "集成"),
]

/// 槽位宿主:按 KimiActivePane 渲染对应面板,并把槽位透传给面板的头部
/// (次槽的关闭按钮只关次槽,不动主区)。.conversation 不是面板,渲染空。
struct KimiAuxPaneHost: View {
  @ObservedObject var model: KimiAppViewModel
  let pane: KimiActivePane
  var slot: KimiPanelSlot = .primary

  var body: some View {
    switch pane {
    case .conversation:
      EmptyView()
    case .diff:
      KimiDiffPane(model: model, slot: slot)
    case .browser:
      KimiBrowserPane(model: model, slot: slot)
    case .files:
      KimiFilesPane(model: model, slot: slot)
    case .verification:
      KimiVerificationPane(model: model, slot: slot)
    case .integrations:
      KimiIntegrationsPane(model: model, slot: slot)
    case .tasks:
      KimiTasksPane(model: model, slot: slot)
    }
  }
}

/// Shared header for the workspace's secondary panes.
private struct KimiPaneHeader: View {
  let title: String
  let icon: String
  var trailing: String? = nil
  var refresh: (() -> Void)? = nil
  /// 次面板槽里叫「关闭面板」(只关次槽);主区保持「返回会话」。
  var backTitle: String = "返回会话"
  let back: () -> Void

  var body: some View {
    HStack {
      Label(title, systemImage: icon).font(.title3.weight(.semibold))
      Spacer()
      if let trailing {
        Text(trailing).font(.caption).foregroundStyle(KimiDesign.muted)
      }
      if let refresh {
        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless)
          .help("刷新")
      }
      Button(backTitle, action: back).buttonStyle(.bordered)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 18)
  }
}

private struct KimiPaneEmpty: View {
  let icon: String
  let text: String

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 36)).foregroundStyle(KimiDesign.primary)
      Text(text).foregroundStyle(KimiDesign.muted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Diff 审阅

struct KimiDiffPane: View {
  @ObservedObject var model: KimiAppViewModel
  var slot: KimiPanelSlot = .primary
  @State private var selectedPath: String?
  @AppStorage("kimi.layout.diffFileListWidth") private var fileListWidth: Double = 240

  private var files: [FileDiff] { model.diffSnapshot?.files ?? [] }
  private var additions: Int { files.reduce(0) { $0 + $1.additions } }
  private var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

  private var selectedFile: FileDiff? {
    files.first(where: { $0.path == selectedPath }) ?? files.first
  }

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "Diff 审阅",
        icon: "arrow.left.arrow.right",
        trailing: files.isEmpty ? nil : "\(files.count) 个文件 · +\(additions) −\(deletions)",
        refresh: { Task { await model.loadDiff() } },
        backTitle: slot.backTitle,
        back: { model.closePanel(in: slot) }
      )
      if let notice = model.diffReviewNotice {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          Text(notice).font(.subheadline)
          Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(KimiDesign.surfaceSecondary)
      }
      if model.diffLoading {
        ProgressView("正在计算工作区改动…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diffError = model.diffError {
        // A failed git invocation (not a repo, git missing, …) is not the
        // same as a clean working tree — never render it as "no changes".
        KimiPaneEmpty(icon: "exclamationmark.triangle", text: "无法计算工作区改动：\(diffError)")
      } else if files.isEmpty {
        KimiPaneEmpty(icon: "checkmark.circle", text: "工作区没有未提交的改动。")
      } else {
        HStack(spacing: 0) {
          KimiDiffSidebar(model: model, files: files, selectedPath: $selectedPath)
            .frame(width: fileListWidth)
          KimiResizeDivider(width: $fileListWidth, range: 180...380)
          if let file = selectedFile {
            KimiDiffDetail(file: file, model: model)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
    }
    .background(KimiDesign.background)
    .background(
      Button("") { model.sendDiffReview() }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(model.diffComments.isEmpty)
        .hidden()
    )
    .task { await model.loadDiff() }
    .onChange(of: files.map(\.path)) { _, paths in
      // 刷新后选中文件可能已不在 diff 里，回退到第一个文件。
      if let selectedPath, !paths.contains(selectedPath) { self.selectedPath = nil }
    }
  }
}

/// 左侧栏：文件列表（+N/−M、选中态）+ 待提交评论列表与发送/放弃操作。
private struct KimiDiffSidebar: View {
  @ObservedObject var model: KimiAppViewModel
  let files: [FileDiff]
  @Binding var selectedPath: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { model.requestAIReview() } label: {
          Label("AI 评审", systemImage: "sparkle.magnifyingglass")
            .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .help("把当前改动发给引擎自审编译错误、逻辑错误、安全漏洞和明显 bug")
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(files) { file in
            KimiDiffFileRow(
              file: file,
              selected: file.path == (selectedPath ?? files.first?.path),
              commentCount: model.diffComments.filter { $0.filePath == file.path }.count
            )
            .contentShape(Rectangle())
            .onTapGesture { selectedPath = file.path }
          }
        }
        .padding(8)
      }
      if !model.diffComments.isEmpty {
        Divider()
        KimiDiffPendingComments(model: model)
      }
    }
    .background(KimiDesign.surface.opacity(0.5))
  }
}

private struct KimiDiffFileRow: View {
  let file: FileDiff
  let selected: Bool
  let commentCount: Int

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption)
        .foregroundStyle(KimiDesign.primary)
      Text(file.path)
        .font(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      if commentCount > 0 {
        Text("\(commentCount)")
          .font(.caption2)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(KimiDesign.accent.opacity(0.2))
          .clipShape(Capsule())
      }
      Text("+\(file.additions)").font(.caption2).foregroundStyle(.green)
      Text("−\(file.deletions)").font(.caption2).foregroundStyle(.red)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(selected ? KimiDesign.primary.opacity(0.12) : .clear)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var icon: String {
    switch file.status {
    case .added: "doc.badge.plus"
    case .deleted: "doc.badge.minus"
    case .renamed: "doc.on.doc"
    case .modified: "doc.text"
    }
  }
}

/// 待提交评论列表：过期评论保留并标记，可单条删除；⌘Enter 或按钮发送全部。
private struct KimiDiffPendingComments: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("待提交评审意见 \(model.diffComments.count) 条")
          .font(.caption.weight(.medium))
        Spacer()
        Button("放弃全部") { model.discardDiffComments() }
          .font(.caption)
          .buttonStyle(.borderless)
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(model.diffComments) { comment in
            HStack(alignment: .top, spacing: 6) {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                  Text("\(comment.filePath):\(comment.line)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(KimiDesign.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                  if comment.stale {
                    Text("已过期")
                      .font(.caption2)
                      .padding(.horizontal, 4)
                      .padding(.vertical, 1)
                      .background(Color.orange.opacity(0.2))
                      .clipShape(Capsule())
                  }
                }
                Text(comment.text)
                  .font(.caption)
                  .foregroundStyle(comment.stale ? KimiDesign.muted : KimiDesign.text)
                  .strikethrough(comment.stale)
                  .lineLimit(2)
              }
              Spacer(minLength: 0)
              Button { model.removeDiffComment(comment.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.caption)
              }
              .buttonStyle(.plain)
              .foregroundStyle(KimiDesign.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
          }
        }
      }
      .frame(maxHeight: 160)
      HStack {
        Spacer()
        Button { model.sendDiffReview() } label: {
          Label("发送评审意见 (⌘Enter)", systemImage: "paperplane")
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .background(KimiDesign.surface)
  }
}

/// 右侧：选中文件的完整 diff，行号 + 点击任意行展开评论输入框。
private struct KimiDiffDetail: View {
  let file: FileDiff
  @ObservedObject var model: KimiAppViewModel
  @State private var editingRowID: Int?
  @State private var commentDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        // 路径可点击：进文件面板预览；右键走统一的路径菜单。
        Button(action: { model.navigateToFile(file.path) }) {
          Text(file.path)
            .font(.subheadline.monospaced().weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(KimiDesign.primary)
        .contextMenu {
          KimiFilePathContextMenu(path: file.path, isDirectory: false, model: model)
        }
        Spacer()
        Text("点击任意行添加评审评论")
          .font(.caption)
          .foregroundStyle(KimiDesign.muted)
        Text("+\(file.additions)").font(.caption).foregroundStyle(.green)
        Text("−\(file.deletions)").font(.caption).foregroundStyle(.red)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(file.displayRows()) { row in
            switch row.kind {
            case .hunkHeader(let title):
              Text(title)
                .font(.caption.monospaced())
                .foregroundStyle(KimiDesign.accent)
                .padding(.vertical, 6)
                .padding(.leading, 44)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KimiDesign.surfaceSecondary.opacity(0.6))
            case .line(let number, let isDeletion):
              lineRow(row: row, number: number, isDeletion: isDeletion)
            }
          }
        }
        .padding(.vertical, 8)
      }
    }
    .background(KimiDesign.surface)
    .onChange(of: file.path) { _, _ in
      editingRowID = nil
      commentDraft = ""
    }
  }

  private func comments(on number: Int, content: String) -> [KimiDiffComment] {
    model.diffComments.filter {
      $0.filePath == file.path && $0.line == number && $0.lineContent == content
    }
  }

  @ViewBuilder
  private func lineRow(row: DiffDisplayRow, number: Int, isDeletion: Bool) -> some View {
    let content = String(row.text.dropFirst())
    let anchored = comments(on: number, content: content)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Rectangle()
          .fill(anchored.isEmpty ? .clear : KimiDesign.accent)
          .frame(width: 3)
        Text("\(number)")
          .font(.caption2.monospaced())
          .foregroundStyle(KimiDesign.muted)
          .frame(width: 40, alignment: .trailing)
          .padding(.trailing, 8)
        Text(row.text.isEmpty ? " " : row.text)
          .font(.caption.monospaced())
          .foregroundStyle(color(for: row.text))
        Spacer(minLength: 0)
        if !anchored.isEmpty {
          Image(systemName: "text.bubble.fill")
            .font(.caption2)
            .foregroundStyle(KimiDesign.accent)
            .padding(.trailing, 8)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(background(for: row.text))
      .contentShape(Rectangle())
      .onTapGesture {
        if editingRowID == row.id {
          editingRowID = nil
          commentDraft = ""
        } else {
          editingRowID = row.id
          commentDraft = ""
        }
      }
      ForEach(anchored) { comment in
        HStack(spacing: 6) {
          Image(systemName: "text.bubble").font(.caption2).foregroundStyle(KimiDesign.accent)
          Text(comment.text)
            .font(.caption)
            .foregroundStyle(comment.stale ? KimiDesign.muted : KimiDesign.text)
          if comment.stale {
            Text("已过期").font(.caption2).foregroundStyle(.orange)
          }
          Spacer()
          Button { model.removeDiffComment(comment.id) } label: {
            Image(systemName: "xmark.circle.fill").font(.caption2)
          }
          .buttonStyle(.plain)
          .foregroundStyle(KimiDesign.muted)
        }
        .padding(.leading, 48)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KimiDesign.accent.opacity(0.06))
      }
      if editingRowID == row.id {
        VStack(alignment: .leading, spacing: 6) {
          TextEditor(text: $commentDraft)
            .font(.caption)
            .frame(minHeight: 48, maxHeight: 96)
            .padding(4)
            .background(KimiDesign.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(KimiDesign.border, lineWidth: 1))
          HStack(spacing: 8) {
            Button("添加评论") {
              model.addDiffComment(filePath: file.path, line: number, lineContent: content, text: commentDraft)
              editingRowID = nil
              commentDraft = ""
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消") {
              editingRowID = nil
              commentDraft = ""
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            Spacer()
          }
        }
        .padding(.leading, 48)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(KimiDesign.accent.opacity(0.06))
      }
    }
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

// MARK: - 项目文件

private struct KimiFileNode: Identifiable, Hashable {
  let url: URL
  let isDirectory: Bool
  var id: URL { url }

  var name: String { url.lastPathComponent }

  var children: [KimiFileNode]? {
    guard isDirectory else { return nil }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    let nodes = names
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .prefix(200)
      .map { name -> KimiFileNode in
        let child = url.appendingPathComponent(name)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
        return KimiFileNode(url: child, isDirectory: isDir.boolValue)
      }
    return nodes.sorted { ($0.isDirectory ? 0 : 1) < ($1.isDirectory ? 0 : 1) }
  }
}

struct KimiFilesPane: View {
  @ObservedObject var model: KimiAppViewModel
  var slot: KimiPanelSlot = .primary
  @State private var selectedFile: URL?
  @State private var preview: String = ""
  @State private var editing = false
  @State private var draft = ""
  /// 载入时的全文与 mtime：dirty 判定（draft != loadedText）与磁盘冲突检测用。
  /// 仅在文件完整载入（≤64KB 且为 UTF-8 文本）时非空，此时才可编辑。
  @State private var loadedText: String?
  @State private var loadedMTime: Date?
  @State private var loadedBinary = false
  @State private var loadedTruncated = false
  @State private var showConflictDialog = false
  @State private var fileNotice: String?
  /// 进入过编辑模式才算有草稿：否则 draft 恒为空串会误判 dirty。
  @State private var draftTouched = false

  private var root: KimiFileNode? {
    guard let path = model.activeProjectPath, !path.isEmpty else { return nil }
    return KimiFileNode(url: URL(fileURLWithPath: path, isDirectory: true), isDirectory: true)
  }

  private var editable: Bool { loadedText != nil }
  private var isDirty: Bool { draftTouched && loadedText != nil && draft != loadedText }

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "项目文件",
        icon: "folder",
        trailing: model.activeProjectPath,
        backTitle: slot.backTitle,
        back: { model.closePanel(in: slot) }
      )
      if let root {
        HSplitView {
          ScrollView {
            OutlineGroup(root.children ?? [], children: \.children) { node in
              HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
                  .font(.caption)
                  .foregroundStyle(node.isDirectory ? KimiDesign.primary : KimiDesign.muted)
                Text(node.name)
                  .font(.subheadline)
                  .lineLimit(1)
              }
              .padding(.vertical, 2)
              .contentShape(Rectangle())
              .onTapGesture {
                guard !node.isDirectory else { return }
                selectedFile = node.url
                loadPreview(node.url)
              }
              .contextMenu {
                KimiFilePathContextMenu(path: node.url.path, isDirectory: node.isDirectory, model: model)
              }
            }
            .padding(12)
          }
          .frame(minWidth: 220, maxWidth: 300)
          if let selectedFile {
            VStack(spacing: 0) {
              editorHeader(for: selectedFile)
              Divider()
              if editing, editable {
                TextEditor(text: $draft)
                  .font(.caption.monospaced())
                  .padding(8)
              } else {
                ScrollView {
                  Text(preview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
              }
            }
            .background(KimiDesign.surface)
            .confirmationDialog("文件已在磁盘上被修改", isPresented: $showConflictDialog, titleVisibility: .visible) {
              Button("覆盖保存") { writeDraft() }
              Button("放弃我的修改并重新加载") { loadPreview(selectedFile) }
              Button("取消", role: .cancel) {}
            } message: {
              Text("磁盘上的版本与载入时不一致，直接保存会覆盖外部修改。")
            }
          }
        }
      } else {
        KimiPaneEmpty(icon: "folder.badge.questionmark", text: "选择项目后将在这里显示文件。")
      }
    }
    .background(KimiDesign.background)
    .onChange(of: model.revealedFileURL) { _, url in
      // 聊天/diff 里的路径点击跳转：定位到文件并载入预览。
      guard let url else { return }
      selectedFile = url
      loadPreview(url)
      model.revealedFileURL = nil
    }
  }

  private func editorHeader(for url: URL) -> some View {
    HStack(spacing: 8) {
      Text(url.lastPathComponent)
        .font(.subheadline.monospaced().weight(.medium))
        .lineLimit(1)
        .truncationMode(.middle)
      if isDirty {
        Text("未保存")
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.orange.opacity(0.2))
          .clipShape(Capsule())
      }
      if let fileNotice {
        Text(fileNotice).font(.caption).foregroundStyle(.red).lineLimit(1)
      }
      Spacer()
      if loadedBinary {
        Text("二进制文件，不支持编辑").font(.caption).foregroundStyle(KimiDesign.muted)
      } else if loadedTruncated {
        Text("超过 64KB，超出部分只读").font(.caption).foregroundStyle(KimiDesign.muted)
      } else if editable {
        if editing {
          Button("放弃更改") { draft = loadedText ?? ""; draftTouched = false; editing = false }
            .buttonStyle(.borderless)
            .disabled(!isDirty)
          Button("保存") { attemptSave() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isDirty)
        }
        Button(editing ? "预览" : "编辑") {
          if editing {
            editing = false
          } else {
            if !draftTouched { draft = loadedText ?? "" }
            draftTouched = true
            editing = true
          }
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func loadPreview(_ url: URL) {
    editing = false
    draft = ""
    draftTouched = false
    loadedText = nil
    loadedBinary = false
    loadedTruncated = false
    fileNotice = nil
    loadedMTime = modificationDate(of: url)
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      preview = "无法读取文件。"
      return
    }
    let capped = data.prefix(65_536)
    loadedTruncated = data.count > capped.count
    guard let text = String(data: capped, encoding: .utf8) else {
      loadedBinary = true
      preview = "（二进制文件，不支持预览与编辑）"
      return
    }
    loadedText = loadedTruncated ? nil : text
    preview = text
    if loadedTruncated { preview += "\n\n…（已截断，超出部分只读）" }
  }

  private func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  /// 保存前做磁盘冲突检测：mtime 或内容与载入时不一致则弹确认框。
  private func attemptSave() {
    guard let url = selectedFile, let loadedText else { return }
    let diskMTime = modificationDate(of: url)
    let diskText = (try? Data(contentsOf: url, options: [.mappedIfSafe])).flatMap { String(data: $0, encoding: .utf8) }
    if diskMTime != loadedMTime || diskText != loadedText {
      showConflictDialog = true
      return
    }
    writeDraft()
  }

  private func writeDraft() {
    guard let url = selectedFile else { return }
    do {
      try draft.write(to: url, atomically: true, encoding: .utf8)
      loadedText = draft
      loadedMTime = modificationDate(of: url)
      preview = draft
      editing = false
      draftTouched = false
      fileNotice = nil
      refreshDiffIfNeeded(for: url)
    } catch {
      fileNotice = "保存失败：\(error.localizedDescription)"
    }
  }

  /// 保存成功后，若该文件出现在 diff 面板中，触发一次 diff 刷新。
  private func refreshDiffIfNeeded(for url: URL) {
    guard let project = model.activeProjectPath, let snapshot = model.diffSnapshot else { return }
    let root = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return }
    let relative = String(path.dropFirst(root.count + 1))
    guard snapshot.files.contains(where: { $0.path == relative }) else { return }
    Task { await model.loadDiff() }
  }
}

// MARK: - 验证（Harness Intent/Receipt 审计）

struct KimiVerificationPane: View {
  @ObservedObject var model: KimiAppViewModel
  var slot: KimiPanelSlot = .primary

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "验证与副作用回执",
        icon: "checkmark.seal",
        trailing: "\(model.verificationRecords.count) 条记录",
        refresh: { Task { await model.loadVerification() } },
        backTitle: slot.backTitle,
        back: { model.closePanel(in: slot) }
      )
      if model.verificationRecords.isEmpty {
        KimiPaneEmpty(icon: "checkmark.seal", text: "当前没有已记录的副作用回执。")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.verificationRecords) { record in
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: record))
                  .foregroundStyle(color(for: record))
                  .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                  HStack {
                    Text(record.subject).font(.subheadline.weight(.medium))
                    Text(record.risk)
                      .font(.caption2)
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(KimiDesign.surfaceSecondary)
                      .clipShape(Capsule())
                  }
                  if let error = record.errorMessage, !error.isEmpty {
                    Text(error)
                      .font(.caption)
                      .foregroundStyle(.red)
                      .lineLimit(3)
                  }
                }
                Spacer()
                Text(record.outcome ?? "进行中")
                  .font(.caption)
                  .foregroundStyle(color(for: record))
              }
              .padding(12)
              .background(KimiDesign.surface)
              .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
            }
          }
          .padding(24)
        }
      }
    }
    .background(KimiDesign.background)
    .task { await model.loadVerification() }
  }

  private func icon(for record: KimiVerificationRecord) -> String {
    switch record.outcome {
    case "success": "checkmark.circle.fill"
    case "failure": "xmark.circle.fill"
    case "cancelled": "minus.circle.fill"
    default: "clock"
    }
  }

  private func color(for record: KimiVerificationRecord) -> Color {
    switch record.outcome {
    case "success": .green
    case "failure": .red
    case "cancelled": .orange
    default: KimiDesign.muted
    }
  }
}

// MARK: - 集成（MCP / Skills）

struct KimiIntegrationsPane: View {
  @ObservedObject var model: KimiAppViewModel
  var slot: KimiPanelSlot = .primary

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "集成",
        icon: "puzzlepiece.extension",
        refresh: { Task { await model.loadIntegrations() } },
        backTitle: slot.backTitle,
        back: { model.closePanel(in: slot) }
      )
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 10) {
            Text("MCP 服务器").font(.headline)
            if model.integrationStatus.mcpServers.isEmpty {
              Text("未配置 MCP 服务器。可在引擎配置中添加后重启运行时。")
                .font(.subheadline)
                .foregroundStyle(KimiDesign.muted)
            } else {
              ForEach(model.integrationStatus.mcpServers) { server in
                HStack(spacing: 10) {
                  Circle()
                    .fill(server.status == "connected" ? Color.green : (server.status == "failed" ? Color.red : Color.orange))
                    .frame(width: 8, height: 8)
                  Text(server.name).font(.subheadline.weight(.medium))
                  Text(server.status).font(.caption).foregroundStyle(KimiDesign.muted)
                  Spacer()
                  if let detail = server.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.red).lineLimit(1)
                  }
                }
                .padding(12)
                .background(KimiDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
              }
            }
          }
          VStack(alignment: .leading, spacing: 10) {
            Text("Skills").font(.headline)
            if model.integrationStatus.skills.isEmpty {
              Text("未发现技能。项目 .kimi/skills 或插件内的 SKILL.md 会被自动注册。")
                .font(.subheadline)
                .foregroundStyle(KimiDesign.muted)
            } else {
              ForEach(model.integrationStatus.skills) { skill in
                VStack(alignment: .leading, spacing: 3) {
                  Text(skill.name).font(.subheadline.weight(.medium))
                  if let description = skill.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(KimiDesign.muted)
                  }
                }
                .padding(12)
                .background(KimiDesign.surface)
                .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
              }
            }
          }
        }
        .padding(24)
      }
    }
    .background(KimiDesign.background)
    .task { await model.loadIntegrations() }
  }
}

// MARK: - Browser 预览

struct KimiBrowserPane: View {
  @ObservedObject var model: KimiAppViewModel
  var slot: KimiPanelSlot = .primary

  var body: some View {
    // 控制器挂在 ViewModel 上(常驻),面板只是它的视图;单独包一层
    // @ObservedObject 让控制器/dev server 的变更能触发这里刷新。
    KimiBrowserPaneBody(model: model, preview: model.browserPreview, devServer: model.devServer, slot: slot)
  }
}

private struct KimiBrowserPaneBody: View {
  @ObservedObject var model: KimiAppViewModel
  @ObservedObject var preview: KimiBrowserPreviewController
  @ObservedObject var devServer: KimiDevServerManager
  var slot: KimiPanelSlot
  @State private var showStartConfirm = false
  @State private var showServerOutput = false
  @State private var devPlan: KimiDevServerPlan?

  private var imageArtifacts: [URL] {
    KimiArtifactImages.extract(from: model.state.activities.compactMap(\.detail))
  }

  private var browserActivities: [KimiActivity] {
    model.state.activities.filter {
      let title = $0.title.lowercased()
      return title.contains("browser") || title.contains("浏览器") || title.contains("kimi_browser")
    }
  }

  private var workingPath: String? {
    model.state.sessions.first(where: { $0.id == model.state.activeSessionID })?.workingPath
  }

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "Browser",
        icon: "safari",
        trailing: preview.pageTitle,
        backTitle: slot.backTitle,
        back: { model.closePanel(in: slot) }
      )
      Picker("面板内容", selection: $preview.section) {
        ForEach(KimiBrowserPreviewController.Section.allCases) { section in
          Text(section.title).tag(section)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 24)
      .padding(.bottom, 10)
      switch preview.section {
      case .preview:
        previewContent
      case .artifacts:
        artifactsContent
      }
    }
    .background(KimiDesign.background)
    .task(id: model.state.activeSessionID) {
      devPlan = workingPath.flatMap {
        KimiBrowserPreviewSupport.devServerPlan(forProjectRoot: URL(fileURLWithPath: $0, isDirectory: true))
      }
    }
  }

  // MARK: 交互预览

  private var previewContent: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button { preview.goBack() } label: { Image(systemName: "chevron.left") }
          .buttonStyle(.borderless)
          .disabled(!preview.canGoBack)
          .help("后退")
        Button { preview.goForward() } label: { Image(systemName: "chevron.right") }
          .buttonStyle(.borderless)
          .disabled(!preview.canGoForward)
          .help("前进")
        Button { preview.isLoading ? preview.stopLoading() : preview.reload() } label: {
          Image(systemName: preview.isLoading ? "xmark" : "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help(preview.isLoading ? "停止加载" : "刷新")
        TextField("输入网址或本地文件路径,回车打开", text: $preview.addressText)
          .textFieldStyle(.roundedBorder)
          .font(.callout)
          .onSubmit { preview.submitAddress() }
        Button { preview.openExternally() } label: { Image(systemName: "safari") }
          .buttonStyle(.borderless)
          .help("在外部浏览器打开")
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 6)
      devServerBar
      KimiWebPreviewView(webView: preview.webView)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(KimiDesign.border, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
      Text("预览浏览器 · 与验证沙箱隔离")
        .font(.caption2)
        .foregroundStyle(KimiDesign.muted)
        .padding(.bottom, 10)
    }
  }

  // MARK: 开发服务器

  @ViewBuilder
  private var devServerBar: some View {
    let sessionID = model.state.activeSessionID
    let server = devServer.state(for: sessionID)
    if server != nil || devPlan != nil {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: "server.rack")
            .font(.caption)
            .foregroundStyle(KimiDesign.muted)
          if let server {
            Circle()
              .fill(server.running ? Color.green : Color.gray)
              .frame(width: 7, height: 7)
            Text(server.command)
              .font(.caption)
              .foregroundStyle(KimiDesign.text)
            if server.running, let url = server.detectedURL {
              Button(url.absoluteString) { preview.navigate(to: url) }
                .buttonStyle(.link)
                .font(.caption)
            }
            if let error = server.lastError {
              Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
            }
            Spacer()
            if !server.tailLines.isEmpty {
              Button(showServerOutput ? "隐藏输出" : "查看输出") { showServerOutput.toggle() }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            if server.running, let sessionID {
              Button("停止") { devServer.stop(sessionID: sessionID) }
                .controlSize(.small)
            } else if devPlan != nil {
              Button("重新启动") { showStartConfirm = true }
                .controlSize(.small)
            }
          } else if let devPlan {
            Text("检测到 \(devPlan.displayCommand)")
              .font(.caption)
              .foregroundStyle(KimiDesign.muted)
            Spacer()
            Button("启动开发服务器") { showStartConfirm = true }
              .controlSize(.small)
          }
        }
        if showServerOutput, let server, !server.tailLines.isEmpty {
          ScrollView {
            Text(server.tailLines.joined(separator: "\n"))
              .font(.caption2.monospaced())
              .foregroundStyle(KimiDesign.muted)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(8)
          }
          .frame(maxHeight: 140)
          .background(KimiDesign.surfaceSecondary)
          .clipShape(RoundedRectangle(cornerRadius: 6))
        }
      }
      .padding(.horizontal, 24)
      .padding(.bottom, 8)
      .alert("启动开发服务器?", isPresented: $showStartConfirm) {
        Button("启动") { startDevServer() }
        Button("取消", role: .cancel) {}
      } message: {
        if let devPlan {
          Text("将在当前会话工作目录运行 \(devPlan.displayCommand),检测到本地地址后自动打开预览。")
        }
      }
    }
  }

  private func startDevServer() {
    guard let sessionID = model.state.activeSessionID,
          let workingPath,
          let devPlan else { return }
    devServer.start(sessionID: sessionID, workingPath: workingPath, plan: devPlan)
  }

  // MARK: 验证截图产物

  @ViewBuilder
  private var artifactsContent: some View {
    if imageArtifacts.isEmpty && browserActivities.isEmpty {
      KimiPaneEmpty(icon: "safari", text: "尚未发起浏览器验证。让 Kimi 验证一个网页后，截图与控制台产物会出现在这里。")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(imageArtifacts, id: \.self) { url in
            if let image = NSImage(contentsOf: url) {
              Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 720)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(KimiDesign.border, lineWidth: 1))
              Text(url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(KimiDesign.muted)
            }
          }
          ForEach(browserActivities) { activity in
            KimiActivityCard(activity: activity)
          }
        }
        .padding(24)
      }
    }
  }
}

// MARK: - 后台任务

/// 后台任务面板(对标 Claude Code tasks pane):聚合当前会话的后台工作——
/// subagent 调用、运行中/已结束的工具调用、后台命令。数据源复用时间线活动卡
/// 的 KimiActivity(state.activities),不新建事件通道。
///
/// 不提供单任务停止:引擎的 abort 通道(/session/:id/abort)是会话级的,
/// 没有按 toolCallID 停止单个任务的端点;运行中条目只显示状态,停止整个
/// 会话仍走会话头部的「停止」按钮。
struct KimiTasksPane: View {
  @ObservedObject var model: KimiAppViewModel
  var slot: KimiPanelSlot = .primary

  /// 运行中的排前面(保持发生顺序),已结束的按完成时间倒序。
  private var tasks: [KimiActivity] {
    let open = model.state.activities.filter { $0.state == .running || $0.state == .queued || $0.state == .awaitingPermission }
    let settled = model.state.activities
      .filter { $0.state == .completed || $0.state == .failed || $0.state == .cancelled }
      .sorted { $0.updatedAt > $1.updatedAt }
    return open + settled
  }

  var body: some View {
    VStack(spacing: 0) {
      KimiPaneHeader(
        title: "后台任务",
        icon: "square.stack.3d.up",
        trailing: model.state.activities.isEmpty ? nil : "\(model.state.activities.count) 项",
        backTitle: slot.backTitle,
        back: { model.closePanel(in: slot) }
      )
      if tasks.isEmpty {
        KimiPaneEmpty(icon: "square.stack.3d.up", text: "当前会话还没有后台任务。子代理调用、工具执行和后台命令会聚合在这里。")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(tasks) { activity in
              KimiTaskRow(activity: activity)
            }
          }
          .padding(24)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .background(KimiDesign.background)
  }
}

/// 单条后台任务:图标 + 标题 + 状态 + 耗时;点击展开输出详情
/// (复用活动卡的 detail 数据源)。
private struct KimiTaskRow: View {
  let activity: KimiActivity
  @State private var isExpanded = false

  private var isRunning: Bool {
    activity.state == .running || activity.state == .queued || activity.state == .awaitingPermission
  }

  private var statusText: String {
    switch activity.state {
    case .running: return "运行中"
    case .queued: return "排队中"
    case .awaitingPermission: return "等待审批"
    case .completed: return "已完成"
    case .failed: return "失败"
    case .cancelled: return "已取消"
    }
  }

  private var statusColor: Color {
    switch activity.state {
    case .running, .queued, .awaitingPermission: return KimiDesign.primary
    case .completed: return .green
    case .failed: return .red
    case .cancelled: return .orange
    }
  }

  private var icon: String {
    if activity.title.hasPrefix("子代理") { return "person.2" }
    if activity.title == "思考过程" { return "brain" }
    if activity.title.lowercased().contains("bash") { return "terminal" }
    return "wrench.and.screwdriver"
  }

  private var hasDetail: Bool {
    activity.detail?.isEmpty == false
  }

  private static func durationText(from start: Date, to end: Date) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)秒" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)分\(seconds % 60)秒" }
    return "\(minutes / 60)小时\(minutes % 60)分"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        if hasDetail { isExpanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(statusColor)
            .frame(width: 16)
          Text(activity.title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(KimiDesign.text)
            .lineLimit(1)
          Text(statusText)
            .font(.caption2)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
          Spacer()
          // 运行中的耗时实时走动;已结束的定格在 updatedAt(最后一帧)。
          if isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
              Text(Self.durationText(from: activity.createdAt, to: context.date))
                .font(.caption.monospacedDigit())
                .foregroundStyle(KimiDesign.muted)
            }
          } else {
            Text(Self.durationText(from: activity.createdAt, to: activity.updatedAt))
              .font(.caption.monospacedDigit())
              .foregroundStyle(KimiDesign.muted)
          }
          if hasDetail {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2)
              .foregroundStyle(KimiDesign.muted)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded, let detail = activity.detail, !detail.isEmpty {
        Text(detail)
          .font(.caption)
          .foregroundStyle(KimiDesign.muted)
          .textSelection(.enabled)
          .lineLimit(40)
          .padding(.leading, 24)
      }
    }
    .padding(12)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
  }
}
