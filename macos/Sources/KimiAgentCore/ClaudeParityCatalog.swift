import Foundation

public enum ClaudeCapabilityKind: String, Codable, CaseIterable, Sendable {
  case desktopWorkbench
  case terminalSession
  case worktreeIsolation
  case diffReview
  case planMode
  case subagents
  case skills
  case hooks
  case mcp
  case customCommands
  case memory
  case settings
  case browserUse
  case computerUse
  case githubAutomation
  case gitlabIntegration
  case sessionResume
  case loginAndIdentity
  case diagnostics
}

public enum ClaudeCapabilityLoop: String, Codable, CaseIterable, Sendable {
  case localOpenRun
  case planExecuteReview
  case inspectAcceptReject
  case configureAuthorizeRun
  case reviewVerifyMerge
  case resumeRecover
}

public struct ClaudeCapabilityDescriptor: Equatable, Codable, Sendable, Identifiable {
  public let id: String
  public let kind: ClaudeCapabilityKind
  public let title: String
  public let summary: String
  public let loop: ClaudeCapabilityLoop
  public let isImplemented: Bool

  public init(
    kind: ClaudeCapabilityKind,
    title: String,
    summary: String,
    loop: ClaudeCapabilityLoop,
    isImplemented: Bool
  ) {
    self.id = kind.rawValue
    self.kind = kind
    self.title = title
    self.summary = summary
    self.loop = loop
    self.isImplemented = isImplemented
  }
}

public struct ClaudeParityCapabilityCatalog: Equatable, Codable, Sendable {
  public let capabilities: [ClaudeCapabilityDescriptor]

  public static let defaultCatalog = ClaudeParityCapabilityCatalog(capabilities: [
    .init(kind: .desktopWorkbench, title: "原生桌面工作台", summary: "macOS 原生三栏界面、统一时间线对话、Todo 清单与 Inspector。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .terminalSession, title: "终端会话", summary: "右侧本机交互终端（不经权限门），Agent Shell 由引擎权限管控。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .worktreeIsolation, title: "Worktree 隔离", summary: "git 仓库项目的新会话默认绑定 <项目>/.kimi/worktrees/<id> 独立工作区(设置可关),侧栏显示分支徽标,删除会话时可清理 worktree(有未提交改动先警告);非 git 项目/创建失败自动回退项目根。", loop: .planExecuteReview, isImplemented: true),
    .init(kind: .diffReview, title: "Diff 审阅", summary: "Diff 面板实时渲染工作区改动（文件/hunk 级）；合并保持人工。", loop: .inspectAcceptReject, isImplemented: true),
    .init(kind: .planMode, title: "Plan 模式", summary: "composer 权限模式菜单切换：prompt 级 agent=plan 走引擎内置 plan agent（禁编辑），自动接受编辑经会话级 permission ruleset 运行时下发。", loop: .planExecuteReview, isImplemented: true),
    .init(kind: .subagents, title: "Subagents", summary: "引擎原生 task 子代理，活动卡展示运行与结算状态。", loop: .planExecuteReview, isImplemented: true),
    .init(kind: .skills, title: "Skills", summary: "引擎发现项目与插件技能，集成面板展示。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .hooks, title: "Hooks", summary: "引擎配置层支持 hooks，尚未在 UI 暴露。", loop: .configureAuthorizeRun, isImplemented: false),
    .init(kind: .mcp, title: "MCP", summary: "引擎管理 MCP 服务器，集成面板展示连接状态。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .customCommands, title: "自定义命令", summary: "Slash 命令补全与执行（含项目级命令发现）。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .memory, title: "记忆 / 规则", summary: "项目级和用户级长期规则入口。", loop: .resumeRecover, isImplemented: false),
    .init(kind: .settings, title: "设置", summary: "本地配置、权限和模型偏好。", loop: .resumeRecover, isImplemented: true),
    .init(kind: .browserUse, title: "浏览器使用", summary: "WKWebView 验证、截图产物回流与展示。", loop: .inspectAcceptReject, isImplemented: true),
    .init(kind: .computerUse, title: "Computer Use", summary: "系统级点击、输入与屏幕操作（逐次审批）。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .githubAutomation, title: "GitHub 自动化", summary: "PR/CI 状态条已落地（gh CLI 轮询分支 PR 与 statusCheckRollup，未装 gh 静默降级）；auto-fix/auto-merge 与完整 PR 创建流未接，整体保持未实现。", loop: .reviewVerifyMerge, isImplemented: false),
    .init(kind: .gitlabIntegration, title: "GitLab 集成", summary: "凭据存储就绪，UI 入口未接。", loop: .reviewVerifyMerge, isImplemented: false),
    .init(kind: .sessionResume, title: "会话恢复", summary: "重启/切换后从引擎消息日志重建对话、Todo 与活动。", loop: .resumeRecover, isImplemented: true),
    .init(kind: .loginAndIdentity, title: "登录与身份", summary: "Kimi OAuth 与 Keychain 存储。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .diagnostics, title: "诊断", summary: "Runtime、Node、权限和 Computer Use 检查。", loop: .localOpenRun, isImplemented: true)
  ])
}
