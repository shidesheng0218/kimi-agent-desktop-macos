import XCTest
@testable import KimiAgentCore

/// 会话权限模式三档（manual / acceptEdits / plan）的引擎映射。
final class KimiSessionPermissionModeTests: XCTestCase {
  func testPromptAgentOnlyPlanModeOverridesEngineAgent() {
    XCTAssertNil(KimiSessionPermissionMode.manual.promptAgent, "manual 必须使用引擎默认 build agent")
    XCTAssertNil(KimiSessionPermissionMode.acceptEdits.promptAgent, "acceptEdits 必须使用引擎默认 build agent")
    XCTAssertEqual(KimiSessionPermissionMode.plan.promptAgent, "plan", "plan 模式必须通过 agent 字段切换引擎内置 plan agent")
  }

  func testSessionPermissionRulesMapModesToEditActions() {
    let manual = KimiSessionPermissionMode.manual.sessionPermissionRules
    XCTAssertEqual(manual, [KimiPermissionRule(permission: "edit", pattern: "*", action: "ask")], "manual 的编辑必须逐次询问")
    let acceptEdits = KimiSessionPermissionMode.acceptEdits.sessionPermissionRules
    XCTAssertEqual(acceptEdits, [KimiPermissionRule(permission: "edit", pattern: "*", action: "allow")], "acceptEdits 的编辑必须直接放行")
    let plan = KimiSessionPermissionMode.plan.sessionPermissionRules
    XCTAssertEqual(plan, [KimiPermissionRule(permission: "edit", pattern: "*", action: "deny")], "plan 的编辑必须显式 deny，避免沿用 acceptEdits 留下的 allow 覆盖 plan agent 禁令")
  }

  func testSessionPermissionRulesAlwaysTargetEditWildcard() {
    for mode in KimiSessionPermissionMode.allCases {
      let rules = mode.sessionPermissionRules
      XCTAssertEqual(rules.count, 1)
      XCTAssertEqual(rules.first?.permission, "edit")
      XCTAssertEqual(rules.first?.pattern, "*")
    }
  }

  func testPermissionRuleRoundTripCoding() throws {
    let rule = KimiPermissionRule(permission: "edit", pattern: "src/**", action: "allow")
    let decoded = try JSONDecoder().decode(KimiPermissionRule.self, from: JSONEncoder().encode(rule))
    XCTAssertEqual(decoded, rule, "权限规则必须可编解码往返，供 PATCH /session/:id 使用")
  }
}
