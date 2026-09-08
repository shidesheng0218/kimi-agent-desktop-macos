import XCTest
@testable import KimiAgentCore

/// 输入区附件：data URL 图片、file:// 文件引用、二进制 sniff、持久化剥离载荷。
final class KimiPromptAttachmentTests: XCTestCase {
  func testImageAttachmentBuildsDataURL() {
    let data = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
    let attachment = KimiPromptAttachment.image(data: data, filename: "shot.png", mime: "image/png")
    XCTAssertEqual(attachment.url, "data:image/png;base64,\(data.base64EncodedString())", "图片附件必须以 base64 data URL 发送")
    XCTAssertEqual(attachment.byteCount, data.count)
    XCTAssertTrue(attachment.isImage)
    XCTAssertTrue(attachment.isDataURL)
  }

  func testFileReferenceAttachmentBuildsFileURL() throws {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("kimi-attachment-\(UUID().uuidString).txt")
    try Data("hello".utf8).write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let attachment = KimiPromptAttachment.fileReference(absolutePath: fileURL.path)
    XCTAssertEqual(attachment.url, fileURL.absoluteString, "项目文件引用必须走 file:// 绝对路径")
    XCTAssertEqual(attachment.filename, fileURL.lastPathComponent)
    XCTAssertEqual(attachment.mime, "text/plain")
    XCTAssertEqual(attachment.byteCount, 5, "文件引用必须带出真实文件大小")
    XCTAssertFalse(attachment.isDataURL)
    XCTAssertFalse(attachment.isImage)
  }

  func testImageDataOnlyForDataURLAttachments() {
    let data = Data([0x01, 0x02, 0x03])
    let image = KimiPromptAttachment.image(data: data, filename: "a.png", mime: "image/png")
    XCTAssertEqual(image.imageData, data, "data URL 附件必须能还原原始字节用于缩略图")
    let file = KimiPromptAttachment(filename: "b.txt", mime: "text/plain", url: "file:///tmp/b.txt", byteCount: 3)
    XCTAssertNil(file.imageData, "文件引用不得尝试还原图片字节")
  }

  func testSniffImageMIMEDetectsCommonFormats() {
    XCTAssertEqual(KimiPromptAttachment.sniffImageMIME(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "image/png")
    XCTAssertEqual(KimiPromptAttachment.sniffImageMIME(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])), "image/jpeg")
    XCTAssertEqual(KimiPromptAttachment.sniffImageMIME(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), "image/gif")
    // RIFF....WEBP：魔数在第 8-11 字节。
    XCTAssertEqual(KimiPromptAttachment.sniffImageMIME(Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50])), "image/webp")
  }

  func testSniffImageMIMEReturnsNilForUnknownData() {
    XCTAssertNil(KimiPromptAttachment.sniffImageMIME(Data("plain text".utf8)), "无法识别的字节必须返回 nil 由上层回落默认 mime")
    XCTAssertNil(KimiPromptAttachment.sniffImageMIME(Data()), "空数据不得误判")
  }

  func testPersistenceStripsDataURLPayload() throws {
    // 持久化（ui-state.json）必须剥离 base64 载荷，避免拖慢每次状态落盘。
    let image = KimiPromptAttachment.image(data: Data(repeating: 0xAB, count: 1024), filename: "big.png", mime: "image/png")
    let encoded = try JSONEncoder().encode(image)
    XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains(image.url) == true, "持久化不得包含 data URL 载荷")
    let decoded = try JSONDecoder().decode(KimiPromptAttachment.self, from: encoded)
    XCTAssertEqual(decoded.id, image.id)
    XCTAssertEqual(decoded.filename, image.filename, "剥离载荷后文件名必须保留")
    XCTAssertEqual(decoded.mime, image.mime)
    XCTAssertEqual(decoded.byteCount, image.byteCount, "剥离载荷后文件大小必须保留")
    XCTAssertEqual(decoded.url, "", "data URL 附件持久化后 url 必须为空串")
    XCTAssertNil(decoded.imageData)
  }

  func testPersistenceKeepsFileReferenceURL() throws {
    let file = KimiPromptAttachment(filename: "b.txt", mime: "text/plain", url: "file:///tmp/b.txt", byteCount: 3)
    let decoded = try JSONDecoder().decode(KimiPromptAttachment.self, from: JSONEncoder().encode(file))
    XCTAssertEqual(decoded.url, "file:///tmp/b.txt", "文件引用的 file:// 路径必须原样持久化")
    XCTAssertEqual(decoded, file)
  }
}
