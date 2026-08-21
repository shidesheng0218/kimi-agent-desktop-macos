import Foundation

/// Commands emitted by the native SwiftUI shell. This deliberately uses a
/// distinct name from the legacy `KimiCommand` process-launch value type.
public enum KimiAppCommand: Sendable, Equatable {
  case createSession(directory: String?)
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
  case changeModel(String)
  case changeThinkingEffort(String)
  case restartRuntime

  public enum Kind: String, Codable, Sendable {
    case createSession
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
    case changeModel
    case changeThinkingEffort
    case restartRuntime
  }

  public var kind: Kind {
    switch self {
    case .createSession: .createSession
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
    case .changeModel: .changeModel
    case .changeThinkingEffort: .changeThinkingEffort
    case .restartRuntime: .restartRuntime
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

  public init(
    id: UUID = UUID(),
    runtimeID: String? = nil,
    title: String = "新会话",
    projectPath: String? = nil,
    status: SessionStatus = .idle,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.runtimeID = runtimeID
    self.title = title
    self.projectPath = projectPath
    self.status = status
    self.updatedAt = updatedAt
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
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    role: KimiMessageRole,
    text: String,
    isStreaming: Bool = false,
    runtimePartID: String? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.isStreaming = isStreaming
    self.runtimePartID = runtimePartID
    self.createdAt = createdAt
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

  public init(id: UUID = UUID(), runtimeID: String? = nil, toolID: String, reason: String, patterns: [String] = [], createdAt: Date = .now) {
    self.id = id
    self.runtimeID = runtimeID
    self.toolID = toolID
    self.reason = reason
    self.patterns = patterns
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, runtimeID, toolID, reason, patterns, createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      runtimeID: try container.decodeIfPresent(String.self, forKey: .runtimeID),
      toolID: try container.decode(String.self, forKey: .toolID),
      reason: try container.decode(String.self, forKey: .reason),
      patterns: try container.decodeIfPresent([String].self, forKey: .patterns) ?? [],
      createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
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
    lastUserMessageIDBySession: [String: String] = [:]
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
    }
  }
}
