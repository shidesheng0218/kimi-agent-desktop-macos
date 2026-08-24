import Foundation

public enum HarnessChatRole: String, Codable, Equatable, Sendable {
  case system
  case user
  case assistant
  case tool
}

public struct HarnessToolCall: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let argumentsJSON: String

  public init(id: String, name: String, argumentsJSON: String) {
    self.id = id
    self.name = name
    self.argumentsJSON = argumentsJSON
  }
}

public struct HarnessChatMessage: Codable, Equatable, Sendable {
  public let role: HarnessChatRole
  public let content: String?
  public let toolCalls: [HarnessToolCall]
  public let toolCallID: String?

  public init(
    role: HarnessChatRole,
    content: String? = nil,
    toolCalls: [HarnessToolCall] = [],
    toolCallID: String? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  public static func user(_ text: String) -> HarnessChatMessage {
    HarnessChatMessage(role: .user, content: text)
  }

  public static func assistant(_ text: String, toolCalls: [HarnessToolCall] = []) -> HarnessChatMessage {
    HarnessChatMessage(role: .assistant, content: text, toolCalls: toolCalls)
  }

  public static func tool(_ result: HarnessToolResult) -> HarnessChatMessage {
    HarnessChatMessage(
      role: .tool,
      content: result.output,
      toolCallID: result.callID
    )
  }
}

public struct HarnessModelUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int
  public let cachedTokens: Int

  public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0, cachedTokens: Int = 0) {
    self.inputTokens = max(0, inputTokens)
    self.outputTokens = max(0, outputTokens)
    self.reasoningTokens = max(0, reasoningTokens)
    self.cachedTokens = max(0, cachedTokens)
  }
}

public enum HarnessConversationFinishReason: String, Codable, Equatable, Sendable {
  case stop
  case toolCalls
  case maxTokens
  case error
}

public struct HarnessToolResult: Codable, Equatable, Sendable {
  public let callID: String
  public let toolName: String
  public let output: String
  public let isError: Bool

  public init(callID: String, toolName: String, output: String, isError: Bool) {
    self.callID = callID
    self.toolName = toolName
    self.output = output
    self.isError = isError
  }
}
