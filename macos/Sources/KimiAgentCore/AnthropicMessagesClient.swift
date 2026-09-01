import Foundation

/// One content block streamed from a single Anthropic Messages API turn.
/// `AnthropicDirectEngineProvider` maps these onto `EngineRuntimeEvent`s;
/// this type carries only what the wire protocol actually distinguishes.
public enum AnthropicStreamChunk: Sendable {
  case textDelta(String)
  case toolUseStart(id: String, name: String)
  case toolUseInputDelta(id: String, partialJSON: String)
  case messageStop
}

public enum AnthropicClientError: LocalizedError, Sendable {
  case missingAPIKey
  case httpError(status: Int, body: String)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey: return "未配置 Anthropic API 密钥。"
    case let .httpError(status, body): return "Anthropic API 返回 HTTP \(status)：\(body)"
    case .invalidResponse: return "Anthropic API 返回了无法解析的响应。"
    }
  }
}

/// One turn's tool-call round trip: what the model asked to run, and the
/// text result to hand back in the next request's `tool_result` block.
public struct AnthropicToolUse: Sendable, Equatable {
  public let id: String
  public let name: String
  public let inputJSON: String

  public init(id: String, name: String, inputJSON: String) {
    self.id = id
    self.name = name
    self.inputJSON = inputJSON
  }
}

/// A minimal, streaming-capable Anthropic Messages API client. This is a raw
/// HTTP wire client only — it knows nothing about `EngineRuntimeEvent` or
/// engine-agnostic Harness types. `AnthropicDirectEngineProvider` is the
/// adapter layer that speaks `EngineProvider` on one side and this client on
/// the other.
public final class AnthropicMessagesClient: @unchecked Sendable {
  public struct Message: Sendable {
    public let role: String
    public let content: [ContentBlock]

    public init(role: String, content: [ContentBlock]) {
      self.role = role
      self.content = content
    }
  }

  public enum ContentBlock: Sendable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseID: String, content: String, isError: Bool)

    var json: [String: Any] {
      switch self {
      case let .text(text):
        return ["type": "text", "text": text]
      case let .toolUse(id, name, inputJSON):
        let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) ?? [String: Any]()
        return ["type": "tool_use", "id": id, "name": name, "input": input]
      case let .toolResult(toolUseID, content, isError):
        return ["type": "tool_result", "tool_use_id": toolUseID, "content": content, "is_error": isError]
      }
    }
  }

  private let apiKey: String
  private let baseURL: URL
  private let session: URLSession
  private let model: String

  public init(apiKey: String, model: String, baseURL: URL = URL(string: "https://api.anthropic.com/v1")!, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.model = model
    self.baseURL = baseURL
    self.session = session
  }

  /// Streams one assistant turn. The returned stream yields text deltas and
  /// tool-use announcements as they arrive, and finishes after `message_stop`
  /// (or throws on a non-2xx response / transport error).
  public func streamTurn(
    systemPrompt: String?,
    messages: [Message],
    tools: [(name: String, description: String, inputSchemaJSON: String)]
  ) -> AsyncThrowingStream<AnthropicStreamChunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var body: [String: Any] = [
            "model": model,
            "max_tokens": 8_192,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content.map(\.json)] }
          ]
          if let systemPrompt, !systemPrompt.isEmpty { body["system"] = systemPrompt }
          if !tools.isEmpty {
            body["tools"] = tools.map { tool in
              [
                "name": tool.name,
                "description": tool.description,
                "input_schema": (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) ?? [String: Any]()
              ]
            }
          }
          var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
          request.httpMethod = "POST"
          request.timeoutInterval = 604_800
          request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
          request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          let (bytes, response) = try await session.bytes(for: request)
          guard let http = response as? HTTPURLResponse else { throw AnthropicClientError.invalidResponse }
          guard (200..<300).contains(http.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw AnthropicClientError.httpError(status: http.statusCode, body: errorBody)
          }

          var currentToolUseID: String?
          for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "content_block_start":
              if let block = object["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
                 let id = block["id"] as? String, let name = block["name"] as? String {
                currentToolUseID = id
                continuation.yield(.toolUseStart(id: id, name: name))
              }
            case "content_block_delta":
              guard let delta = object["delta"] as? [String: Any] else { continue }
              if let text = delta["text"] as? String {
                continuation.yield(.textDelta(text))
              } else if let partialJSON = delta["partial_json"] as? String, let id = currentToolUseID {
                continuation.yield(.toolUseInputDelta(id: id, partialJSON: partialJSON))
              }
            case "content_block_stop":
              currentToolUseID = nil
            case "message_stop":
              continuation.yield(.messageStop)
            default:
              continue
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
