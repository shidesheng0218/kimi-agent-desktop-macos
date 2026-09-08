import Foundation

public struct KimiRuntimeSession: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var title: String?
  public var directory: String?
  /// The engine-side session ID this one was forked from (via POST
  /// /session/:id/fork or by passing parentID at creation), or nil for a
  /// root session. Mirrors the engine's session Info.parentID field.
  public var parentID: String?

  public init(id: String, title: String? = nil, directory: String? = nil, parentID: String? = nil) {
    self.id = id
    self.title = title
    self.directory = directory
    self.parentID = parentID
  }
}

public struct CreateSessionInput: Codable, Sendable {
  public let directory: String?
  public let title: String?
  /// When set, the engine creates this session as a child of the given
  /// session ID (same effect as forking with no messageID — full history
  /// carried over). Most callers leave this nil for a fresh root session.
  public let parentID: String?

  public init(directory: String? = nil, title: String? = nil, parentID: String? = nil) {
    self.directory = directory
    self.title = title
    self.parentID = parentID
  }
}

public struct KimiRuntimePromptInput: Codable, Sendable {
  public let sessionID: String
  public let text: String
  public let directory: String?
  /// Per-prompt model override; the engine accepts a ModelRef in the prompt
  /// body, so switching models never requires a runtime restart.
  public let modelID: String?
  /// 附件映射为引擎 FilePartInput（图片 data URL / 文件 file:// 引用），
  /// 追加在 text part 之后；空数组时请求体与历史行为一致。
  public let attachments: [KimiPromptAttachment]
  /// prompt 级 agent 覆盖（引擎 PromptInput.agent，如 "plan"）；nil 时
  /// 请求体与历史行为一致，引擎回落到默认 build agent。
  public let agent: String?

  public init(sessionID: String, text: String, directory: String? = nil, modelID: String? = nil, attachments: [KimiPromptAttachment] = [], agent: String? = nil) {
    self.sessionID = sessionID
    self.text = text
    self.directory = directory
    self.modelID = modelID
    self.attachments = attachments
    self.agent = agent
  }
}

public struct KimiRuntimeSteerInput: Codable, Sendable {
  public let sessionID: String
  public let text: String
  public let directory: String?

  public init(sessionID: String, text: String, directory: String? = nil) {
    self.sessionID = sessionID
    self.text = text
    self.directory = directory
  }
}

public struct PermissionResponse: Codable, Sendable {
  public let sessionID: String
  public let requestID: String
  public let reply: String
  public let message: String?
  /// Project directory routing the request to the engine instance that owns
  /// the pending permission.
  public let directory: String?

  public init(sessionID: String, requestID: String, reply: String, message: String? = nil, directory: String? = nil) {
    self.sessionID = sessionID
    self.requestID = requestID
    self.reply = reply
    self.message = message
    self.directory = directory
  }
}

/// One part of a restored engine message (GET /session/:id/message).
public struct KimiRuntimeHistoryPart: Sendable, Equatable {
  public let partID: String
  public let type: String
  public let text: String?
  public let toolName: String?
  public let callID: String?
  public let status: String?
  public let output: String?
  /// file part 的展示字段：历史重建时把用户消息里的附件还原成缩略图/文件名 chip。
  public let mime: String?
  public let filename: String?
  public let url: String?
  /// 引擎为 file part 生成的合成文本（"Called the Read tool..."、文件内容），
  /// 重建用户消息气泡时要排除，否则附件内容会灌进气泡正文。
  public let synthetic: Bool

  public init(partID: String, type: String, text: String? = nil, toolName: String? = nil, callID: String? = nil, status: String? = nil, output: String? = nil, mime: String? = nil, filename: String? = nil, url: String? = nil, synthetic: Bool = false) {
    self.partID = partID
    self.type = type
    self.text = text
    self.toolName = toolName
    self.callID = callID
    self.status = status
    self.output = output
    self.mime = mime
    self.filename = filename
    self.url = url
    self.synthetic = synthetic
  }
}

/// A durable engine conversation message with its parts, used to rebuild the
/// chat UI after a session switch or app restart.
public struct KimiRuntimeHistoryMessage: Sendable, Equatable {
  public let id: String
  public let role: String
  public let createdAt: Date?
  public let parts: [KimiRuntimeHistoryPart]

  public init(id: String, role: String, createdAt: Date?, parts: [KimiRuntimeHistoryPart]) {
    self.id = id
    self.role = role
    self.createdAt = createdAt
    self.parts = parts
  }
}

/// One engine-agnostic execution backend. `KimiAppKernel` and
/// `KimiRuntimeOperationDriver` talk to whichever backend is configured only
/// through this protocol — they hold `any EngineProvider` and never branch on
/// which concrete implementation is live. The opencode-backed
/// `URLSessionRuntimeClient` and `AnthropicDirectEngineProvider` are two
/// implementations of the exact same contract.
///
/// Every `directory` parameter is a workspace-context hint, not a literal
/// opencode HTTP query parameter: `URLSessionRuntimeClient` forwards it as
/// opencode's directory-routing query string (its engine process serves
/// multiple project directories from one instance), while
/// `AnthropicDirectEngineProvider` only reads it as an optional cwd hint for
/// local tool execution and otherwise ignores it — a backend with no
/// directory-routing concept of its own is free to no-op on it.
public protocol EngineProvider: Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession
  /// Forks a session via POST /session/:sessionID/fork. Passing messageID
  /// branches from that specific message; nil forks the entire history up to
  /// the current point. The returned session's parentID is set by the engine.
  func forkSession(sessionID: String, messageID: String?, directory: String?) async throws -> KimiRuntimeSession
  func prompt(_ input: KimiRuntimePromptInput) async throws
  func steer(_ input: KimiRuntimeSteerInput) async throws
  func abort(sessionID: String, directory: String?) async throws
  func respondPermission(_ input: PermissionResponse) async throws
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession]
  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error>
  func fetchMessages(sessionID: String, directory: String?) async throws -> [KimiRuntimeHistoryMessage]
  func fetchModelCatalog(directory: String?) async throws -> [String]
  func fetchTodos(sessionID: String, directory: String?) async throws -> [KimiTodoItem]
  func fetchCommands(directory: String?) async throws -> [KimiSlashCommand]
  func answerQuestion(requestID: String, answers: [[String]], directory: String?) async throws
  func rejectQuestion(requestID: String, directory: String?) async throws
  func revert(sessionID: String, messageID: String, directory: String?) async throws
  func unrevert(sessionID: String, directory: String?) async throws
  func runCommand(sessionID: String, command: String, arguments: String, directory: String?) async throws
  func summarize(sessionID: String, modelID: String, directory: String?) async throws
  func fetchMcpStatus(directory: String?) async throws -> [KimiMcpServerStatus]
  func fetchSkills(directory: String?) async throws -> [KimiSkillSummary]
  /// Adds an MCP server at runtime via POST /mcp, without restarting the engine.
  func addMCPServer(_ entry: KimiMCPServerEntry, directory: String?) async throws
  /// Disconnects an MCP server via POST /mcp/{name}/disconnect, without restart.
  func removeMCPServer(name: String, directory: String?) async throws
  /// Engine-side busy/idle map (`GET /session/status`), used to reconcile UI
  /// state after an event-stream reconnect where a completion frame may have
  /// been missed.
  func fetchSessionStatuses(directory: String?) async throws -> [String: String]
  /// Runtime per-session permission ruleset (PATCH /session/:id). The engine
  /// merges it after the agent-level rules and evaluates last-match-wins, so
  /// these rules override the launch-time config without an engine restart.
  func updateSessionPermission(sessionID: String, ruleset: [KimiPermissionRule], directory: String?) async throws
  /// 删除会话及其全部历史(DELETE /session/:id),用于会话删除与侧聊临时
  /// 会话清理。
  func deleteSession(sessionID: String, directory: String?) async throws
}

/// Convenience defaults keep scripted clients in checks and smoke targets
/// minimal; the production URLSession client provides real implementations.
public extension EngineProvider {
  func forkSession(sessionID: String, messageID: String?, directory: String?) async throws -> KimiRuntimeSession { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func fetchMessages(sessionID: String, directory: String?) async throws -> [KimiRuntimeHistoryMessage] { [] }
  func fetchModelCatalog(directory: String?) async throws -> [String] { [] }
  func fetchTodos(sessionID: String, directory: String?) async throws -> [KimiTodoItem] { [] }
  func fetchCommands(directory: String?) async throws -> [KimiSlashCommand] { [] }
  func answerQuestion(requestID: String, answers: [[String]], directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func rejectQuestion(requestID: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func revert(sessionID: String, messageID: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func unrevert(sessionID: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func runCommand(sessionID: String, command: String, arguments: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func summarize(sessionID: String, modelID: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func fetchMcpStatus(directory: String?) async throws -> [KimiMcpServerStatus] { [] }
  func fetchSkills(directory: String?) async throws -> [KimiSkillSummary] { [] }
  func addMCPServer(_ entry: KimiMCPServerEntry, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func removeMCPServer(name: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  func fetchSessionStatuses(directory: String?) async throws -> [String: String] { [:] }
  /// 无权限门概念的 backend（如 Anthropic 直连）静默忽略；权限模式同步是
  /// best-effort，失败只意味着回落到引擎默认的 ask 行为。
  func updateSessionPermission(sessionID: String, ruleset: [KimiPermissionRule], directory: String?) async throws {}
  func deleteSession(sessionID: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
}

public final class URLSessionRuntimeClient: EngineProvider, @unchecked Sendable {
  private let endpoint: KimiRuntimeEndpoint
  private let directory: String?
  private let session: URLSession

  public init(endpoint: KimiRuntimeEndpoint, directory: String? = nil, session: URLSession = .shared) {
    self.endpoint = endpoint
    self.directory = directory
    self.session = session
  }

  public func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    // The engine resolves the working directory from the request query (or
    // the x-opencode-directory header), never from the body: putting
    // `directory` in the JSON body silently created every session in the
    // engine process's cwd instead of the chosen project.
    var body: [String: Any] = [:]
    if let title = input.title { body["title"] = title }
    if let parentID = input.parentID { body["parentID"] = parentID }
    return try await request(
      path: "/session",
      method: "POST",
      query: directoryQuery(input.directory),
      body: body
    )
  }

  public func forkSession(sessionID: String, messageID: String?, directory: String?) async throws -> KimiRuntimeSession {
    var body: [String: Any] = [:]
    if let messageID { body["messageID"] = messageID }
    return try await request(
      path: "/session/\(sessionID)/fork",
      method: "POST",
      query: directoryQuery(directory),
      body: body
    )
  }

  public func prompt(_ input: KimiRuntimePromptInput) async throws {
    // 引擎 PromptInput schema：parts 为 TextPartInput | FilePartInput 的
    // 判别联合（type 字段判别）。FilePartInput 的 url 支持 data:（base64）
    // 与 file://（引擎端 Read 工具读取）两种协议，无需任何降级路径。
    var parts: [[String: Any]] = []
    if !input.text.isEmpty {
      parts.append(["type": "text", "text": input.text])
    }
    for attachment in input.attachments {
      parts.append([
        "type": "file",
        "mime": attachment.mime,
        "url": attachment.url,
        "filename": attachment.filename,
      ])
    }
    var body: [String: Any] = ["parts": parts]
    if let modelID = input.modelID, !modelID.isEmpty {
      body["model"] = ["providerID": KimiRuntimeIdentityStore.providerID, "modelID": modelID]
    }
    if let agent = input.agent, !agent.isEmpty {
      body["agent"] = agent
    }
    _ = try await requestData(
      path: "/session/\(input.sessionID)/prompt_async",
      method: "POST",
      query: directoryQuery(input.directory),
      body: body
    )
  }

  public func steer(_ input: KimiRuntimeSteerInput) async throws {
    // The engine has no dedicated steer endpoint: a prompt sent while the
    // session is busy is admitted into the running loop and picked up on its
    // next iteration, which is exactly the steering semantics we want.
    try await prompt(KimiRuntimePromptInput(sessionID: input.sessionID, text: input.text, directory: input.directory))
  }

  public func abort(sessionID: String, directory: String?) async throws {
    _ = try await requestData(path: "/session/\(sessionID)/abort", method: "POST", query: directoryQuery(directory), body: nil)
  }

  public func respondPermission(_ input: PermissionResponse) async throws {
    var body: [String: Any] = ["reply": input.reply]
    if let message = input.message { body["message"] = message }
    _ = try await requestData(
      path: "/permission/\(input.requestID)/reply",
      method: "POST",
      query: directoryQuery(input.directory),
      body: body
    )
  }

  public func listSessions(directory: String? = nil) async throws -> [KimiRuntimeSession] {
    try await request(path: "/session", method: "GET", query: directoryQuery(directory), body: nil)
  }

  public func fetchMessages(sessionID: String, directory: String?) async throws -> [KimiRuntimeHistoryMessage] {
    let data = try await requestData(path: "/session/\(sessionID)/message", method: "GET", query: directoryQuery(directory), body: nil)
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return array.compactMap(Self.parseHistoryMessage)
  }

  public func fetchModelCatalog(directory: String?) async throws -> [String] {
    let data = try await requestData(path: "/provider", method: "GET", query: directoryQuery(directory), body: nil)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let providers = object["all"] as? [[String: Any]] ?? []
    let connected = Set(object["connected"] as? [String] ?? [])
    // Prefer the provider the app is configured for; fall back to any
    // connected provider rather than whichever happens to sort first.
    let preferred = providers.first(where: { $0["id"] as? String == KimiRuntimeIdentityStore.providerID })
      ?? providers.first(where: { connected.contains($0["id"] as? String ?? "") })
      ?? providers.first
    let models = preferred?["models"] as? [String: Any] ?? [:]
    return models.keys.sorted()
  }

  public func fetchTodos(sessionID: String, directory: String?) async throws -> [KimiTodoItem] {
    let data = try await requestData(path: "/session/\(sessionID)/todo", method: "GET", query: directoryQuery(directory), body: nil)
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return KimiRuntimeEventBridge.decodeTodos(text)
  }

  public func fetchCommands(directory: String?) async throws -> [KimiSlashCommand] {
    let data = try await requestData(path: "/command", method: "GET", query: directoryQuery(directory), body: nil)
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return array.compactMap { item in
      guard let name = item["name"] as? String, !name.isEmpty else { return nil }
      return KimiSlashCommand(
        name: name,
        description: item["description"] as? String,
        hint: item["hint"] as? String ?? item["template"] as? String
      )
    }
  }

  public func answerQuestion(requestID: String, answers: [[String]], directory: String?) async throws {
    _ = try await requestData(
      path: "/question/\(requestID)/reply",
      method: "POST",
      query: directoryQuery(directory),
      body: ["answers": answers]
    )
  }

  public func rejectQuestion(requestID: String, directory: String?) async throws {
    _ = try await requestData(path: "/question/\(requestID)/reject", method: "POST", query: directoryQuery(directory), body: nil)
  }

  public func revert(sessionID: String, messageID: String, directory: String?) async throws {
    _ = try await requestData(
      path: "/session/\(sessionID)/revert",
      method: "POST",
      query: directoryQuery(directory),
      body: ["messageID": messageID]
    )
  }

  public func unrevert(sessionID: String, directory: String?) async throws {
    _ = try await requestData(path: "/session/\(sessionID)/unrevert", method: "POST", query: directoryQuery(directory), body: nil)
  }

  public func runCommand(sessionID: String, command: String, arguments: String, directory: String?) async throws {
    _ = try await requestData(
      path: "/session/\(sessionID)/command",
      method: "POST",
      query: directoryQuery(directory),
      body: ["command": command, "arguments": arguments]
    )
  }

  public func summarize(sessionID: String, modelID: String, directory: String?) async throws {
    // The engine rejects the request without providerID/modelID ("Missing
    // key at [\"providerID\"]") — auto:true alone is not enough.
    _ = try await requestData(
      path: "/session/\(sessionID)/summarize",
      method: "POST",
      query: directoryQuery(directory),
      body: ["providerID": KimiRuntimeIdentityStore.providerID, "modelID": modelID, "auto": true]
    )
  }

  public func fetchMcpStatus(directory: String?) async throws -> [KimiMcpServerStatus] {
    let data = try await requestData(path: "/mcp", method: "GET", query: directoryQuery(directory), body: nil)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    // The endpoint returns a name → status-object map; tolerate both nested
    // objects and plain status strings.
    return object.keys.sorted().map { name in
      if let detail = object[name] as? [String: Any] {
        let status = detail["status"] as? String ?? "unknown"
        let message = detail["error"] as? String ?? detail["message"] as? String
        return KimiMcpServerStatus(name: name, status: status, detail: message)
      }
      return KimiMcpServerStatus(name: name, status: object[name] as? String ?? "unknown")
    }
  }

  public func fetchSkills(directory: String?) async throws -> [KimiSkillSummary] {
    let data = try await requestData(path: "/skill", method: "GET", query: directoryQuery(directory), body: nil)
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return array.compactMap { item in
      guard let name = item["name"] as? String, !name.isEmpty else { return nil }
      return KimiSkillSummary(name: name, description: item["description"] as? String)
    }
  }

  public func addMCPServer(_ entry: KimiMCPServerEntry, directory: String?) async throws {
    // POST /mcp adds the server at runtime without restarting the engine.
    // Body shape: { name: <server id>, config: <engine mcp schema object> }
    _ = try await requestData(
      path: "/mcp",
      method: "POST",
      query: directoryQuery(directory),
      body: ["name": entry.id, "config": entry.toEngineConfig()]
    )
  }

  public func removeMCPServer(name: String, directory: String?) async throws {
    // POST /mcp/{name}/disconnect disconnects the server at runtime.
    _ = try await requestData(
      path: "/mcp/\(name)/disconnect",
      method: "POST",
      query: directoryQuery(directory),
      body: nil
    )
  }

  public func fetchSessionStatuses(directory: String?) async throws -> [String: String] {
    let data = try await requestData(path: "/session/status", method: "GET", query: directoryQuery(directory), body: nil)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    var statuses: [String: String] = [:]
    for (sessionID, value) in object {
      if let entry = value as? [String: Any], let type = entry["type"] as? String {
        statuses[sessionID] = type
      } else if let type = value as? String {
        statuses[sessionID] = type
      }
    }
    return statuses
  }

  public func updateSessionPermission(sessionID: String, ruleset: [KimiPermissionRule], directory: String?) async throws {
    let rules: [[String: Any]] = ruleset.map { ["permission": $0.permission, "pattern": $0.pattern, "action": $0.action] }
    _ = try await requestData(
      path: "/session/\(sessionID)",
      method: "PATCH",
      query: directoryQuery(directory),
      body: ["permission": rules]
    )
  }

  public func deleteSession(sessionID: String, directory: String?) async throws {
    _ = try await requestData(path: "/session/\(sessionID)", method: "DELETE", query: directoryQuery(directory), body: nil)
  }

  static func parseHistoryMessage(_ object: [String: Any]) -> KimiRuntimeHistoryMessage? {
    guard let info = object["info"] as? [String: Any], let id = info["id"] as? String else { return nil }
    let role = info["role"] as? String ?? "assistant"
    var createdAt: Date?
    if let time = info["time"] as? [String: Any], let raw = (time["created"] as? NSNumber)?.doubleValue {
      // Engine timestamps are epoch milliseconds; tolerate seconds as well.
      createdAt = Date(timeIntervalSince1970: raw > 1e12 ? raw / 1_000 : raw)
    }
    let rawParts = object["parts"] as? [[String: Any]] ?? []
    let parts = rawParts.map { part in
      KimiRuntimeHistoryPart(
        partID: part["id"] as? String ?? UUID().uuidString,
        type: (part["type"] as? String)?.lowercased() ?? "text",
        text: part["text"] as? String,
        toolName: part["tool"] as? String,
        callID: part["callID"] as? String,
        status: (part["state"] as? [String: Any])?["status"] as? String,
        output: KimiRuntimeEventDecoder.stringify((part["state"] as? [String: Any])?["output"]),
        mime: part["mime"] as? String,
        filename: part["filename"] as? String,
        url: part["url"] as? String,
        synthetic: part["synthetic"] as? Bool ?? false
      )
    }
    return KimiRuntimeHistoryMessage(id: id, role: role, createdAt: createdAt, parts: parts)
  }

  public func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    let eventURL = Self.endpointURL(
      base: endpoint.baseURL,
      path: "/event",
      queryItems: directoryQuery(directory ?? self.directory)
    )
    var request = URLRequest(url: eventURL)
    // SSE streams are open-ended: URLRequest's 60s default timeout kills a
    // long agentic turn's stream mid-run (and with it every later event,
    // including turn completion). Give the stream a effectively-unbounded
    // budget; liveness is monitored via the engine's 10s heartbeats.
    request.timeoutInterval = 604_800
    request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
    let eventRequest = request
    // One decoder per stream: reasoning deltas are classified via the part
    // type registry that only makes sense within a single subscription.
    let decoder = KimiRuntimeEventDecoder()

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: eventRequest)
          guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw KimiRuntimeError.invalidResponse
          }
          var dataLines: [String] = []
          for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            let candidate = Data(dataLines.joined(separator: "\n").utf8)
            // The engine emits one compact JSON object per data line, and the
            // async line iterator never surfaces the blank SSE frame
            // separators — so decode as soon as the accumulated text is a
            // complete JSON object instead of waiting for a frame boundary.
            guard (try? JSONSerialization.jsonObject(with: candidate)) is [String: Any] else { continue }
            if let event = decoder.decode(candidate, sessionID: sessionID), event.sessionID == sessionID {
              continuation.yield(event)
            }
            dataLines.removeAll()
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func directoryQuery(_ override: String?) -> [String: String] {
    guard let value = (override ?? directory)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return [:]
    }
    return ["directory": value]
  }

  /// Query assembly is URLComponents-based so project paths containing `&`,
  /// `=` or spaces cannot corrupt the query string. Exposed for verification
  /// in KimiAgentCoreChecks.
  public static func endpointURL(base: URL, path: String, queryItems: [String: String]) -> URL {
    guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      return base.appendingPathComponent(path)
    }
    if !queryItems.isEmpty {
      components.queryItems = queryItems.map { URLQueryItem(name: $0.key, value: $0.value) }.sorted { $0.name < $1.name }
    }
    return components.url ?? base.appendingPathComponent(path)
  }

  private func request<T: Decodable>(path: String, method: String, query: [String: String], body: [String: Any]?) async throws -> T {
    let data = try await requestData(path: path, method: method, query: query, body: body)
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw KimiRuntimeError.requestFailed("引擎响应解析失败：\(error.localizedDescription)") }
  }

  private func requestData(path: String, method: String, query: [String: String], body: [String: Any]?) async throws -> Data {
    let url = Self.endpointURL(base: endpoint.baseURL, path: path, queryItems: query)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw KimiRuntimeError.requestFailed("引擎 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
      }
      return data
    } catch let error as KimiRuntimeError {
      throw error
    } catch {
      throw KimiRuntimeError.requestFailed(error.localizedDescription)
    }
  }
}
