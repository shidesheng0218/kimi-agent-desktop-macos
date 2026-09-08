import Foundation

/// gh `statusCheckRollup` 汇总模型：PR/CI 状态条的通过/失败/进行中计数。
/// 纯解析逻辑放在 Core 层，便于 KimiAgentCoreChecks 直接覆盖。
public struct KimiPRChecksSummary: Equatable, Sendable {
  public var passed: Int
  public var failed: Int
  public var pending: Int

  public init(passed: Int = 0, failed: Int = 0, pending: Int = 0) {
    self.passed = passed
    self.failed = failed
    self.pending = pending
  }

  /// statusCheckRollup 条目有两种形状：CheckRun（status/conclusion）与
  /// StatusContext（state）。pending 优先于失败、失败优先于通过。
  public static func summarize(rollup: [[String: Any]]) -> KimiPRChecksSummary {
    var summary = KimiPRChecksSummary()
    for check in rollup {
      let status = (check["status"] as? String)?.uppercased()
      let conclusion = (check["conclusion"] as? String)?.uppercased()
      let state = (check["state"] as? String)?.uppercased()
      if let status, status != "COMPLETED" {
        summary.pending += 1
      } else if state == "PENDING" || state == "EXPECTED" {
        summary.pending += 1
      } else if let conclusion, ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) {
        summary.failed += 1
      } else if state == "FAILURE" || state == "ERROR" {
        summary.failed += 1
      } else {
        summary.passed += 1
      }
    }
    return summary
  }
}
