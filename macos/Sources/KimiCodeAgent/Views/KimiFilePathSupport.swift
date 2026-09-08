import SwiftUI
import AppKit
import KimiAgentCore

/// 聊天消息 / diff 文本里文件路径的保守识别：绝对路径（/ 或 ~ 开头）或
/// 含 / 且带扩展名的相对路径。两个保险：词边界 lookbehind 避免吃进
/// URL/普通文本；命中后必须能在磁盘上解析到真实文件才当作路径。
enum KimiFilePathDetector {
  private static let regex: NSRegularExpression = {
    // 绝对路径允许无扩展名（如 /Applications）；相对路径必须带扩展名，
    // 否则 "and/or" 这类写法也会被误认为路径。
    let pattern = #"(?<![\w/\-.@+])(?:~?/(?:[\w.@-]+/)*[\w.@+-]+(?:\.[A-Za-z0-9]{1,12})?|(?:[\w.@-]+/)+[\w.@+-]+\.[A-Za-z0-9]{1,12})"#
    return try! NSRegularExpression(pattern: pattern)
  }()

  private static let trailingTrim = CharacterSet(charactersIn: ".,;:!?)』」>\"'")

  /// 按出现顺序去重返回文本中真实存在的文件路径。
  static func paths(in text: String, projectPath: String?) -> [String] {
    let nsText = text as NSString
    var seen = Set<String>()
    var result: [String] = []
    for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
      var candidate = nsText.substring(with: match.range)
      while let last = candidate.unicodeScalars.last, trailingTrim.contains(last) {
        candidate = String(candidate.dropLast())
      }
      guard !candidate.isEmpty, !seen.contains(candidate) else { continue }
      // 排除 URL（路径前面紧跟 :// 说明是网址的一部分）
      if match.range.location >= 3, nsText.substring(with: NSRange(location: match.range.location - 3, length: 3)) == "://" { continue }
      let url = KimiAppViewModel.resolveFileURL(candidate, projectPath: projectPath)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
      seen.insert(candidate)
      result.append(candidate)
    }
    return result
  }
}

/// 「在编辑器中打开」：检测已安装的 VS Code / Cursor / Zed，都没有时回退默认打开方式。
enum KimiFileEditorOpener {
  private static let knownEditors: [(name: String, bundleID: String)] = [
    ("VS Code", "com.microsoft.VSCode"),
    ("Cursor", "com.todesktop.230313mzl4w4u92"),
    ("Zed", "dev.zed.Zed"),
  ]

  static var installedEditors: [(name: String, appURL: URL)] {
    knownEditors.compactMap { entry in
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
      return (name: entry.name, appURL: url)
    }
  }

  static func open(_ fileURL: URL, withEditor appURL: URL) {
    NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
  }
}

/// 文件路径的统一右键菜单：文件面板打开 / 编辑器打开 / Finder 显示 /
/// 复制路径 / 附加为上下文。聊天文本块、diff 文件卡、文件树条目共用。
struct KimiFilePathContextMenu: View {
  let path: String
  let isDirectory: Bool
  @ObservedObject var model: KimiAppViewModel

  private var fileURL: URL {
    KimiAppViewModel.resolveFileURL(path, projectPath: model.activeProjectPath)
  }

  var body: some View {
    if !isDirectory {
      Button("在文件面板中打开") { model.navigateToFile(path) }
      if KimiBrowserPreviewSupport.isBrowserPreviewableFile(fileURL) {
        Button("在浏览器面板中打开") { model.navigateToBrowserFile(path) }
      }
    }
    let editors = KimiFileEditorOpener.installedEditors
    if editors.isEmpty {
      Button("打开") { NSWorkspace.shared.open(fileURL) }
    } else {
      ForEach(editors, id: \.name) { editor in
        Button("在 \(editor.name) 中打开") { KimiFileEditorOpener.open(fileURL, withEditor: editor.appURL) }
      }
    }
    Button("在 Finder 显示") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    Button("复制路径") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(fileURL.path, forType: .string)
    }
    if !isDirectory {
      Button("附加为上下文") { model.addComposerFileURLs([fileURL]) }
    }
  }
}
