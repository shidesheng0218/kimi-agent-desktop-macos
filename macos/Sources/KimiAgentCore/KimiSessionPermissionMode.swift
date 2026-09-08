import Foundation

/// 引擎权限规则(PermissionV1.Rule):PATCH /session/:id 的 permission 字段。
/// 引擎求值时对合并后的 ruleset 取最后命中(Permission.evaluate 的 findLast),
/// 会话级规则因此覆盖 OPENCODE_CONFIG_CONTENT 里的配置级规则,运行时即可切换。
public struct KimiPermissionRule: Codable, Equatable, Sendable {
  public let permission: String
  public let pattern: String
  public let action: String

  public init(permission: String, pattern: String, action: String) {
    self.permission = permission
    self.pattern = pattern
    self.action = action
  }
}

/// 会话权限模式,对应 Claude Code 的 normal / acceptEdits / plan 三档。
/// manual 与 acceptEdits 通过会话级 permission ruleset 的运行时 PATCH 生效;
/// plan 通过 prompt_async body 的 agent 字段切换到引擎内置 plan agent
/// (编辑工具全部 deny,只允许写计划文件)。
public enum KimiSessionPermissionMode: String, Codable, CaseIterable, Sendable {
  case manual
  case acceptEdits
  case plan

  public var title: String {
    switch self {
    case .manual: return "手动确认"
    case .acceptEdits: return "自动接受编辑"
    case .plan: return "计划模式"
    }
  }

  public var summary: String {
    switch self {
    case .manual: return "高风险操作逐次弹卡确认"
    case .acceptEdits: return "文件编辑不再询问，直接执行"
    case .plan: return "只分析与规划，不修改文件"
    }
  }

  /// composer 右侧的权限提示文案。
  public var composerHint: String {
    switch self {
    case .manual: return "高风险操作需逐次确认"
    case .acceptEdits: return "编辑文件不再逐次确认"
    case .plan: return "计划模式：只出方案，不改文件"
    }
  }

  public var icon: String {
    switch self {
    case .manual: return "hand.raised"
    case .acceptEdits: return "checkmark.shield"
    case .plan: return "list.clipboard"
    }
  }

  /// 发送 prompt 时携带的引擎 agent;nil 表示引擎默认(build)。
  public var promptAgent: String? {
    self == .plan ? "plan" : nil
  }

  /// 写入会话的运行时权限规则。plan 模式下 edit 显式 deny:
  /// 会话级规则命中优先级高于 agent 级,若沿用 acceptEdits 留下的 allow
  /// 会把 plan agent 的编辑禁令覆盖掉。
  public var sessionPermissionRules: [KimiPermissionRule] {
    let action: String
    switch self {
    case .manual: action = "ask"
    case .acceptEdits: action = "allow"
    case .plan: action = "deny"
    }
    return [KimiPermissionRule(permission: "edit", pattern: "*", action: action)]
  }
}
