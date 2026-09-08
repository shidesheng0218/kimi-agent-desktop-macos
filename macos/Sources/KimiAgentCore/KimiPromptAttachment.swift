import Foundation

/// 输入区附件：粘贴/拖拽的图片，或 @提及、拖拽进来的项目文件。
/// 对应引擎 prompt_async 的 FilePartInput（{type:"file", mime, url, filename}）：
/// 图片走 base64 data URL，项目文件走 file:// 绝对路径（引擎端用 Read 工具语义读取）。
public struct KimiPromptAttachment: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public var filename: String
  public var mime: String
  /// 图片为 `data:<mime>;base64,...`；文件引用为 `file://<绝对路径>`。
  public var url: String
  public var byteCount: Int

  public init(id: UUID = UUID(), filename: String, mime: String, url: String, byteCount: Int) {
    self.id = id
    self.filename = filename
    self.mime = mime
    self.url = url
    self.byteCount = byteCount
  }

  public var isImage: Bool { mime.hasPrefix("image/") }
  public var isDataURL: Bool { url.hasPrefix("data:") }

  /// 单张图片的原始字节上限；超出在输入区提示，不静默丢弃。
  public static let maxImageBytes = 10 * 1024 * 1024

  /// 粘贴/拖拽的图片附件：内容随 prompt 以 data URL 发送。
  /// 引擎端会做尺寸/体积归一（上限 2000×2000、base64 5MB，超限自动缩放），
  /// 客户端只需在 10MB 的原始字节上限内即可。
  public static func image(data: Data, filename: String, mime: String) -> KimiPromptAttachment {
    KimiPromptAttachment(
      filename: filename,
      mime: mime,
      url: "data:\(mime);base64,\(data.base64EncodedString())",
      byteCount: data.count
    )
  }

  /// 项目文件引用附件（@提及、拖拽的文本类文件）：引擎端按 file:// 读取，
  /// 文本文件经 Read 工具注入为上下文，与 opencode 前端的 @ 行为一致。
  public static func fileReference(absolutePath: String) -> KimiPromptAttachment {
    let fileURL = URL(fileURLWithPath: absolutePath)
    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return KimiPromptAttachment(
      filename: fileURL.lastPathComponent,
      mime: "text/plain",
      url: fileURL.absoluteString,
      byteCount: size
    )
  }

  /// data URL 图片的原始字节，供时间线/输入条渲染缩略图；文件引用返回 nil。
  public var imageData: Data? {
    guard isDataURL, let marker = url.range(of: ";base64,") else { return nil }
    return Data(base64Encoded: String(url[marker.upperBound...]))
  }

  /// 二进制 sniff：粘贴板图片未必带可靠 mime，按魔数判定，默认 PNG。
  public static func sniffImageMIME(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
    if bytes.count >= 12, bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
    return nil
  }

  private enum CodingKeys: String, CodingKey {
    case id, filename, mime, url, byteCount
  }

  /// 持久化（ui-state.json）时剥离 data URL 载荷：几 MB 的 base64 进状态文件
  /// 会拖慢每次持久化。重启后芯片仍在（文件名/大小保留），缩略图待引擎
  /// 历史重建时恢复。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(filename, forKey: .filename)
    try container.encode(mime, forKey: .mime)
    try container.encode(isDataURL ? "" : url, forKey: .url)
    try container.encode(byteCount, forKey: .byteCount)
  }
}
