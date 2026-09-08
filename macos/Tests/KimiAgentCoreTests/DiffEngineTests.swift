import XCTest
@testable import KimiAgentCore

/// 迁移自 KimiAgentCoreChecks：权限卡 diff 预览（DiffEngine.parseUnifiedDiff）。
final class DiffEngineTests: XCTestCase {
  func testParseUnifiedDiffCountsAdditionsAndDeletions() throws {
    let diff = "Index: /tmp/proj/src/a.ts\n===================================================================\n--- /tmp/proj/src/a.ts\n+++ /tmp/proj/src/a.ts\n@@ -1,2 +1,2 @@\n const a = 1\n-const b = 2\n+const b = 3\n"
    let file = try XCTUnwrap(DiffEngine.parseUnifiedDiff(diff, fallbackPath: "/tmp/proj/src/a.ts"))
    XCTAssertEqual(file.additions, 1, "必须解析 unified diff 的新增统计")
    XCTAssertEqual(file.deletions, 1, "必须解析 unified diff 的删除统计")
  }

  func testParseUnifiedDiffPreservesOriginalPathWithoutGitHeader() throws {
    let diff = "--- /tmp/proj/src/a.ts\n+++ /tmp/proj/src/a.ts\n@@ -1,1 +1,1 @@\n-old\n+new\n"
    let file = try XCTUnwrap(DiffEngine.parseUnifiedDiff(diff, fallbackPath: "/tmp/proj/src/a.ts"))
    XCTAssertEqual(file.path, "/tmp/proj/src/a.ts", "必须保留原始文件路径（含无 diff --git 头的补丁）")
    XCTAssertEqual(file.status, .modified)
  }

  func testParseUnifiedDiffDetectsNewFileFromZeroOldStart() throws {
    let diff = "--- /tmp/proj/new.ts\n+++ /tmp/proj/new.ts\n@@ -0,0 +1,2 @@\n+line one\n+line two"
    let file = try XCTUnwrap(DiffEngine.parseUnifiedDiff(diff, fallbackPath: "/tmp/proj/new.ts"))
    XCTAssertEqual(file.status, .added, "新文件写入的 diff 预览必须识别为新增文件")
    XCTAssertEqual(file.additions, 2)
    XCTAssertEqual(file.deletions, 0)
  }

  func testParseUnifiedDiffAcceptsPatchWithGitHeader() throws {
    let diff = "diff --git a/src/b.ts b/src/b.ts\nindex 1111111..2222222 100644\n--- a/src/b.ts\n+++ b/src/b.ts\n@@ -1,1 +1,1 @@\n-old\n+new\n"
    let file = try XCTUnwrap(DiffEngine.parseUnifiedDiff(diff, fallbackPath: "src/b.ts"))
    XCTAssertEqual(file.path, "src/b.ts", "已带 diff --git 头的补丁不得再补合成头")
    XCTAssertEqual(file.additions, 1)
    XCTAssertEqual(file.deletions, 1)
  }

  func testParseUnifiedDiffEmptyInputYieldsZeroStats() throws {
    // 空补丁只含合成头，解析为零增删、无 hunk 的占位 FileDiff（权限卡据此显示空预览）。
    let file = try XCTUnwrap(DiffEngine.parseUnifiedDiff("", fallbackPath: "file"))
    XCTAssertEqual(file.path, "file")
    XCTAssertEqual(file.additions, 0)
    XCTAssertEqual(file.deletions, 0)
    XCTAssertTrue(file.hunks.isEmpty)
  }
}
