import Foundation

/// 开发服务器启动计划:从项目根 package.json 推断脚本与包管理器。
/// Package.swift(Swift 包)没有统一的 dev server 约定,不支持。
public struct KimiDevServerPlan: Equatable, Sendable {
  public let packageManager: String
  public let script: String

  public init(packageManager: String, script: String) {
    self.packageManager = packageManager
    self.script = script
  }

  public var command: KimiCommand {
    KimiCommand(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [packageManager, "run", script]
    )
  }

  public var displayCommand: String { "\(packageManager) run \(script)" }
}

/// 浏览器预览面板的纯逻辑支撑:dev server 检测、本地地址提取、
/// 可预览文件类型判定。UI 与进程管理在应用层(KimiBrowserPreview.swift)。
public enum KimiBrowserPreviewSupport {
  /// 读取项目根 package.json 的 scripts,优先 dev、其次 start;都没有返回 nil。
  /// 包管理器按 lockfile 推断:pnpm-lock.yaml > yarn.lock > 默认 npm。
  public static func devServerPlan(forProjectRoot root: URL) -> KimiDevServerPlan? {
    let manifestURL = root.appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: manifestURL),
          let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let scripts = manifest["scripts"] as? [String: Any]
    else { return nil }
    let script: String
    if scripts["dev"] is String {
      script = "dev"
    } else if scripts["start"] is String {
      script = "start"
    } else {
      return nil
    }
    let fileManager = FileManager.default
    let packageManager: String
    if fileManager.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) {
      packageManager = "pnpm"
    } else if fileManager.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) {
      packageManager = "yarn"
    } else {
      packageManager = "npm"
    }
    return KimiDevServerPlan(packageManager: packageManager, script: script)
  }

  private static let localURLRegex: NSRegularExpression = {
    // 只认环回地址:dev server 预览不主动导航到局域网/公网地址。
    let pattern = #"https?://(?:localhost|127\.0\.0\.1)(?::\d{1,5})?(?:/[^\s"'<>\)\]]*)?"#
    return try! NSRegularExpression(pattern: pattern)
  }()

  private static let localURLTrailingTrim = CharacterSet(charactersIn: ".,;:!?\"'")

  /// 从 dev server 输出中提取首个 http://localhost:PORT / http://127.0.0.1:PORT 地址。
  public static func extractLocalURL(from text: String) -> URL? {
    let nsText = text as NSString
    guard let match = localURLRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { return nil }
    var candidate = nsText.substring(with: match.range)
    while let last = candidate.unicodeScalars.last, localURLTrailingTrim.contains(last) {
      candidate = String(candidate.dropLast())
    }
    return URL(string: candidate)
  }

  /// 浏览器面板可直接预览的本地文件扩展名:HTML / PDF / 图片 / 视频。
  private static let previewableExtensions: Set<String> = [
    "html", "htm",
    "pdf",
    "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "ico",
    "mp4", "mov", "m4v", "webm",
  ]

  public static func isBrowserPreviewableFile(_ url: URL) -> Bool {
    previewableExtensions.contains(url.pathExtension.lowercased())
  }
}
