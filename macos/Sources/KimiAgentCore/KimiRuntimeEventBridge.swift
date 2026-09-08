import Foundation

/// One assistant turn's terminal outcome, set explicitly by whichever engine
/// produced the event rather than inferred by callers matching on `kind`.
/// opencode's SSE decoder maps its own idle frames to `.completed` here; a
/// non-SSE engine (e.g. a direct API call with no event stream of its own)
/// synthesizes this value itself right after the call returns. This is the
/// single contract `KimiRuntimeOperationDriver.waitForCompletion` blocks on,
/// so any engine implementation only needs to guarantee this field, not
/// reproduce opencode's specific idle/status wire shapes.
public enum EngineTurnOutcome: String, Codable, Sendable {
  case completed
  case failed
  case aborted
}

public enum KimiRuntimeEventKind: String, Codable, Sendable {
  case sessionCreated
  case sessionUpdated
  case sessionStatus
  case sessionIdle
  case userText
  case assistantText
  case reasoningText
  case toolCall
  case toolResult
  case permissionAsked
  case permissionReplied
  case todoUpdated
  case questionAsked
  case questionReplied
  case fileChanged
  case patchCreated
  case terminalCreated
  case mcpUpdated
  case subagentStarted
  case subagentCompleted
  case compacted
  case error
  case unknown
}

public struct EngineRuntimeEvent: Codable, Equatable, Sendable {
  public let id: UUID
  public let sessionID: String
  public let kind: KimiRuntimeEventKind
  public let text: String?
  public let toolCallID: String?
  public let toolID: String?
  public let requestID: String?
  /// Engine message identifier from `message.part.*` events.
  public let messageID: String?
  /// Engine part identifier; one streaming text part maps to one UI bubble.
  public let partID: String?
  /// `true` when `text` is the part's full content so far (replace semantics),
  /// `false` for incremental deltas (append semantics).
  public let isSnapshot: Bool
  public let payload: [String: String]
  public let createdAt: Date
  /// Non-nil exactly on the one event per turn that declares the turn over.
  /// See `EngineTurnOutcome`.
  public let turnOutcome: EngineTurnOutcome?

  public init(
    id: UUID = UUID(),
    sessionID: String,
    kind: KimiRuntimeEventKind,
    text: String? = nil,
    toolCallID: String? = nil,
    toolID: String? = nil,
    requestID: String? = nil,
    messageID: String? = nil,
    partID: String? = nil,
    isSnapshot: Bool = false,
    payload: [String: String] = [:],
    createdAt: Date = .now,
    turnOutcome: EngineTurnOutcome? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.kind = kind
    self.text = text
    self.toolCallID = toolCallID
    self.toolID = toolID
    self.requestID = requestID
    self.messageID = messageID
    self.partID = partID
    self.isSnapshot = isSnapshot
    self.payload = payload
    self.createdAt = createdAt
    self.turnOutcome = turnOutcome
  }

  private enum CodingKeys: String, CodingKey {
    case id, sessionID, kind, text, toolCallID, toolID, requestID, messageID, partID, isSnapshot, payload, createdAt, turnOutcome
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      sessionID: try container.decode(String.self, forKey: .sessionID),
      kind: try container.decode(KimiRuntimeEventKind.self, forKey: .kind),
      text: try container.decodeIfPresent(String.self, forKey: .text),
      toolCallID: try container.decodeIfPresent(String.self, forKey: .toolCallID),
      toolID: try container.decodeIfPresent(String.self, forKey: .toolID),
      requestID: try container.decodeIfPresent(String.self, forKey: .requestID),
      messageID: try container.decodeIfPresent(String.self, forKey: .messageID),
      partID: try container.decodeIfPresent(String.self, forKey: .partID),
      isSnapshot: try container.decodeIfPresent(Bool.self, forKey: .isSnapshot) ?? false,
      payload: try container.decodeIfPresent([String: String].self, forKey: .payload) ?? [:],
      createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now,
      turnOutcome: try container.decodeIfPresent(EngineTurnOutcome.self, forKey: .turnOutcome)
    )
  }
}

/// Stateful wire decoder for one engine SSE subscription. `message.part.delta`
/// events carry no part type, so the decoder remembers the type announced by
/// `message.part.updated` and classifies later deltas (text vs reasoning)
/// through that registry.
public final class KimiRuntimeEventDecoder: @unchecked Sendable {
  private let lock = NSLock()
  private var partKinds: [String: String] = [:]
  /// messageID → role, announced by message.updated. Text parts of user
  /// messages must not surface as assistant bubbles (the composer already
  /// renders the user's own message locally).
  private var messageRoles: [String: String] = [:]
  /// Reasoning parts re-register on every snapshot, so a hard cap is enough;
  /// eviction only degrades classification back to plain text.
  private let partKindLimit = 8_192

  public init() {}

  public func decode(_ data: Data, sessionID: String) -> EngineRuntimeEvent? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let rawType = (object["type"] as? String) ?? (object["event"] as? String) ?? "unknown"
    let loweredType = rawType.lowercased()
    let properties = object["properties"] as? [String: Any] ?? object["data"] as? [String: Any] ?? object
    let nestedPart = properties["part"] as? [String: Any]
    let part = nestedPart ?? properties
    let partState = part["state"] as? [String: Any]
    let rawPartType = (part["type"] as? String)?.lowercased()
    var messageID = properties["messageID"] as? String ?? part["messageID"] as? String
    let partID = properties["partID"] as? String ?? part["id"] as? String

    // message.updated announces the durable message id and role; user events
    // carry no text part (they never produce a chat bubble), and the role
    // registry keeps later text parts of user messages out of the assistant
    // stream.
    var usagePayload: [String: String] = [:]
    if loweredType == "message.updated",
       let info = properties["info"] as? [String: Any] {
      let role = (info["role"] as? String)?.lowercased()
      if let id = info["id"] as? String, let role { registerRole(role, for: id) }
      if role == "user" {
        messageID = info["id"] as? String ?? messageID
        return EngineRuntimeEvent(
          sessionID: properties["sessionID"] as? String ?? sessionID,
          kind: .userText,
          messageID: messageID
        )
      }
      // Assistant message.updated carries the turn's token usage and cost in
      // info.tokens / info.cost; forward them through the payload so Harness
      // accounting can settle the turn without changing the event kind.
      if role == "assistant" {
        messageID = messageID ?? info["id"] as? String
        if let tokens = info["tokens"] as? [String: Any], let encoded = Self.stringify(tokens) {
          usagePayload["usageTokens"] = encoded
        }
        if let cost = Self.numberString(info["cost"]) {
          usagePayload["usageCost"] = cost
        }
      }
    }

    if loweredType == "message.part.delta" {
      let field = (properties["field"] as? String) ?? "text"
      guard field == "text", let delta = properties["delta"] as? String, !delta.isEmpty else { return nil }
      if let messageID, registeredRole(for: messageID) == "user" { return nil }
      let isReasoning = partID.map { registeredKind(for: $0) == "reasoning" } ?? false
      return EngineRuntimeEvent(
        sessionID: properties["sessionID"] as? String ?? sessionID,
        kind: isReasoning ? .reasoningText : .assistantText,
        text: delta,
        messageID: messageID,
        partID: partID
      )
    }

    if loweredType == "message.part.updated", let partID, let rawPartType {
      register(kind: rawPartType, for: partID)
    }
    if let messageID, registeredRole(for: messageID) == "user",
       rawPartType == "text" || rawPartType == "reasoning" {
      return nil
    }

    var kind = Self.mapKind(rawType)
    if loweredType.contains("text.delta") { kind = .assistantText }
    if loweredType.contains("reasoning.delta") { kind = .reasoningText }
    if loweredType.contains("tool.called") || loweredType.contains("tool.input") { kind = .toolCall }
    if loweredType.contains("tool.success") || loweredType.contains("tool.failed") || loweredType.contains("tool.result") { kind = .toolResult }
    var isSnapshot = false
    if rawPartType == "tool" {
      let status = (partState?["status"] as? String)?.lowercased()
      kind = (status == "completed" || status == "failed") ? .toolResult : .toolCall
    } else if rawPartType == "agent" || rawPartType == "subtask" || rawPartType == "task" {
      // Engine-native subagent invocation: render as a nested activity, with
      // completion driven by its part state like any other tool.
      let status = (partState?["status"] as? String)?.lowercased()
      kind = (status == "completed" || status == "failed") ? .subagentCompleted : .subagentStarted
    } else if loweredType == "message.part.updated", rawPartType == "text" {
      kind = .assistantText
      isSnapshot = true
    } else if loweredType == "message.part.updated", rawPartType == "reasoning" {
      kind = .reasoningText
      isSnapshot = true
    } else if rawPartType == "text" || rawPartType == "reasoning" {
      kind = rawPartType == "reasoning" ? .reasoningText : .assistantText
    }
    if loweredType == "session.status" {
      kind = .sessionStatus
    }
    if loweredType == "todo.updated" { kind = .todoUpdated }
    if loweredType == "question.asked" { kind = .questionAsked }
    if loweredType == "session.diff" { kind = .patchCreated }

    let text = (properties["delta"] as? String)
      ?? (part["text"] as? String)
      ?? (part["content"] as? String)
      ?? (part["message"] as? String)
      ?? Self.stringify(part["result"])
      ?? Self.stringify(partState?["output"])
      ?? Self.stringify(properties["error"])
    let toolCallID = properties["callID"] as? String
      ?? part["callID"] as? String
      ?? part["toolCallID"] as? String
    // permission.asked carries the permission name ("bash", "edit", …) in
    // `permission`; `tool` is a {messageID, callID} reference object there.
    let toolID = properties["tool"] as? String
      ?? part["tool"] as? String
      ?? part["toolID"] as? String
      ?? properties["permission"] as? String
    let eventSessionID = properties["sessionID"] as? String
      ?? part["sessionID"] as? String
      ?? sessionID
    let requestID = properties["id"] as? String
      ?? properties["requestID"] as? String
    var payload: [String: String] = [:]
    for (key, value) in properties {
      if let string = value as? String { payload[key] = string }
    }
    // Structured fields the UI and Harness accounting rely on; arrays and
    // objects would be lost by the string-only pass above.
    for key in ["patterns", "always", "todos", "questions", "diff", "input", "error", "result", "metadata"] {
      if payload[key] == nil, let encoded = Self.stringify(properties[key]) { payload[key] = encoded }
    }
    if let input = partState?["input"], let encoded = Self.stringify(input) { payload["arguments"] = encoded }
    if let input = properties["input"], let encoded = Self.stringify(input) { payload["arguments"] = encoded }
    if let status = partState?["status"] as? String { payload["status"] = status }
    if let statusType = (properties["status"] as? [String: Any])?["type"] as? String { payload["statusType"] = statusType }
    if let error = properties["error"] { payload["error"] = Self.stringify(error) ?? "error" }
    for (key, value) in usagePayload where payload[key] == nil { payload[key] = value }
    // opencode signals turn completion through two different wire shapes
    // (a dedicated session.idle event, or a session.status frame whose
    // statusType is "idle"); translate both into the one explicit contract
    // KimiRuntimeOperationDriver actually waits on.
    var turnOutcome: EngineTurnOutcome? = nil
    if kind == .sessionIdle || (kind == .sessionStatus && payload["statusType"] == "idle") {
      turnOutcome = .completed
    } else if kind == .error {
      turnOutcome = .failed
    }
    return EngineRuntimeEvent(
      sessionID: eventSessionID,
      kind: kind,
      text: text,
      toolCallID: toolCallID,
      toolID: toolID,
      requestID: requestID,
      messageID: messageID,
      partID: partID,
      isSnapshot: isSnapshot,
      payload: payload,
      turnOutcome: turnOutcome
    )
  }

  private func registeredKind(for partID: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return partKinds[partID]
  }

  private func registeredRole(for messageID: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return messageRoles[messageID]
  }

  private func register(kind: String, for partID: String) {
    lock.lock()
    defer { lock.unlock() }
    if partKinds.count >= partKindLimit { partKinds.removeAll(keepingCapacity: true) }
    partKinds[partID] = kind
  }

  private func registerRole(_ role: String, for messageID: String) {
    lock.lock()
    defer { lock.unlock() }
    if messageRoles.count >= partKindLimit { messageRoles.removeAll(keepingCapacity: true) }
    messageRoles[messageID] = role
  }

  static func stringify(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let value = value as? String { return value }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Renders a JSON number (Int or Double after JSONSerialization) as a plain
  /// decimal string; anything else is dropped rather than guessed.
  static func numberString(_ value: Any?) -> String? {
    switch value {
    case let number as NSNumber: return number.stringValue
    case let string as String: return string
    default: return nil
    }
  }

  static func mapKind(_ raw: String) -> KimiRuntimeEventKind {
    let value = raw.lowercased()
    if value.contains("session.idle") { return .sessionIdle }
    if value.contains("session.status") { return .sessionStatus }
    if value.contains("session.created") { return .sessionCreated }
    if value.contains("session.updated") { return .sessionUpdated }
    if value.contains("todo.updated") { return .todoUpdated }
    if value.contains("question.replied") || value.contains("question.rejected") { return .questionReplied }
    if value.contains("question.asked") { return .questionAsked }
    if value.contains("message.part") || value.contains("text") {
      return value.contains("user") ? .userText : .assistantText
    }
    if value.contains("tool") && value.contains("result") { return .toolResult }
    if value.contains("tool") || value.contains("call") { return .toolCall }
    if value.contains("permission") && (value.contains("replied") || value.contains("resolved")) { return .permissionReplied }
    if value.contains("permission") { return .permissionAsked }
    if value.contains("file") { return .fileChanged }
    if value.contains("patch") || value.contains("diff") { return .patchCreated }
    if value.contains("terminal") || value.contains("pty") { return .terminalCreated }
    if value.contains("mcp") { return .mcpUpdated }
    if value.contains("subagent") || value.contains("child") { return value.contains("complete") ? .subagentCompleted : .subagentStarted }
    if value.contains("compact") { return .compacted }
    if value.contains("error") { return .error }
    return .unknown
  }
}

public enum KimiRuntimeEventBridge {
  /// One-shot decode kept for tests and diagnostics. Production subscriptions
  /// use a per-stream `KimiRuntimeEventDecoder` so reasoning classification
  /// survives across delta frames.
  public static func decodeSSEData(_ data: Data, sessionID: String) -> EngineRuntimeEvent? {
    KimiRuntimeEventDecoder().decode(data, sessionID: sessionID)
  }

  public static func map(_ event: EngineRuntimeEvent) -> [KimiEvent] {
    switch event.kind {
    case .assistantText:
      return event.text.map { [.assistantText(text: $0, partID: event.partID, isSnapshot: event.isSnapshot)] } ?? []
    case .reasoningText:
      return event.text.map { [.reasoningText(text: $0, partID: event.partID, isSnapshot: event.isSnapshot)] } ?? []
    case .userText:
      return event.text.map { [.userText($0)] } ?? []
    case .sessionStatus:
      guard let statusType = event.payload["statusType"] else { return [] }
      return [.sessionBusy(sessionID: event.sessionID, isBusy: statusType != "idle")]
    case .sessionIdle:
      return [.sessionBusy(sessionID: event.sessionID, isBusy: false)]
    case .sessionCreated, .sessionUpdated:
      return []
    case .toolCall:
      return [
        .activity(KimiActivity(
          title: event.toolID ?? "工具活动",
          detail: event.text,
          state: .running,
          toolCallID: event.toolCallID
        ))
      ]
    case .toolResult:
      let failed = event.payload["status"]?.lowercased() == "failed" || event.payload["error"] != nil
      return [
        .activity(KimiActivity(
          title: event.toolID ?? "工具活动",
          detail: event.text,
          state: failed ? .failed : .completed,
          toolCallID: event.toolCallID
        ))
      ]
    case .permissionAsked:
      // edit/write 工具的 permission.asked metadata 携带 {filepath, diff}
      //（见 vendor engine tool/edit.ts、tool/write.ts 的 ctx.ask 调用点），
      // 透传给权限卡做批准前的改动预览。
      let metadata = Self.decodeJSONObject(event.payload["metadata"])
      return [
        .permission(KimiPermissionRequest(
          id: event.id,
          runtimeID: event.requestID,
          toolID: event.toolID ?? "unknown",
          reason: event.text ?? "需要确认工具操作。",
          patterns: Self.decodeStringArray(event.payload["patterns"]),
          sessionRuntimeID: event.sessionID,
          metadataFilePath: metadata?["filepath"] as? String,
          metadataDiff: metadata?["diff"] as? String
        ))
      ]
    case .todoUpdated:
      let todos = Self.decodeTodos(event.payload["todos"])
      return [.todoUpdated(sessionID: event.sessionID, todos: todos)]
    case .questionAsked:
      let questions = Self.decodeQuestions(event.payload["questions"])
      guard !questions.isEmpty else { return [] }
      return [.questionAsked(KimiQuestionRequest(
        id: event.id,
        runtimeID: event.requestID,
        sessionID: event.sessionID,
        questions: questions
      ))]
    case .permissionReplied:
      return event.requestID.map { [.permissionSettled(requestID: $0)] } ?? []
    case .questionReplied:
      return event.requestID.map { [.questionSettled(requestID: $0)] } ?? []
    case .subagentStarted, .subagentCompleted:
      let agentName = event.toolID ?? "子代理"
      let completed = event.kind == .subagentCompleted
      return [
        .activity(KimiActivity(
          title: "子代理 · \(agentName)",
          detail: event.text,
          state: completed ? .completed : .running,
          toolCallID: event.toolCallID ?? "subagent|\(event.partID ?? event.id.uuidString)"
        ))
      ]
    case .fileChanged, .patchCreated, .terminalCreated,
         .mcpUpdated, .compacted:
      return event.text.map { [.activity(KimiActivity(title: event.kind.rawValue, detail: $0, state: .completed))] } ?? []
    case .unknown:
      // Provider catalogs, heartbeats, server banners and other events without
      // a UI projection must never leak into the activity timeline.
      return []
    case .error:
      return [.error(event.text ?? "执行引擎出现错误。")]
    }
  }

  static func decodeStringArray(_ raw: String?) -> [String] {
    guard let raw,
          let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
    return array.compactMap { $0 as? String }
  }

  static func decodeJSONObject(_ raw: String?) -> [String: Any]? {
    guard let raw,
          let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func decodeTodos(_ raw: String?) -> [KimiTodoItem] {
    guard let raw,
          let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return array.enumerated().map { index, item in
      KimiTodoItem(
        id: item["id"] as? String ?? item["_id"] as? String ?? "todo-\(index)",
        content: item["content"] as? String ?? item["text"] as? String ?? "",
        status: (item["status"] as? String)?.lowercased() ?? "pending",
        priority: item["priority"] as? String
      )
    }.filter { !$0.content.isEmpty }
  }

  static func decodeQuestions(_ raw: String?) -> [KimiQuestionItem] {
    guard let raw,
          let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return array.enumerated().map { index, item in
      let rawOptions = item["options"] as? [[String: Any]] ?? []
      return KimiQuestionItem(
        id: item["id"] as? String ?? "question-\(index)",
        question: item["question"] as? String ?? "",
        header: item["header"] as? String,
        options: rawOptions.map { option in
          KimiQuestionOption(
            label: option["label"] as? String ?? "",
            description: option["description"] as? String
          )
        }.filter { !$0.label.isEmpty },
        multiple: item["multiple"] as? Bool ?? false,
        custom: item["custom"] as? Bool ?? true
      )
    }.filter { !$0.question.isEmpty }
  }
}
