import XCTest
@testable import KimiAgentCore

/// 旧持久化数据兼容解码：新增的可选字段缺失时不得让整个状态解码失败。
final class LegacyDecodingTests: XCTestCase {
  func testLegacyKimiMessageWithoutAttachmentsDecodes() throws {
    // 旧持久化状态没有 attachments/runtimePartID/runtimeMessageID 键。
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","role":"user","text":"你好","isStreaming":false,"createdAt":0}"#
    let message = try JSONDecoder().decode(KimiMessage.self, from: Data(json.utf8))
    XCTAssertEqual(message.id, id)
    XCTAssertEqual(message.role, .user)
    XCTAssertEqual(message.text, "你好")
    XCTAssertTrue(message.attachments.isEmpty, "缺失 attachments 键时必须回落为空数组")
    XCTAssertNil(message.runtimePartID)
    XCTAssertNil(message.runtimeMessageID)
  }

  func testKimiMessageRoundTripKeepsAttachments() throws {
    let attachment = KimiPromptAttachment(filename: "b.txt", mime: "text/plain", url: "file:///tmp/b.txt", byteCount: 3)
    let message = KimiMessage(role: .user, text: "带附件", runtimePartID: "part-1", runtimeMessageID: "msg_1", attachments: [attachment])
    let decoded = try JSONDecoder().decode(KimiMessage.self, from: JSONEncoder().encode(message))
    XCTAssertEqual(decoded, message, "完整消息必须可编解码往返")
  }

  func testLegacyKimiPermissionRequestDecodesWithMinimalFields() throws {
    // 旧持久化数据只有 id/toolID/reason，没有 runtimeID/patterns/sessionRuntimeID/metadata 等键。
    let id = UUID()
    let json = #"{"id":"\#(id.uuidString)","toolID":"bash","reason":"运行 npm test"}"#
    let request = try JSONDecoder().decode(KimiPermissionRequest.self, from: Data(json.utf8))
    XCTAssertEqual(request.id, id)
    XCTAssertEqual(request.toolID, "bash")
    XCTAssertEqual(request.reason, "运行 npm test")
    XCTAssertTrue(request.patterns.isEmpty, "缺失 patterns 键时必须回落为空数组")
    XCTAssertNil(request.runtimeID)
    XCTAssertNil(request.sessionRuntimeID)
    XCTAssertNil(request.metadataFilePath)
    XCTAssertNil(request.metadataDiff)
  }

  func testLegacyKimiPermissionRequestWithoutIDGeneratesOne() throws {
    let json = #"{"toolID":"edit","reason":"写入文件","patterns":["src/a.ts"]}"#
    let request = try JSONDecoder().decode(KimiPermissionRequest.self, from: Data(json.utf8))
    XCTAssertEqual(request.patterns, ["src/a.ts"], "已有 patterns 必须保留")
    XCTAssertNotNil(request.id)
  }

  func testLegacyKimiSessionSummaryWithoutWorktreeKeysDecodes() throws {
    // 旧数据没有 worktreePath/worktreeBranch 键；workingPath 必须回退 projectPath。
    let json = #"{"id":"\#(UUID().uuidString)","title":"旧会话","projectPath":"/tmp/demo","status":"idle","updatedAt":0,"isScratch":false}"#
    let session = try JSONDecoder().decode(KimiSessionSummary.self, from: Data(json.utf8))
    XCTAssertNil(session.worktreePath, "旧数据不得解出 worktree 字段")
    XCTAssertNil(session.worktreeBranch)
    XCTAssertEqual(session.workingPath, "/tmp/demo", "无 worktree 时 workingPath 必须回退项目根")
  }

  func testKimiSessionSummaryWorkingPathFollowsWorktree() {
    let session = KimiSessionSummary(projectPath: "/tmp/demo", worktreePath: "/tmp/demo/.kimi/worktrees/a1b2c3d4", worktreeBranch: "kimi/session-a1b2c3d4")
    XCTAssertEqual(session.workingPath, "/tmp/demo/.kimi/worktrees/a1b2c3d4", "绑定 worktree 后 workingPath 必须指向 worktree")
  }
}
