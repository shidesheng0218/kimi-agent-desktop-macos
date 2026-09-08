import SwiftUI
import AppKit

/// 助手消息的分块 Markdown 渲染：正文段落保持 AttributedString 内联富文本，
/// fenced code block 渲染为独立卡片（语言标签、复制按钮、语法高亮、横向滚动）。
/// 传入 model 时启用文件路径识别：文本里真实存在的路径渲染为可点击链接
/// （点击在文件面板预览），文本块右键菜单提供该块内路径的统一操作。
struct KimiMarkdownView: View {
  let text: String
  /// nil 时（如用户消息气泡）保持纯文本渲染，不做路径识别。
  var model: KimiAppViewModel? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(KimiMarkdownBlock.parse(text)) { block in
        switch block.kind {
        case .text(let content):
          Group {
            if let attributed = Self.attributed(content, model: model) {
              Text(attributed)
            } else {
              Text(content)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contextMenu {
            if let model {
              let paths = KimiFilePathDetector.paths(in: content, projectPath: model.activeProjectPath)
              ForEach(paths.prefix(4), id: \.self) { path in
                Menu(path) {
                  KimiFilePathContextMenu(path: path, isDirectory: false, model: model)
                }
              }
              // http(s) 链接:点击仍默认走系统浏览器,右键可选择在应用内预览。
              let links = Self.httpLinks(in: content)
              ForEach(links.prefix(3), id: \.self) { url in
                Menu(url.host ?? url.absoluteString) {
                  Button("在浏览器面板中打开") { model.navigateToBrowser(url: url) }
                  Button("在默认浏览器打开") { NSWorkspace.shared.open(url) }
                }
              }
            }
          }
        case .code(let language, let code):
          KimiCodeBlockCard(language: language, code: code)
        }
      }
    }
    .environment(\.openURL, OpenURLAction { url in
      guard url.scheme == "kimi-file",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
            let model
      else { return .systemAction }
      model.navigateToFile(path)
      return .handled
    })
  }

  /// 内联 Markdown 解析 + 路径链接化。路径分段单独构造 AttributedString
  /// 并挂上 kimi-file:// 链接（点击经上面的 openURL 走 navigateToFile）；
  /// 反引号包裹的行内 code 路径去掉反引号、保持等宽字体。
  private static func attributed(_ content: String, model: KimiAppViewModel?) -> AttributedString? {
    guard let model else {
      return try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
    let paths = KimiFilePathDetector.paths(in: content, projectPath: model.activeProjectPath)
    guard !paths.isEmpty else {
      return try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
    // 按命中区间把文本切成 普通 / 路径 分段；区间用 NSString 坐标系对齐正则结果。
    let nsContent = content as NSString
    var segments: [(range: NSRange, path: String)] = []
    for path in paths {
      var searchStart = 0
      while searchStart < nsContent.length {
        let found = nsContent.range(of: path, options: [], range: NSRange(location: searchStart, length: nsContent.length - searchStart))
        guard found.location != NSNotFound else { break }
        if !segments.contains(where: { NSIntersectionRange($0.range, found).length > 0 }) {
          segments.append((found, path))
        }
        searchStart = found.location + found.length
      }
    }
    segments.sort { $0.range.location < $1.range.location }

    var result = AttributedString()
    var cursor = 0
    for segment in segments {
      // 行内 code 路径：吞掉两侧反引号（计入消费区间但不显示），路径本身按 code 样式渲染。
      var consumeRange = segment.range
      let hasBackticks = segment.range.location > 0
        && segment.range.upperBound < nsContent.length
        && nsContent.substring(with: NSRange(location: segment.range.location - 1, length: 1)) == "`"
        && nsContent.substring(with: NSRange(location: segment.range.upperBound, length: 1)) == "`"
      if hasBackticks {
        consumeRange = NSRange(location: segment.range.location - 1, length: segment.range.length + 2)
      }
      if consumeRange.location > cursor {
        appendMarkdown(nsContent.substring(with: NSRange(location: cursor, length: consumeRange.location - cursor)), to: &result)
      }
      var link = AttributedString(nsContent.substring(with: segment.range))
      link.foregroundColor = KimiDesign.primary
      link.underlineStyle = .single
      if hasBackticks { link.font = .body.monospaced() }
      link.link = linkURL(for: segment.path)
      result.append(link)
      cursor = consumeRange.upperBound
    }
    if cursor < nsContent.length {
      appendMarkdown(nsContent.substring(from: cursor), to: &result)
    }
    return result
  }

  private static func appendMarkdown(_ text: String, to result: inout AttributedString) {
    if let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
      result.append(parsed)
    } else {
      result.append(AttributedString(text))
    }
  }

  private static func linkURL(for path: String) -> URL? {
    var components = URLComponents()
    components.scheme = "kimi-file"
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "path", value: path)]
    return components.url
  }

  /// 文本块里的 http(s) 链接(去重、按出现顺序),供右键菜单提供打开方式选择。
  private static func httpLinks(in text: String) -> [URL] {
    let nsText = text as NSString
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var seen = Set<String>()
    var result: [URL] = []
    for match in detector?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? [] {
      guard let url = match.url, let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            seen.insert(url.absoluteString).inserted
      else { continue }
      result.append(url)
    }
    return result
  }
}

struct KimiMarkdownBlock: Identifiable, Equatable {
  enum Kind: Equatable {
    case text(String)
    case code(language: String, code: String)
  }

  let id: Int
  let kind: Kind

  static func parse(_ markdown: String) -> [KimiMarkdownBlock] {
    var blocks: [KimiMarkdownBlock] = []
    var textLines: [String] = []
    var codeLines: [String] = []
    var codeLanguage = ""
    var inCode = false

    func flushText() {
      let content = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !content.isEmpty { blocks.append(KimiMarkdownBlock(id: blocks.count, kind: .text(content))) }
      textLines.removeAll()
    }
    func flushCode() {
      blocks.append(KimiMarkdownBlock(id: blocks.count, kind: .code(language: codeLanguage, code: codeLines.joined(separator: "\n"))))
      codeLines.removeAll()
      codeLanguage = ""
    }

    for line in markdown.components(separatedBy: "\n") {
      let fence = line.trimmingCharacters(in: .whitespaces)
      if fence.hasPrefix("```") {
        if inCode {
          flushCode()
          inCode = false
        } else {
          flushText()
          inCode = true
          codeLanguage = String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        continue
      }
      if inCode { codeLines.append(line) } else { textLines.append(line) }
    }
    // 流式场景下尾部未闭合的 fence：余下内容按代码块渲染。
    if inCode { flushCode() } else { flushText() }
    return blocks
  }
}

struct KimiCodeBlockCard: View {
  let language: String
  let code: String
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(language.isEmpty ? "code" : language)
          .font(.caption2.monospaced())
          .foregroundStyle(KimiDesign.muted)
        Spacer()
        Button(action: copy) {
          Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(KimiDesign.muted)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      Divider().overlay(KimiDesign.border)
      ScrollView(.horizontal) {
        Text(KimiSyntaxHighlighter.highlight(code, language: language))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .padding(10)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(KimiDesign.codeBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(KimiDesign.border, lineWidth: 1)
    )
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
  }
}

/// 轻量自研语法高亮：关键词 / 字符串 / 注释 / 数字 / 类型 五类着色，
/// 覆盖 swift / python / javascript / typescript / bash / json / yaml。
enum KimiSyntaxHighlighter {
  private enum TokenKind {
    case plain, keyword, string, comment, number, type
  }

  private enum Language: String {
    case swift, python, javascript, typescript, bash, json, yaml, other
  }

  static func highlight(_ code: String, language: String) -> AttributedString {
    let language = normalize(language)
    let keywords = keywordSets[language] ?? []
    var result = AttributedString()
    var index = code.startIndex

    func emit(_ slice: Substring, _ kind: TokenKind) {
      var segment = AttributedString(String(slice))
      if let color = color(for: kind) { segment.foregroundColor = color }
      result.append(segment)
    }

    while index < code.endIndex {
      let rest = code[index...]
      // 注释
      if let end = commentEnd(in: rest, language: language) {
        emit(rest[..<end], .comment)
        index = end
        continue
      }
      let char = rest.first!
      // 字符串
      if char == "\"" || char == "'" || (char == "`" && (language == .javascript || language == .typescript)) {
        let delimiter: Character = char
        var triple = false
        if language == .python {
          let prefix3 = rest.prefix(3)
          triple = prefix3 == "\"\"\"" || prefix3 == "'''"
        }
        var cursor = rest.index(after: rest.startIndex)
        var end = rest.endIndex
        if triple {
          let closing = String(repeating: String(delimiter), count: 3)
          if let range = rest[cursor...].range(of: closing) {
            end = range.upperBound
          }
        } else {
          while cursor < rest.endIndex {
            let c = rest[cursor]
            if c == "\\" {
              cursor = rest.index(cursor, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
              continue
            }
            if c == delimiter {
              end = rest.index(after: cursor)
              break
            }
            if c == "\n" && delimiter != "`" {
              end = cursor
              break
            }
            cursor = rest.index(after: cursor)
          }
        }
        emit(rest[..<end], .string)
        index = end
        continue
      }
      // 数字
      if char.isNumber {
        var end = rest.index(after: rest.startIndex)
        while end < rest.endIndex, rest[end].isNumber || "abcdefABCDEFxXoObB._'".contains(rest[end]) {
          end = rest.index(after: end)
        }
        emit(rest[..<end], .number)
        index = end
        continue
      }
      // 标识符：关键词 / 类型 / 普通
      if char.isLetter || char == "_" || char == "$" {
        var end = rest.index(after: rest.startIndex)
        while end < rest.endIndex, rest[end].isLetter || rest[end].isNumber || rest[end] == "_" || rest[end] == "$" {
          end = rest.index(after: end)
        }
        let word = rest[..<end]
        if keywords.contains(String(word)) {
          emit(word, .keyword)
        } else if word.first?.isUppercase == true {
          emit(word, .type)
        } else {
          emit(word, .plain)
        }
        index = end
        continue
      }
      emit(rest.prefix(1), .plain)
      index = rest.index(after: rest.startIndex)
    }
    return result
  }

  private static func normalize(_ raw: String) -> Language {
    switch raw.lowercased() {
    case "swift": return .swift
    case "python", "py": return .python
    case "javascript", "js", "jsx", "node": return .javascript
    case "typescript", "ts", "tsx": return .typescript
    case "bash", "sh", "shell", "zsh": return .bash
    case "json": return .json
    case "yaml", "yml": return .yaml
    default: return .other
    }
  }

  private static func commentEnd(in rest: Substring, language: Language) -> Substring.Index? {
    switch language {
    case .swift, .javascript, .typescript:
      if rest.hasPrefix("//") { return lineEnd(of: rest) }
      if rest.hasPrefix("/*") {
        if let range = rest.range(of: "*/") { return range.upperBound }
        return rest.endIndex
      }
      return nil
    case .python, .bash, .yaml:
      return rest.hasPrefix("#") ? lineEnd(of: rest) : nil
    case .json, .other:
      return nil
    }
  }

  private static func lineEnd(of rest: Substring) -> Substring.Index {
    rest.firstIndex(of: "\n") ?? rest.endIndex
  }

  private static func color(for kind: TokenKind) -> Color? {
    switch kind {
    case .plain: return nil
    case .keyword: return KimiDesign.syntaxKeyword
    case .string: return KimiDesign.syntaxString
    case .comment: return KimiDesign.syntaxComment
    case .number: return KimiDesign.syntaxNumber
    case .type: return KimiDesign.syntaxType
    }
  }

  private static let keywordSets: [Language: Set<String>] = [
    .swift: ["func", "var", "let", "class", "struct", "enum", "protocol", "extension", "import", "return",
             "if", "else", "for", "while", "guard", "switch", "case", "default", "break", "continue", "do",
             "try", "catch", "throw", "throws", "async", "await", "some", "any", "in", "where", "as", "is",
             "self", "Self", "super", "nil", "true", "false", "static", "public", "private", "internal",
             "fileprivate", "open", "final", "lazy", "weak", "unowned", "mutating", "override", "init",
             "deinit", "subscript", "typealias", "defer", "repeat", "fallthrough", "inout", "actor"],
    .python: ["def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "try",
              "except", "finally", "with", "as", "lambda", "pass", "break", "continue", "raise", "yield",
              "global", "nonlocal", "assert", "del", "in", "is", "not", "and", "or", "None", "True",
              "False", "async", "await", "print"],
    .javascript: ["function", "var", "let", "const", "class", "extends", "import", "export", "from",
                  "return", "if", "else", "for", "while", "do", "try", "catch", "finally", "throw", "new",
                  "delete", "typeof", "instanceof", "in", "of", "switch", "case", "default", "break",
                  "continue", "this", "super", "null", "undefined", "true", "false", "async", "await",
                  "yield", "void", "static", "get", "set"],
    .typescript: ["function", "var", "let", "const", "class", "extends", "import", "export", "from",
                  "return", "if", "else", "for", "while", "do", "try", "catch", "finally", "throw", "new",
                  "delete", "typeof", "instanceof", "in", "of", "switch", "case", "default", "break",
                  "continue", "this", "super", "null", "undefined", "true", "false", "async", "await",
                  "yield", "void", "static", "get", "set", "interface", "type", "enum", "namespace",
                  "implements", "readonly", "public", "private", "protected", "abstract", "declare",
                  "keyof", "infer", "satisfies", "as", "any", "never", "unknown", "string", "number",
                  "boolean"],
    .bash: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function",
            "in", "echo", "cd", "export", "local", "return", "exit", "source", "alias", "unset", "set",
            "shift", "readonly", "declare", "eval", "exec", "printf", "read", "sudo"],
    .json: ["true", "false", "null"],
    .yaml: ["true", "false", "null", "yes", "no", "on", "off"],
  ]
}
