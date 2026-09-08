import XCTest
@testable import KimiAgentCore

/// 迁移自 KimiAgentCoreChecks：PR/CI 状态条 statusCheckRollup 汇总。
final class KimiPRChecksSummaryTests: XCTestCase {
  func testSummarizeMixedCheckRunAndStatusContextShapes() {
    // CheckRun 用 status/conclusion，StatusContext 用 state，两种形状必须都能正确归类。
    let summary = KimiPRChecksSummary.summarize(rollup: [
      ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"],
      ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE"],
      ["__typename": "CheckRun", "status": "IN_PROGRESS"],
      ["__typename": "StatusContext", "state": "SUCCESS"],
      ["__typename": "StatusContext", "state": "PENDING"],
      ["__typename": "StatusContext", "state": "ERROR"],
    ])
    XCTAssertEqual(summary.passed, 2)
    XCTAssertEqual(summary.failed, 2)
    XCTAssertEqual(summary.pending, 2)
  }

  func testSummarizeEmptyRollupIsAllZero() {
    XCTAssertEqual(KimiPRChecksSummary.summarize(rollup: []), KimiPRChecksSummary(), "空检查列表必须汇总为全零")
  }

  func testSummarizeInProgressCheckRunIsPending() {
    let summary = KimiPRChecksSummary.summarize(rollup: [
      ["__typename": "CheckRun", "status": "QUEUED"],
    ])
    XCTAssertEqual(summary, KimiPRChecksSummary(passed: 0, failed: 0, pending: 1), "未 COMPLETED 的 CheckRun 必须计为进行中")
  }

  func testSummarizeFailedConclusionsAreCounted() {
    let summary = KimiPRChecksSummary.summarize(rollup: [
      ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "CANCELLED"],
      ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "TIMED_OUT"],
      ["__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"],
    ])
    XCTAssertEqual(summary.failed, 2, "CANCELLED/TIMED_OUT 必须计为失败")
    XCTAssertEqual(summary.passed, 1)
  }

  func testSummarizeLowercaseValuesAreNormalized() {
    // GitHub API 返回大写，但汇总逻辑必须对大小写不敏感。
    let summary = KimiPRChecksSummary.summarize(rollup: [
      ["__typename": "StatusContext", "state": "success"],
      ["__typename": "StatusContext", "state": "pending"],
      ["__typename": "StatusContext", "state": "failure"],
    ])
    XCTAssertEqual(summary, KimiPRChecksSummary(passed: 1, failed: 1, pending: 1))
  }
}
