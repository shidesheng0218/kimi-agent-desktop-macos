import Foundation

public enum ToolRisk: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
  case destructive
}

public enum ToolExecutionMode: String, Codable, CaseIterable, Sendable {
  case parallel
  case sessionSerial
  case worktreeSerial
}

public struct ToolDefinition: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let description: String
  public let permissionScopes: [PermissionScope]
  public let risk: ToolRisk
  public let executionMode: ToolExecutionMode
  public let supportsBackground: Bool
  public let timeoutSeconds: Int
  public let inputSchemaJSON: String?

  private enum CodingKeys: String, CodingKey {
    case id, title, description, permissionScopes, risk, executionMode, supportsBackground, timeoutSeconds, inputSchemaJSON
  }

  public init(
    id: String,
    title: String,
    description: String,
    permissionScopes: [PermissionScope],
    risk: ToolRisk = .low,
    executionMode: ToolExecutionMode? = nil,
    supportsBackground: Bool = false,
    timeoutSeconds: Int = 120,
    inputSchemaJSON: String? = nil
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.permissionScopes = permissionScopes
    self.risk = risk
    self.executionMode = executionMode ?? (risk == .low ? .parallel : .sessionSerial)
    self.supportsBackground = supportsBackground
    self.timeoutSeconds = timeoutSeconds
    self.inputSchemaJSON = inputSchemaJSON
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let title = try container.decode(String.self, forKey: .title)
    let description = try container.decode(String.self, forKey: .description)
    let scopes = try container.decodeIfPresent([PermissionScope].self, forKey: .permissionScopes) ?? []
    let risk = try container.decodeIfPresent(ToolRisk.self, forKey: .risk) ?? .low
    let mode = try container.decodeIfPresent(ToolExecutionMode.self, forKey: .executionMode)
    let background = try container.decodeIfPresent(Bool.self, forKey: .supportsBackground) ?? false
    let timeout = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 120
    let schema = try container.decodeIfPresent(String.self, forKey: .inputSchemaJSON)
    self.init(id: id, title: title, description: description, permissionScopes: scopes, risk: risk, executionMode: mode, supportsBackground: background, timeoutSeconds: timeout, inputSchemaJSON: schema)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(description, forKey: .description)
    try container.encode(permissionScopes, forKey: .permissionScopes)
    try container.encode(risk, forKey: .risk)
    try container.encode(executionMode, forKey: .executionMode)
    try container.encode(supportsBackground, forKey: .supportsBackground)
    try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    try container.encodeIfPresent(inputSchemaJSON, forKey: .inputSchemaJSON)
  }
}

public enum ToolCatalog {
  public static let defaultDefinitions: [ToolDefinition] = [
    ToolDefinition(id: "read", title: "读取文件", description: "读取工作区内文件。", permissionScopes: [.readWorkspace], inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#),
    ToolDefinition(id: "search", title: "搜索代码", description: "搜索工作区文件和符号。", permissionScopes: [.readWorkspace], inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"},"path":{"type":"string"}},"required":["query"],"additionalProperties":false}"#),
    ToolDefinition(id: "write", title: "写入文件", description: "在 Worktree 中写入文件。", permissionScopes: [.writeWorkspace], risk: .medium, inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#),
    ToolDefinition(id: "shell", title: "运行命令", description: "执行受策略约束的 Shell 命令。", permissionScopes: [.executeCommand], risk: .high, inputSchemaJSON: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"}},"required":["command"],"additionalProperties":false}"#),
    ToolDefinition(id: "web.search", title: "Web Search", description: "搜索已授权网络来源。", permissionScopes: [.network], supportsBackground: true, inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#),
    ToolDefinition(id: "web.fetch", title: "Web Fetch", description: "抓取已授权网页正文。", permissionScopes: [.network], inputSchemaJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"],"additionalProperties":false}"#),
    ToolDefinition(id: "browser", title: "浏览器验证", description: "打开并验证本地网页，支持计划、定位、点击、输入和截图。", permissionScopes: [.browser], risk: .medium, executionMode: .sessionSerial, supportsBackground: true, inputSchemaJSON: #"{"type":"object","properties":{"plan":{"type":"string"},"action":{"type":"string","enum":["open","navigate","inspect","click","typeText","pressKey","scroll","screenshot","collectConsole","collectNetwork"]},"url":{"type":"string"},"selector":{"type":"string"},"text":{"type":"string"},"key":{"type":"string"}},"additionalProperties":true}"#),
    ToolDefinition(id: "computer_use.inspect", title: "Computer Use Inspect", description: "读取当前屏幕和窗口状态。", permissionScopes: [.systemComputerUse], risk: .medium),
    ToolDefinition(id: "computer_use.screenshot", title: "Computer Use Screenshot", description: "保存当前屏幕截图作为可审阅产物。", permissionScopes: [.systemComputerUse], risk: .medium),
    ToolDefinition(id: "computer_use.click", title: "Computer Use Click", description: "执行已审批的屏幕点击。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "computer_use.click_element", title: "Computer Use Click Element", description: "按识别元素执行点击。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "computer_use.type_text", title: "Computer Use Type", description: "向已授权目标输入文本。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "computer_use.press_key", title: "Computer Use Key", description: "向已授权目标发送按键。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "github.pull_request.create", title: "Create Pull Request", description: "创建 GitHub Pull Request。", permissionScopes: [.network], risk: .high),
    ToolDefinition(id: "task", title: "Subagent", description: "创建独立子 Agent 会话。", permissionScopes: [.readWorkspace], supportsBackground: true),
    ToolDefinition(id: "mcp", title: "MCP Tool", description: "调用已授权 MCP 工具。", permissionScopes: [.network], risk: .medium)
  ]
}

/// JSON-native tool input.  The legacy string dictionary remains available as
/// a projection on `ToolExecutionRequest`, but it must no longer be the
/// transport format because model tools legitimately carry nested objects and
/// arrays.
public enum HarnessJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([HarnessJSONValue])
  case object([String: HarnessJSONValue])

  private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
  }

  public init(from decoder: Decoder) throws {
    let single = try decoder.singleValueContainer()
    if single.decodeNil() { self = .null; return }
    if let value = try? single.decode(Bool.self) { self = .bool(value); return }
    if let value = try? single.decode(Double.self) { self = .number(value); return }
    if let value = try? single.decode(String.self) { self = .string(value); return }

    if var array = try? decoder.unkeyedContainer() {
      var values: [HarnessJSONValue] = []
      while !array.isAtEnd { values.append(try array.decode(HarnessJSONValue.self)) }
      self = .array(values)
      return
    }

    let object = try decoder.container(keyedBy: DynamicKey.self)
    var values: [String: HarnessJSONValue] = [:]
    for key in object.allKeys { values[key.stringValue] = try object.decode(HarnessJSONValue.self, forKey: key) }
    self = .object(values)
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    case let .bool(value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case let .number(value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case let .string(value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case let .array(values):
      var container = encoder.unkeyedContainer()
      for value in values { try container.encode(value) }
    case let .object(values):
      var container = encoder.container(keyedBy: DynamicKey.self)
      for (key, value) in values {
        guard let codingKey = DynamicKey(stringValue: key) else { continue }
        try container.encode(value, forKey: codingKey)
      }
    }
  }

  public var objectValue: [String: HarnessJSONValue]? {
    guard case let .object(value) = self else { return nil }
    return value
  }

  public var arrayValue: [HarnessJSONValue]? {
    guard case let .array(value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case let .string(value) = self else { return nil }
    return value
  }

  public var integerValue: Int? {
    guard case let .number(value) = self, value.rounded() == value else { return nil }
    return Int(exactly: value)
  }

  public func compatibilityString() -> String? {
    switch self {
    case let .string(value): return value
    case let .bool(value): return value ? "true" : "false"
    case let .number(value): return value.rounded() == value ? String(Int(value)) : String(value)
    case .null: return nil
    case .array, .object:
      guard let data = try? JSONEncoder().encode(self) else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }

  public static func stringObject(_ values: [String: String]) -> HarnessJSONValue {
    .object(values.mapValues(HarnessJSONValue.string))
  }

  public func compatibilityObject() -> [String: String] {
    guard case let .object(values) = self else { return [:] }
    return values.reduce(into: [:]) { result, pair in
      if let value = pair.value.compatibilityString() { result[pair.key] = value }
    }
  }

  /// Applies a legacy hook's top-level string edits without flattening or
  /// discarding nested JSON values owned by the provider.
  public func overlaying(stringValues: [String: String]) -> HarnessJSONValue {
    guard case var .object(values) = self else {
      return .stringObject(stringValues)
    }
    for (key, value) in stringValues {
      values[key] = .string(value)
    }
    return .object(values)
  }
}

public struct ToolExecutionRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID
  public let sessionID: UUID
  public let operationID: UUID?
  public let agentID: String
  public let toolID: String
  public let inputJSON: HarnessJSONValue
  /// Compatibility projection for existing executors. New runtimes must read
  /// `inputJSON` so nested parameters are not lost.
  public var input: [String: String] { inputJSON.compatibilityObject() }
  public let resource: String?
  public let command: String?

  private enum CodingKeys: String, CodingKey {
    case id, taskID, sessionID, operationID, agentID, toolID, input, inputJSON, resource, command
  }

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    sessionID: UUID,
    operationID: UUID? = nil,
    agentID: String,
    toolID: String,
    input: [String: String] = [:],
    inputJSON: HarnessJSONValue? = nil,
    resource: String? = nil,
    command: String? = nil
  ) {
    self.id = id
    self.taskID = taskID
    self.sessionID = sessionID
    self.operationID = operationID
    self.agentID = agentID
    self.toolID = toolID
    self.inputJSON = inputJSON ?? HarnessJSONValue.stringObject(input)
    self.resource = resource
    self.command = command
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    taskID = try container.decode(UUID.self, forKey: .taskID)
    sessionID = try container.decode(UUID.self, forKey: .sessionID)
    operationID = try container.decodeIfPresent(UUID.self, forKey: .operationID)
    agentID = try container.decode(String.self, forKey: .agentID)
    toolID = try container.decode(String.self, forKey: .toolID)
    let legacyInput = try container.decodeIfPresent([String: String].self, forKey: .input) ?? [:]
    inputJSON = try container.decodeIfPresent(HarnessJSONValue.self, forKey: .inputJSON) ?? HarnessJSONValue.stringObject(legacyInput)
    resource = try container.decodeIfPresent(String.self, forKey: .resource)
    command = try container.decodeIfPresent(String.self, forKey: .command)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(taskID, forKey: .taskID)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encodeIfPresent(operationID, forKey: .operationID)
    try container.encode(agentID, forKey: .agentID)
    try container.encode(toolID, forKey: .toolID)
    // Keep the projection while old durable records and compatibility workers
    // are still readable; authoritative new input is `inputJSON`.
    try container.encode(input, forKey: .input)
    try container.encode(inputJSON, forKey: .inputJSON)
    try container.encodeIfPresent(resource, forKey: .resource)
    try container.encodeIfPresent(command, forKey: .command)
  }
}

public struct ToolExecutionResult: Codable, Equatable, Sendable {
  public let output: String
  public let metadata: [String: String]
  public let exitCode: Int32?

  public init(output: String, metadata: [String: String] = [:], exitCode: Int32? = nil) {
    self.output = output
    self.metadata = metadata
    self.exitCode = exitCode
  }
}

public protocol ToolExecutor: Sendable {
  func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult
}
