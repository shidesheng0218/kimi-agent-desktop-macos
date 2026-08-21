import Foundation

public struct KimiRuntimeSession: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var title: String?
  public var directory: String?

  public init(id: String, title: String? = nil, directory: String? = nil) {
    self.id = id
    self.title = title
    self.directory = directory
  }
}

public struct CreateSessionInput: Codable, Sendable {
  public let directory: String?
  public let title: String?

  public init(directory: String? = nil, title: String? = nil) {
    self.directory = directory
    self.title = title
  }
}

public struct KimiRuntimePromptInput: Codable, Sendable {
  public let sessionID: String
  public let text: String
  public let directory: String?
  /// Per-prompt model override; the engine accepts a ModelRef in the prompt
  /// body, so switching models never requires a runtime restart.
  public let modelID: String?

  public init(sessionID: String, text: String, directory: String? = nil, modelID: String? = nil) {
    self.sessionID = sessionID
    self.text = text
    self.directory = directory
    self.modelID = modelID
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

  public init(partID: String, type: String, text: String? = nil, toolName: String? = nil, callID: String? = nil, status: String? = nil, output: String? = nil) {
    self.partID = partID
    self.type = type
    self.text = text
    self.toolName = toolName
    self.callID = callID
    self.status = status
    self.output = output
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

public protocol KimiRuntimeSessionClient: Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession
  func prompt(_ input: KimiRuntimePromptInput) async throws
  func steer(_ input: KimiRuntimeSteerInput) async throws
  func abort(sessionID: String, directory: String?) async throws
  func respondPermission(_ input: PermissionResponse) async throws
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession]
  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error>
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
  /// Engine-side busy/idle map (`GET /session/status`), used to reconcile UI
  /// state after an event-stream reconnect where a completion frame may have
  /// been missed.
  func fetchSessionStatuses(directory: String?) async throws -> [String: String]
}

/// Convenience defaults keep scripted clients in checks and smoke targets
/// minimal; the production URLSession client provides real implementations.
public extension KimiRuntimeSessionClient {
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
  func fetchSessionStatuses(directory: String?) async throws -> [String: String] { [:] }
}

public final class URLSessionRuntimeClient: KimiRuntimeSessionClient, @unchecked Sendable {
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
    return try await request(
      path: "/session",
      method: "POST",
      query: directoryQuery(input.directory),
      body: body
    )
  }

  public func prompt(_ input: KimiRuntimePromptInput) async throws {
    var body: [String: Any] = [
      "parts": [["type": "text", "text": input.text]]
    ]
    if let modelID = input.modelID, !modelID.isEmpty {
      body["model"] = ["providerID": KimiRuntimeIdentityStore.providerID, "modelID": modelID]
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
        output: KimiRuntimeEventDecoder.stringify((part["state"] as? [String: Any])?["output"])
      )
    }
    return KimiRuntimeHistoryMessage(id: id, role: role, createdAt: createdAt, parts: parts)
  }

  public func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
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
