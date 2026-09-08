import Foundation

/// Commands emitted by the native SwiftUI shell. This deliberately uses a
/// distinct name from the legacy `KimiCommand` process-launch value type.
public enum KimiAppCommand: Sendable, Equatable {
  case createSession(directory: String?)
  /// Creates a session bound to the app's private scratch directory instead
  /// of a user-chosen project — no folder picker, no entry in recent
  /// projects. Always has a real directory (never omitted from the engine
  /// request), just one the user didn't pick: see KimiAppKernel.scratchDirectory.
  case createScratchSession
  /// Forks the given session into a new branch. `messageID` is the engine
  /// message ID to branch from; nil forks the entire history up to now.
  case forkSession(UUID, messageID: String?)
  case selectSession(UUID)
  case showHome
  case prompt(PromptInput)
  case steer(PromptInput)
  case followUp(PromptInput)
  case abort(OperationID)
  case approve(UUID)
  case approveAlways(UUID)
  case deny(UUID)
  case answerQuestion(UUID, [[String]])
  case rejectQuestion(UUID)
  case revertLastTurn
  case unrevert
  case runSlashCommand(name: String, arguments: String)
  case compact
  case retry(OperationID)
  case resume(OperationID)
  case openTerminal(UUID)
  case openDiff(UUID)
  case openBrowser(UUID)
  case openFile(String)
  /// 打开纯本地投影的辅助面板（验证/集成/后台任务）。必须经 kernel 置位
  /// activePane:ViewModel 本地置位会被下一次事件快照刷新冲掉。
  case openAuxPane(KimiActivePane)
  case changeModel(String)
  case changeThinkingEffort(String)
  case restartRuntime
  /// 删除会话(引擎 DELETE /session/:id + 本地移除)。worktree 的清理
  /// 由 ViewModel 在用户确认后单独执行(见 KimiAppViewModel.confirmDeleteSession)。
  case deleteSession(UUID)
  /// 打开当前会话的侧聊:fork 出一条临时会话,携带主会话完整上下文。
  case openSideChat
  /// 关闭侧聊并删除引擎侧临时会话。
  case closeSideChat
  /// 侧聊发消息(纯文本)。不经过 Harness 主通道,直接驱动侧聊 fork 会话。
  case sideChatPrompt(String)
  case sideChatAbort

  public enum Kind: String, Codable, Sendable {
    case createSession
    case createScratchSession
    case forkSession
    case selectSession
    case showHome
    case prompt
    case steer
    case followUp
    case abort
    case approve
    case approveAlways
    case deny
    case answerQuestion
    case rejectQuestion
    case revertLastTurn
    case unrevert
    case runSlashCommand
    case compact
    case retry
    case resume
    case openTerminal
    case openDiff
    case openBrowser
    case openFile
    case openAuxPane
    case changeModel
    case changeThinkingEffort
    case restartRuntime
    case deleteSession
    case openSideChat
    case closeSideChat
    case sideChatPrompt
    case sideChatAbort
  }

  public var kind: Kind {
    switch self {
    case .createSession: .createSession
    case .createScratchSession: .createScratchSession
    case .forkSession: .forkSession
    case .selectSession: .selectSession
    case .showHome: .showHome
    case .prompt: .prompt
    case .steer: .steer
    case .followUp: .followUp
    case .abort: .abort
    case .approve: .approve
    case .approveAlways: .approveAlways
    case .deny: .deny
    case .answerQuestion: .answerQuestion
    case .rejectQuestion: .rejectQuestion
    case .revertLastTurn: .revertLastTurn
    case .unrevert: .unrevert
    case .runSlashCommand: .runSlashCommand
    case .compact: .compact
    case .retry: .retry
    case .resume: .resume
    case .openTerminal: .openTerminal
    case .openDiff: .openDiff
    case .openBrowser: .openBrowser
    case .openFile: .openFile
    case .openAuxPane: .openAuxPane
    case .changeModel: .changeModel
    case .changeThinkingEffort: .changeThinkingEffort
    case .restartRuntime: .restartRuntime
    case .deleteSession: .deleteSession
    case .openSideChat: .openSideChat
    case .closeSideChat: .closeSideChat
    case .sideChatPrompt: .sideChatPrompt
    case .sideChatAbort: .sideChatAbort
    }
  }
}

public enum KimiActivePane: String, Codable, Sendable {
  case conversation
  case diff
  case browser
  case files
  case verification
  case integrations
  case tasks
}

public enum KimiTerminalPlacement: String, Codable, Sendable {
  case right
}

public enum KimiRuntimeState: String, Codable, Sendable {
  case stopped
  case starting
  case ready
  case degraded
  case stopping
  case failed
}

public struct KimiSessionSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  /// The engine uses string IDs such as `ses_...`; the UUID remains the local
  /// stable identity used by SwiftUI's ForEach and Harness records.
  public let runtimeID: String?
  public var title: String
  public var projectPath: String?
  public var status: SessionStatus
  public var updatedAt: Date
  /// The engine-side `ses_...` ID of the session this one was forked from, or
  /// nil for a root session. Mirrors the engine's `parentID` field (see
  /// `KimiRuntimeSession.parentID`) so the sidebar can render a branch tree
  /// without a second round trip.
  public var parentRuntimeID: String?
  /// True for sessions created via `.createScratchSession` — bound to the
  /// app's private scratch directory instead of a user-chosen project. Never
  /// set on a project session and never toggled after creation: a scratch
  /// session cannot become a project session or vice versa, so its directory
  /// binding is always what the user (or lack thereof) expects.
  public var isScratch: Bool = false
  /// 会话绑定的 git worktree 目录（开启「新会话使用独立工作区」且项目是可
  /// 用 git 仓库时，位于 <repo>/.kimi/worktrees/<id>）；nil 表示会话直接
  /// 运行在 projectPath。projectPath 始终保持项目根，用于侧栏分组与最近项目。
  public var worktreePath: String? = nil
  /// worktree 分支名（kimi/session-<id>），侧栏徽标展示。
  public var worktreeBranch: String? = nil
  /// 会话实际工作目录：引擎调用、diff、文件面板、终端统一走这里。
  public var workingPath: String? { worktreePath ?? projectPath }

  public init(
    id: UUID = UUID(),
    runtimeID: String? = nil,
    title: String = "新会话",
    projectPath: String? = nil,
    status: SessionStatus = .idle,
    updatedAt: Date = .now,
    parentRuntimeID: String? = nil,
    isScratch: Bool = false,
    worktreePath: String? = nil,
    worktreeBranch: String? = nil
  ) {
    self.id = id
    self.runtimeID = runtimeID
    self.title = title
    self.projectPath = projectPath
    self.status = status
    self.updatedAt = updatedAt
    self.parentRuntimeID = parentRuntimeID
    self.isScratch = isScratch
    self.worktreePath = worktreePath
    self.worktreeBranch = worktreeBranch
  }
}

public enum KimiMessageRole: String, Codable, Sendable {
  case user
  case assistant
  case system
  case tool
}

public struct KimiMessage: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let role: KimiMessageRole
  public var text: String
  public var isStreaming: Bool
  /// Engine-side part identifier (`partID` from `message.part.*` events). A
  /// streaming text part maps to exactly one bubble, so deltas append to and
  /// snapshots replace the same row instead of shattering into fragments.
  public let runtimePartID: String?
  /// Engine-side message identifier (the `id` field on GET
  /// /session/:id/message rows, i.e. `msg_...`). Live-appended messages
  /// (the ones constructed as the user types or the assistant streams) don't
  /// have this yet — it's only known once the engine has durably recorded
  /// the message and `loadHistory` rebuilds the timeline from
  /// `fetchMessages`. Needed to fork a session from a specific message via
  /// POST /session/:id/fork, which takes an engine messageID.
  public let runtimeMessageID: String?
  /// 用户消息携带的附件（图片缩略图 / 文件 chip），用于时间线展示；
  /// 助手消息恒为空。
  public var attachments: [KimiPromptAttachment]
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    role: KimiMessageRole,
    text: String,
    isStreaming: Bool = false,
    runtimePartID: String? = nil,
    runtimeMessageID: String? = nil,
    attachments: [KimiPromptAttachment] = [],
    createdAt: Date = .now
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.isStreaming = isStreaming
    self.runtimePartID = runtimePartID
    self.runtimeMessageID = runtimeMessageID
    self.attachments = attachments
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, role, text, isStreaming, runtimePartID, runtimeMessageID, attachments, createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      role: try container.decode(KimiMessageRole.self, forKey: .role),
      text: try container.decode(String.self, forKey: .text),
      isStreaming: try container.decode(Bool.self, forKey: .isStreaming),
      runtimePartID: try container.decodeIfPresent(String.self, forKey: .runtimePartID),
      runtimeMessageID: try container.decodeIfPresent(String.self, forKey: .runtimeMessageID),
      // 旧持久化状态没有 attachments 键；decodeIfPresent 缺失时回落为空，
      // 避免整个消息数组因单条解码失败被丢弃。
      attachments: try container.decodeIfPresent([KimiPromptAttachment].self, forKey: .attachments) ?? [],
      createdAt: try container.decode(Date.self, forKey: .createdAt)
    )
  }
}

public enum KimiActivityState: String, Codable, Sendable {
  case queued
  case running
  case awaitingPermission
  case completed
  case failed
  case cancelled
}

public struct KimiActivity: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public var detail: String?
  public var state: KimiActivityState
  public var toolCallID: String?
  public var effectID: UUID?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    detail: String? = nil,
    state: KimiActivityState = .queued,
    toolCallID: String? = nil,
    effectID: UUID? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.state = state
    self.toolCallID = toolCallID
    self.effectID = effectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct KimiPermissionRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  /// Opaque engine permission request identifier. The Swift UUID is used
  /// for stable SwiftUI identity only; this value is what must be sent back to
  /// the headless server when the user approves or rejects the request.
  public let runtimeID: String?
  public let toolID: String
  public let reason: String
  public let patterns: [String]
  public let createdAt: Date
  /// 该权限请求所属的引擎会话 ID，用于系统通知定位会话；旧持久化数据没有此字段。
  public let sessionRuntimeID: String?
  /// edit/write 类权限请求 metadata 里的目标文件路径（引擎下发，绝对路径）。
  public let metadataFilePath: String?
  /// edit/write 类权限请求 metadata 里的待写入 unified diff，用于权限卡内嵌预览。
  public let metadataDiff: String?

  public init(id: UUID = UUID(), runtimeID: String? = nil, toolID: String, reason: String, patterns: [String] = [], createdAt: Date = .now, sessionRuntimeID: String? = nil, metadataFilePath: String? = nil, metadataDiff: String? = nil) {
    self.id = id
    self.runtimeID = runtimeID
    self.toolID = toolID
    self.reason = reason
    self.patterns = patterns
    self.createdAt = createdAt
    self.sessionRuntimeID = sessionRuntimeID
    self.metadataFilePath = metadataFilePath
    self.metadataDiff = metadataDiff
  }

  private enum CodingKeys: String, CodingKey {
    case id, runtimeID, toolID, reason, patterns, createdAt, sessionRuntimeID, metadataFilePath, metadataDiff
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      runtimeID: try container.decodeIfPresent(String.self, forKey: .runtimeID),
      toolID: try container.decode(String.self, forKey: .toolID),
      reason: try container.decode(String.self, forKey: .reason),
      patterns: try container.decodeIfPresent([String].self, forKey: .patterns) ?? [],
      createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now,
      sessionRuntimeID: try container.decodeIfPresent(String.self, forKey: .sessionRuntimeID),
      metadataFilePath: try container.decodeIfPresent(String.self, forKey: .metadataFilePath),
      metadataDiff: try container.decodeIfPresent(String.self, forKey: .metadataDiff)
    )
  }
}

/// One entry of the engine's todo list (todo.updated event / todo endpoint),
/// rendered as the session's working checklist.
public struct KimiTodoItem: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public var content: String
  /// Engine status string: pending / in_progress / completed / cancelled.
  public var status: String
  public var priority: String?

  public init(id: String, content: String, status: String, priority: String? = nil) {
    self.id = id
    self.content = content
    self.status = status
    self.priority = priority
  }

  public var isCompleted: Bool { status == "completed" || status == "cancelled" }
}

public struct KimiQuestionOption: Codable, Equatable, Sendable, Identifiable {
  public var id: String { label }
  public let label: String
  public let description: String?

  public init(label: String, description: String? = nil) {
    self.label = label
    self.description = description
  }
}

public struct KimiQuestionItem: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let question: String
  public let header: String?
  public let options: [KimiQuestionOption]
  public let multiple: Bool
  public let custom: Bool

  public init(id: String = UUID().uuidString, question: String, header: String? = nil, options: [KimiQuestionOption] = [], multiple: Bool = false, custom: Bool = true) {
    self.id = id
    self.question = question
    self.header = header
    self.options = options
    self.multiple = multiple
    self.custom = custom
  }
}

/// A structured engine question (question tool), the counterpart of an
/// approval card: the model asks, the user answers or dismisses.
public struct KimiQuestionRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  /// Engine-side question request identifier used in the reply.
  public let runtimeID: String?
  public let sessionID: String
  public let questions: [KimiQuestionItem]
  public let createdAt: Date

  public init(id: UUID = UUID(), runtimeID: String? = nil, sessionID: String, questions: [KimiQuestionItem], createdAt: Date = .now) {
    self.id = id
    self.runtimeID = runtimeID
    self.sessionID = sessionID
    self.questions = questions
    self.createdAt = createdAt
  }
}

/// A slash command advertised by the engine (`GET /command`), including
/// project-level commands discovered from the workspace.
public struct KimiSlashCommand: Codable, Equatable, Sendable, Identifiable {
  public var id: String { name }
  public let name: String
  public let description: String?
  public let hint: String?

  public init(name: String, description: String? = nil, hint: String? = nil) {
    self.name = name
    self.description = description
    self.hint = hint
  }
}

/// One settled (or still open) side effect, projected from the Harness
/// intent/receipt journal for the verification panel.
public struct KimiVerificationRecord: Equatable, Sendable, Identifiable {
  public var id: UUID { effectID }
  public let effectID: UUID
  public let subject: String
  public let kind: String
  public let risk: String
  /// settled outcome: success / failure / cancelled; nil while still open.
  public let outcome: String?
  public let errorMessage: String?
  public let retryable: Bool
  public let createdAt: Date

  public init(effectID: UUID, subject: String, kind: String, risk: String, outcome: String?, errorMessage: String?, retryable: Bool, createdAt: Date = .now) {
    self.effectID = effectID
    self.subject = subject
    self.kind = kind
    self.risk = risk
    self.outcome = outcome
    self.errorMessage = errorMessage
    self.retryable = retryable
    self.createdAt = createdAt
  }
}

public struct KimiMcpServerStatus: Equatable, Sendable, Identifiable {
  public var id: String { name }
  public let name: String
  public let status: String
  public let detail: String?

  public init(name: String, status: String, detail: String? = nil) {
    self.name = name
    self.status = status
    self.detail = detail
  }
}

public struct KimiSkillSummary: Equatable, Sendable, Identifiable {
  public var id: String { name }
  public let name: String
  public let description: String?

  public init(name: String, description: String? = nil) {
    self.name = name
    self.description = description
  }
}

/// Everything the integrations panel shows: MCP server health and discovered
/// skills, fetched live from the engine.
public struct KimiIntegrationStatus: Equatable, Sendable {
  public var mcpServers: [KimiMcpServerStatus]
  public var skills: [KimiSkillSummary]

  public init(mcpServers: [KimiMcpServerStatus] = [], skills: [KimiSkillSummary] = []) {
    self.mcpServers = mcpServers
    self.skills = skills
  }
}

/// 侧聊(⌘;)的迷你对话线程:主会话的一条临时 fork,能读到主会话上下文
/// 但不写入主会话历史;关闭面板时删除引擎侧临时会话。只发文本,不支持附件。
/// 不持久化(见 KimiUIState 的 CodingKeys):应用重启后由
/// KimiAppKernel.cleanupOrphanSideChats 清理引擎侧遗留会话。
public struct KimiSideChatState: Codable, Equatable, Sendable {
  /// 侧聊 fork 会话的引擎 ID(ses_...)。
  public var sessionRuntimeID: String
  /// 主会话的引擎 ID,侧聊由此 fork。
  public var parentRuntimeID: String
  /// 侧聊会话的工作目录(与主会话一致,可能是 worktree)。
  public var directory: String?
  public var messages: [KimiMessage]
  public var busy: Bool
  public var error: String?

  public init(
    sessionRuntimeID: String,
    parentRuntimeID: String,
    directory: String? = nil,
    messages: [KimiMessage] = [],
    busy: Bool = false,
    error: String? = nil
  ) {
    self.sessionRuntimeID = sessionRuntimeID
    self.parentRuntimeID = parentRuntimeID
    self.directory = directory
    self.messages = messages
    self.busy = busy
    self.error = error
  }
}

public struct KimiUIState: Codable, Equatable, Sendable {
  public var activePane: KimiActivePane
  public let terminalPlacement: KimiTerminalPlacement
  public var runtimeState: KimiRuntimeState
  public var activeSessionID: UUID?
  public var sessions: [KimiSessionSummary]
  public var messages: [KimiMessage]
  public var activities: [KimiActivity]
  public var pendingPermissions: [KimiPermissionRequest]
  public var lastError: String?
  public var selectedModel: String
  public var thinkingEffort: String
  public var modelCatalog: [String]
  /// Runtime session IDs (`ses_...`) currently executing a turn, driven by
  /// `session.status` / `session.idle` engine events. The composer uses this
  /// to offer stop/steer affordances while a session is busy.
  public var busySessionIDs: [String]
  /// Recently used project directories, most recent first (cap 10). New
  /// sessions are created in the most recent project unless the user picks
  /// another one explicitly.
  public var recentProjects: [String]
  /// Working checklist for the active session (engine todo list).
  public var todos: [KimiTodoItem]
  /// Runtime session the current `todos` projection belongs to.
  public var todosSessionID: String?
  /// Structured questions asked by the engine's question tool.
  public var pendingQuestions: [KimiQuestionRequest]
  /// Slash commands advertised by the engine for the active directory.
  public var availableCommands: [KimiSlashCommand]
  /// Sessions whose file changes are currently reverted engine-side.
  public var revertedSessionIDs: [String]
  /// Engine message ID of the last user message per runtime session; revert
  /// targets it to roll back the latest turn's file changes.
  public var lastUserMessageIDBySession: [String: String]
  /// 当前打开的侧聊线程(⌘;)。不持久化:随应用退出失效,引擎侧遗留会话
  /// 由下次启动时的 cleanupOrphanSideChats 依 sideChatRuntimeIDs 清理。
  public var sideChat: KimiSideChatState?
  /// 全部侧聊临时会话的引擎 ID(含已关闭未清理成功的)。持久化,用于
  /// 启动时从引擎会话列表里过滤/删除,避免侧聊出现在侧栏。
  public var sideChatRuntimeIDs: [String]

  public init(
    activePane: KimiActivePane = .conversation,
    terminalPlacement: KimiTerminalPlacement = .right,
    runtimeState: KimiRuntimeState = .stopped,
    activeSessionID: UUID? = nil,
    sessions: [KimiSessionSummary] = [],
    messages: [KimiMessage] = [],
    activities: [KimiActivity] = [],
    pendingPermissions: [KimiPermissionRequest] = [],
    lastError: String? = nil,
    selectedModel: String = KimiRuntimeIdentityStore.defaultModelID,
    thinkingEffort: String = "Medium",
    modelCatalog: [String]? = nil,
    busySessionIDs: [String] = [],
    recentProjects: [String] = [],
    todos: [KimiTodoItem] = [],
    todosSessionID: String? = nil,
    pendingQuestions: [KimiQuestionRequest] = [],
    availableCommands: [KimiSlashCommand] = [],
    revertedSessionIDs: [String] = [],
    lastUserMessageIDBySession: [String: String] = [:],
    sideChat: KimiSideChatState? = nil,
    sideChatRuntimeIDs: [String] = []
  ) {
    self.activePane = activePane
    self.terminalPlacement = terminalPlacement
    self.runtimeState = runtimeState
    self.activeSessionID = activeSessionID
    self.sessions = sessions
    self.messages = messages
    self.activities = activities
    self.pendingPermissions = pendingPermissions
    self.lastError = lastError
    self.selectedModel = selectedModel
    self.thinkingEffort = thinkingEffort
    self.modelCatalog = modelCatalog ?? [selectedModel]
    self.busySessionIDs = busySessionIDs
    self.recentProjects = recentProjects
    self.todos = todos
    self.todosSessionID = todosSessionID
    self.pendingQuestions = pendingQuestions
    self.availableCommands = availableCommands
    self.revertedSessionIDs = revertedSessionIDs
    self.lastUserMessageIDBySession = lastUserMessageIDBySession
    self.sideChat = sideChat
    self.sideChatRuntimeIDs = sideChatRuntimeIDs
  }

  private enum CodingKeys: String, CodingKey {
    case activePane
    case terminalPlacement
    case runtimeState
    case activeSessionID
    case sessions
    case messages
    case activities
    case pendingPermissions
    case lastError
    case selectedModel
    case thinkingEffort
    case modelCatalog
    case busySessionIDs
    case recentProjects
    case todos
    case todosSessionID
    case pendingQuestions
    case availableCommands
    case revertedSessionIDs
    case lastUserMessageIDBySession
    // sideChat 刻意不在 CodingKeys 里:侧聊线程是会话级的临时状态,
    // 既不编码也不解码,重启后恒为 nil。
    case sideChatRuntimeIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activePane = try container.decodeIfPresent(KimiActivePane.self, forKey: .activePane) ?? .conversation
    terminalPlacement = try container.decodeIfPresent(KimiTerminalPlacement.self, forKey: .terminalPlacement) ?? .right
    runtimeState = try container.decodeIfPresent(KimiRuntimeState.self, forKey: .runtimeState) ?? .stopped
    activeSessionID = try container.decodeIfPresent(UUID.self, forKey: .activeSessionID)
    sessions = try container.decodeIfPresent([KimiSessionSummary].self, forKey: .sessions) ?? []
    messages = try container.decodeIfPresent([KimiMessage].self, forKey: .messages) ?? []
    activities = try container.decodeIfPresent([KimiActivity].self, forKey: .activities) ?? []
    pendingPermissions = try container.decodeIfPresent([KimiPermissionRequest].self, forKey: .pendingPermissions) ?? []
    lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    let decodedModel = try container.decodeIfPresent(String.self, forKey: .selectedModel) ?? KimiRuntimeIdentityStore.defaultModelID
    selectedModel = decodedModel
    thinkingEffort = try container.decodeIfPresent(String.self, forKey: .thinkingEffort) ?? "Medium"
    modelCatalog = try container.decodeIfPresent([String].self, forKey: .modelCatalog) ?? [decodedModel]
    // Busy markers describe in-flight engine turns; they never survive a
    // restart because the engine itself went away, so decode but drop stale
    // entries rather than showing a phantom running state.
    busySessionIDs = []
    recentProjects = try container.decodeIfPresent([String].self, forKey: .recentProjects) ?? []
    todos = try container.decodeIfPresent([KimiTodoItem].self, forKey: .todos) ?? []
    todosSessionID = try container.decodeIfPresent(String.self, forKey: .todosSessionID)
    // Engine question requests share the approval-card lifecycle: they only
    // exist inside the engine process, so persisted ones can never be
    // answered after a restart and are dropped on decode.
    pendingQuestions = []
    availableCommands = try container.decodeIfPresent([KimiSlashCommand].self, forKey: .availableCommands) ?? []
    revertedSessionIDs = try container.decodeIfPresent([String].self, forKey: .revertedSessionIDs) ?? []
    lastUserMessageIDBySession = try container.decodeIfPresent([String: String].self, forKey: .lastUserMessageIDBySession) ?? [:]
    sideChat = nil
    sideChatRuntimeIDs = try container.decodeIfPresent([String].self, forKey: .sideChatRuntimeIDs) ?? []
  }
}

public enum KimiEvent: Sendable, Equatable {
  case runtimeChanged(KimiRuntimeState)
  case sessionChanged(KimiSessionSummary)
  case modelChanged(String)
  case userText(String)
  /// Assistant text for one streaming part. `isSnapshot` means `text` is the
  /// part's full content so far (replace semantics); otherwise it is an
  /// incremental delta (append semantics).
  case assistantText(text: String, partID: String?, isSnapshot: Bool)
  /// Model reasoning content, kept out of the chat bubbles and rendered as a
  /// collapsible activity instead.
  case reasoningText(text: String, partID: String?, isSnapshot: Bool)
  /// Engine session.status / session.idle projection: a session started or
  /// stopped executing a turn.
  case sessionBusy(sessionID: String, isBusy: Bool)
  /// The engine's todo list changed for a session.
  case todoUpdated(sessionID: String, todos: [KimiTodoItem])
  /// The engine's question tool asks the user a structured question.
  case questionAsked(KimiQuestionRequest)
  /// Engine confirmed a permission reply; drops the matching pending card.
  /// Duplicate `permission.asked` emissions for one request would otherwise
  /// leave an unanswerable zombie card behind.
  case permissionSettled(requestID: String)
  /// Engine confirmed a question reply/rejection.
  case questionSettled(requestID: String)
  case activity(KimiActivity)
  case permission(KimiPermissionRequest)
  case error(String)
  /// 侧聊线程状态变化(打开/关闭/新消息/忙碌翻转),仅作刷新信号,
  /// apply 不改动主会话时间线。
  case sideChatUpdated
  /// 非活跃会话的原始引擎事件直通(双会话分屏的次会话列据此维护自己的
  /// 时间线)。只发布、不进 apply:主时间线只承载活跃会话。
  case sessionEvent(EngineRuntimeEvent)

  public var displayText: String {
    switch self {
    case let .runtimeChanged(state): return state.rawValue
    case let .sessionChanged(session): return session.title
    case let .modelChanged(model): return model
    case let .userText(text), let .error(text): return text
    case let .assistantText(text, _, _): return text
    case let .reasoningText(text, _, _): return text
    case let .sessionBusy(sessionID, isBusy): return "\(sessionID):\(isBusy ? "busy" : "idle")"
    case let .todoUpdated(sessionID, todos): return "\(sessionID):\(todos.count) 项待办"
    case let .questionAsked(request): return request.questions.first?.question ?? "引擎提问"
    case let .permissionSettled(requestID): return "审批已结算：\(requestID)"
    case let .questionSettled(requestID): return "问题已结算：\(requestID)"
    case let .activity(activity): return activity.title
    case let .permission(permission): return permission.reason
    case .sideChatUpdated: return "侧聊更新"
    case let .sessionEvent(event): return "\(event.sessionID):\(event.kind.rawValue)"
    }
  }

  /// 该事件是否写入主会话时间线(state.messages/activities/todos)。
  /// 非活跃会话的这类事件被 ingest 过滤,改走 .sessionEvent 直通。
  var targetsActiveTimeline: Bool {
    switch self {
    case .userText, .assistantText, .reasoningText, .activity, .todoUpdated:
      return true
    default:
      return false
    }
  }
}
