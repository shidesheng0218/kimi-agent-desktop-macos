import XCTest
@testable import KimiAgentCore

/// 迁移自 KimiAgentCoreChecks：会话级 worktree 的目录/分支命名惯例。
final class GitWorktreeManagerTests: XCTestCase {
  func testSessionWorktreeLocationFollowsKimiWorktreesLayout() {
    let sessionID = UUID()
    let location = GitWorktreeManager.sessionWorktreeLocation(
      repositoryRoot: URL(fileURLWithPath: "/tmp/demo-repo", isDirectory: true),
      sessionID: sessionID
    )
    let expectedShortID = String(sessionID.uuidString.prefix(8)).lowercased()
    XCTAssertEqual(location.directory.path, "/tmp/demo-repo/.kimi/worktrees/\(expectedShortID)", "会话 worktree 必须位于 <repo>/.kimi/worktrees/<session-id 前 8 位>")
    XCTAssertEqual(location.branch, "kimi/session-\(expectedShortID)", "会话 worktree 分支必须为 kimi/session-<id>")
  }

  func testSessionWorktreeLocationShortIDIsLowercased() {
    // UUID 字符串含大写字母，目录与分支名必须统一小写。
    let location = GitWorktreeManager.sessionWorktreeLocation(
      repositoryRoot: URL(fileURLWithPath: "/tmp/repo", isDirectory: true),
      sessionID: UUID()
    )
    XCTAssertEqual(location.directory.lastPathComponent, location.directory.lastPathComponent.lowercased())
    XCTAssertEqual(location.branch, location.branch.lowercased())
  }

  func testSessionWorktreeLocationIsDeterministicPerSession() {
    let sessionID = UUID()
    let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
    let first = GitWorktreeManager.sessionWorktreeLocation(repositoryRoot: root, sessionID: sessionID)
    let second = GitWorktreeManager.sessionWorktreeLocation(repositoryRoot: root, sessionID: sessionID)
    XCTAssertEqual(first.directory, second.directory, "同一会话必须映射到同一 worktree 目录")
    XCTAssertEqual(first.branch, second.branch)
  }
}
