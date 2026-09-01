import Foundation

/// A real, working second `EngineProvider` backend: it calls the Anthropic
/// Messages API directly, with no vendor/engine subprocess, no HTTP+SSE
/// engine of its own, and no `EngineProcessLifecycle` (there is no process to
/// supervise). This exists to prove `EngineProvider` is an abstraction that
/// actually holds across two structurally different execution models — an
/// SSE-driven subprocess (opencode) and an in-process, request/response API
/// call — not just a protocol that happens to describe opencode.
///
/// Deliberate scope limits, not omissions to fix later:
/// - `steer` degrades to a queued follow-up prompt: the Messages API has no
///   "interrupt the current generation" primitive, so mid-turn steering is
///   not possible here. Callers should not assume steer always preempts.
/// - Only a minimal tool set (read/write/shell, backed by the same native
///   primitives Terminal already uses) is wired up — this is not a second
///   implementation of opencode's full tool catalog.
/// - `forkSession`, `revert`/`unrevert`, MCP management, skills, and slash
///   commands are opencode-specific durable-session features with no
///   Anthropic-API equivalent; they use the protocol's throwing/empty
///   defaults rather than fake support.
public final class AnthropicDirectEngineProvider: EngineProvider, @unchecked Sendable {
  private let apiKey: String
  private let model: String
  private let urlSession: URLSession
  private let lock = NSLock()
  private var sessions: [String: SessionState] = [:]

  private struct SessionState {
    var messages: [AnthropicMessagesClient.Message] = []
    var directory: String?
  }

  /// `session` is injectable so checks can point this at a `MockURLProtocol`
  /// session without a real Anthropic API key or network access.
  public init(apiKey: String, model: String, session: URLSession = .shared) {
    self.apiKey = apiKey
    self.model = model
    self.urlSession = session
  }

  private func makeClient() -> AnthropicMessagesClient {
    AnthropicMessagesClient(apiKey: apiKey, model: model, session: urlSession)
  }

  public func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    let id = "anthropic-\(UUID().uuidString)"
    lock.withLock { sessions[id] = SessionState(directory: input.directory) }
    return KimiRuntimeSession(id: id, title: input.title, directory: input.directory)
  }

  public func prompt(_ input: KimiRuntimePromptInput) async throws {
    lock.withLock {
      var state = sessions[input.sessionID] ?? SessionState()
      state.messages.append(AnthropicMessagesClient.Message(role: "user", content: [.text(input.text)]))
      sessions[input.sessionID] = state
    }
  }

  /// No interrupt primitive on the Messages API — queues as the next turn's
  /// leading message instead of preempting a turn already in flight.
  public func steer(_ input: KimiRuntimeSteerInput) async throws {
    try await prompt(KimiRuntimePromptInput(sessionID: input.sessionID, text: input.text, directory: input.directory))
  }

  public func abort(sessionID: String, directory: String?) async throws {
    lock.withLock {
      activeTasks[sessionID]?.cancel()
      activeTasks.removeValue(forKey: sessionID)
    }
  }

  public func respondPermission(_ input: PermissionResponse) async throws {
    // This backend never emits permissionAsked (its minimal tool set runs
    // without an approval gate — see the module doc's scope note), so there
    // is nothing to resolve here.
  }

  public func listSessions(directory: String?) async throws -> [KimiRuntimeSession] {
    lock.withLock { sessions.map { KimiRuntimeSession(id: $0.key, directory: $0.value.directory) } }
  }

  public func fetchSessionStatuses(directory: String?) async throws -> [String: String] {
    lock.withLock { Dictionary(uniqueKeysWithValues: activeTasks.keys.map { ($0, "busy") }) }
  }

  private var activeTasks: [String: Task<Void, Never>] = [:]

  /// One assistant turn, including any tool-use round trips, expressed as an
  /// event stream. `KimiRuntimeOperationDriver.run` calls this once per turn
  /// (before sending the triggering prompt), so this waits for the next user
  /// message to land on `sessionID` and then drives the full turn — text
  /// deltas, tool calls, tool results, and finally the explicit
  /// `turnOutcome: .completed` the driver blocks on.
  public func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      let baselineCount = lock.withLock { sessions[sessionID]?.messages.count ?? 0 }
      let task = Task {
        do {
          while true {
            if Task.isCancelled {
              continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionIdle, turnOutcome: .aborted))
              continuation.finish()
              return
            }
            let current = lock.withLock { sessions[sessionID]?.messages.count ?? 0 }
            if current > baselineCount { break }
            try await Task.sleep(for: .milliseconds(50))
          }
          try await self.runTurn(sessionID: sessionID, directory: directory, continuation: continuation)
          // Every EngineProvider must emit exactly one event whose turnOutcome
          // is set when a turn is fully done — this is the frame
          // KimiRuntimeOperationDriver.waitForCompletion actually blocks on.
          continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionIdle, turnOutcome: .completed))
          continuation.finish()
        } catch {
          continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .error, text: error.localizedDescription, turnOutcome: .failed))
          continuation.finish(throwing: error)
        }
      }
      lock.withLock { activeTasks[sessionID] = task }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Runs the Anthropic tool-use loop to completion: stream a turn, execute
  /// any tool_use blocks the model requested, feed the results back as the
  /// next turn's leading message, and repeat until the model stops asking
  /// for tools (or the round cap is hit — a runaway tool loop must not hang
  /// the operation forever).
  private func runTurn(sessionID: String, directory: String?, continuation: AsyncThrowingStream<EngineRuntimeEvent, Error>.Continuation) async throws {
    let client = makeClient()
    let messageID = UUID().uuidString
    var round = 0
    while round < 10 {
      round += 1
      let history = lock.withLock { sessions[sessionID]?.messages ?? [] }
      var assistantText = ""
      var toolUses: [String: (name: String, inputJSON: String)] = [:]
      var toolUseOrder: [String] = []
      let partID = UUID().uuidString

      for try await chunk in client.streamTurn(systemPrompt: nil, messages: history, tools: Self.toolDefinitions) {
        switch chunk {
        case let .textDelta(text):
          assistantText += text
          continuation.yield(EngineRuntimeEvent(
            sessionID: sessionID, kind: .assistantText, text: text,
            messageID: messageID, partID: partID, isSnapshot: false
          ))
        case let .toolUseStart(id, name):
          toolUses[id] = (name: name, inputJSON: "")
          toolUseOrder.append(id)
        case let .toolUseInputDelta(id, partialJSON):
          toolUses[id]?.inputJSON += partialJSON
        case .messageStop:
          break
        }
      }

      var assistantContent: [AnthropicMessagesClient.ContentBlock] = []
      if !assistantText.isEmpty { assistantContent.append(.text(assistantText)) }
      for id in toolUseOrder {
        guard let use = toolUses[id] else { continue }
        assistantContent.append(.toolUse(id: id, name: use.name, inputJSON: use.inputJSON))
      }
      lock.withLock {
        var state = sessions[sessionID] ?? SessionState()
        state.messages.append(AnthropicMessagesClient.Message(role: "assistant", content: assistantContent))
        sessions[sessionID] = state
      }

      guard !toolUseOrder.isEmpty else { return }

      var resultBlocks: [AnthropicMessagesClient.ContentBlock] = []
      for id in toolUseOrder {
        guard let use = toolUses[id] else { continue }
        continuation.yield(EngineRuntimeEvent(
          sessionID: sessionID, kind: .toolCall, toolCallID: id, toolID: use.name,
          payload: ["arguments": use.inputJSON]
        ))
        let result = Self.executeTool(name: use.name, inputJSON: use.inputJSON, directory: directory)
        continuation.yield(EngineRuntimeEvent(
          sessionID: sessionID, kind: .toolResult, text: result.output, toolCallID: id, toolID: use.name,
          payload: result.isError ? ["status": "failed"] : ["status": "completed"]
        ))
        resultBlocks.append(.toolResult(toolUseID: id, content: result.output, isError: result.isError))
      }
      lock.withLock {
        var state = sessions[sessionID] ?? SessionState()
        state.messages.append(AnthropicMessagesClient.Message(role: "user", content: resultBlocks))
        sessions[sessionID] = state
      }
    }
  }

  private static let toolDefinitions: [(name: String, description: String, inputSchemaJSON: String)] = [
    (name: "read", description: "Read a file's contents from the local filesystem.",
     inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#),
    (name: "write", description: "Write content to a file on the local filesystem, creating it if needed.",
     inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#),
    (name: "bash", description: "Run a shell command and return its output.",
     inputSchemaJSON: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#)
  ]

  private static func executeTool(name: String, inputJSON: String, directory: String?) -> (output: String, isError: Bool) {
    let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any]) ?? [:]
    let cwd = URL(fileURLWithPath: directory ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    switch name {
    case "read":
      guard let path = input["path"] as? String else { return ("read 缺少 path 参数。", true) }
      let url = URL(fileURLWithPath: path, relativeTo: cwd)
      guard let content = try? String(contentsOf: url, encoding: .utf8) else {
        return ("无法读取文件：\(path)", true)
      }
      return (content, false)
    case "write":
      guard let path = input["path"] as? String, let content = input["content"] as? String else {
        return ("write 缺少 path 或 content 参数。", true)
      }
      let url = URL(fileURLWithPath: path, relativeTo: cwd)
      do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ("已写入 \(path)", false)
      } catch {
        return ("写入失败：\(error.localizedDescription)", true)
      }
    case "bash":
      guard let command = input["command"] as? String else { return ("bash 缺少 command 参数。", true) }
      do {
        let result = try TerminalCommandRunner.run(command: command, cwd: cwd)
        let combined = result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError)
        return (combined, result.exitCode != 0)
      } catch {
        return ("命令执行失败：\(error.localizedDescription)", true)
      }
    default:
      return ("未知工具：\(name)", true)
    }
  }
}
