import CryptoKit
import Darwin
import Foundation

/// Errors emitted by the native Web capability.  They are structured so the
/// model receives an actionable tool result rather than an opaque transport
/// failure.
public enum WebRuntimeError: LocalizedError, Equatable, Sendable {
  case invalidURL(String)
  case unsafeTarget(String)
  case unavailable(String)
  case providerFailure(String)
  case timeout
  case responseTooLarge
  case unsupportedContentType(String)
  case invalidResponse
  case redirectLimitExceeded

  public var errorDescription: String? {
    switch self {
    case let .invalidURL(value): "Web URL 无效：\(value)"
    case let .unsafeTarget(value): "Web Fetch 已拦截不安全目标：\(value)"
    case let .unavailable(value): "联网服务不可用：\(value)"
    case let .providerFailure(value): "联网服务失败：\(value)"
    case .timeout: "Web 请求超时。"
    case .responseTooLarge: "Web 响应超过安全大小限制。"
    case let .unsupportedContentType(value): "Web 响应类型不受支持：\(value)"
    case .invalidResponse: "Web 服务返回了无效响应。"
    case .redirectLimitExceeded: "Web 重定向次数超过限制。"
    }
  }
}

public struct WebSource: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let url: String
  public let snippet: String
  public let publishedAt: String?

  public init(id: String? = nil, title: String, url: String, snippet: String = "", publishedAt: String? = nil) {
    self.id = id ?? WebSource.stableID(for: url)
    self.title = title
    self.url = url
    self.snippet = snippet
    self.publishedAt = publishedAt
  }

  public static func stableID(for url: String) -> String {
    let digest = SHA256.hash(data: Data(url.lowercased().utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

public struct WebSearchRequest: Codable, Equatable, Sendable {
  public let query: String
  public let maxResults: Int
  public let language: String?
  public let freshness: String?

  public init(query: String, maxResults: Int = 8, language: String? = nil, freshness: String? = nil) {
    self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    self.maxResults = min(max(maxResults, 1), 8)
    self.language = language?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    self.freshness = freshness?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
  }
}

public struct WebSearchResult: Codable, Equatable, Sendable {
  public let providerID: String
  public let sources: [WebSource]
  public let cached: Bool
  public let fallbackUsed: Bool
  public let elapsedMilliseconds: Int

  public init(providerID: String, sources: [WebSource], cached: Bool = false, fallbackUsed: Bool = false, elapsedMilliseconds: Int = 0) {
    self.providerID = providerID
    self.sources = Array(sources.prefix(8))
    self.cached = cached
    self.fallbackUsed = fallbackUsed
    self.elapsedMilliseconds = max(0, elapsedMilliseconds)
  }
}

public struct WebFetchRequest: Codable, Equatable, Sendable {
  public let url: String
  public let sourceID: String?
  public let maxCharacters: Int

  public init(url: String, sourceID: String? = nil, maxCharacters: Int = 100_000) {
    self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sourceID = sourceID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    self.maxCharacters = min(max(maxCharacters, 1_000), 100_000)
  }
}

public enum WebFetchContentKind: String, Codable, Equatable, Sendable {
  case html
  case text
}

public struct WebFetchResult: Codable, Equatable, Sendable {
  public let url: String
  public let statusCode: Int
  public let contentType: String
  public let kind: WebFetchContentKind
  public let title: String
  public let content: String
  public let truncated: Bool
  public let elapsedMilliseconds: Int

  public init(
    url: String,
    statusCode: Int,
    contentType: String,
    kind: WebFetchContentKind,
    title: String,
    content: String,
    truncated: Bool,
    elapsedMilliseconds: Int
  ) {
    self.url = url
    self.statusCode = statusCode
    self.contentType = contentType
    self.kind = kind
    self.title = title
    self.content = content
    self.truncated = truncated
    self.elapsedMilliseconds = max(0, elapsedMilliseconds)
  }
}

public typealias WebHostResolver = @Sendable (String) async throws -> [String]

/// Pure URL and address policy shared by Search result registration, Fetch and
/// redirect handling. DNS must be re-checked at every hop by the caller.
public enum WebFetchPolicy {
  public static let maximumURLLength = 2_048

  public static func validate(url rawValue: String) throws -> URL {
    guard rawValue.count <= maximumURLLength,
          let url = URL(string: rawValue),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty else {
      throw WebRuntimeError.invalidURL(rawValue)
    }
    guard url.user == nil, url.password == nil else {
      throw WebRuntimeError.unsafeTarget("URL 不允许包含用户名或密码")
    }
    guard !isPrivateOrLocalHost(host) else {
      throw WebRuntimeError.unsafeTarget(host)
    }
    return url
  }

  public static func assertPublic(url: URL, resolver: WebHostResolver = defaultResolver) async throws {
    guard let host = url.host, !isPrivateOrLocalHost(host) else {
      throw WebRuntimeError.unsafeTarget(url.host ?? url.absoluteString)
    }
    let addresses: [String]
    do {
      addresses = try await resolver(host)
    } catch {
      throw WebRuntimeError.unsafeTarget("\(host) 无法进行安全 DNS 解析")
    }
    guard !addresses.isEmpty, !addresses.contains(where: isPrivateOrLocalHost) else {
      throw WebRuntimeError.unsafeTarget("\(host) 解析到私网或不可用地址")
    }
  }

  public static func isPrivateOrLocalHost(_ rawValue: String) -> Bool {
    let host = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .lowercased()
    if host.isEmpty || host == "localhost" || host == "ip6-localhost" || host == "0.0.0.0" || host.hasSuffix(".localhost") {
      return true
    }
    if host.contains(":") { return isPrivateIPv6(host) }
    return isPrivateIPv4(host)
  }

  public static let defaultResolver: WebHostResolver = { host in
    try await Task.detached(priority: .utility) {
      var hints = addrinfo(
        ai_flags: AI_ADDRCONFIG,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
      )
      var result: UnsafeMutablePointer<addrinfo>?
      let status = getaddrinfo(host, nil, &hints, &result)
      guard status == 0, let result else {
        throw WebRuntimeError.unsafeTarget("\(host) 无法解析")
      }
      defer { freeaddrinfo(result) }
      var addresses: [String] = []
      var cursor: UnsafeMutablePointer<addrinfo>? = result
      while let value = cursor {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let nameStatus = getnameinfo(value.pointee.ai_addr, value.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        if nameStatus == 0,
           let terminator = buffer.firstIndex(of: 0) {
          addresses.append(String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        cursor = value.pointee.ai_next
      }
      return Array(Set(addresses))
    }.value
  }

  private static func isPrivateIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
    let first = parts[0]
    let second = parts[1]
    return first == 0 || first == 10 || first == 127 ||
      (first == 100 && (64...127).contains(second)) ||
      (first == 169 && second == 254) ||
      (first == 172 && (16...31).contains(second)) ||
      (first == 192 && second == 0) ||
      (first == 192 && second == 168) ||
      (first == 198 && (18...19).contains(second)) ||
      first >= 224
  }

  private static func isPrivateIPv6(_ host: String) -> Bool {
    let normalized = host.lowercased()
    return normalized == "::" || normalized == "::1" || normalized.hasPrefix("fe80:") || normalized.hasPrefix("fc") || normalized.hasPrefix("fd")
  }
}

public protocol WebSearchExecutingProvider: Sendable {
  var id: String { get }
  func isAvailable() async -> Bool
  func search(_ request: WebSearchRequest) async throws -> WebSearchResult
}

public protocol WebFetchExecutingProvider: Sendable {
  var id: String { get }
  func isAvailable() async -> Bool
  func fetch(_ request: WebFetchRequest) async throws -> WebFetchResult
}

/// One native registry owns deterministic provider selection and the source
/// relationship required to make Fetch and citations trustworthy.
public actor WebRuntime {
  private struct RegisteredSource: Sendable {
    let source: WebSource
    let expiresAt: Date
  }

  private let searchPriority: [String]
  private let fetchPriority: [String]
  private let sourceTTL: TimeInterval
  private var searchProviders: [String: any WebSearchExecutingProvider] = [:]
  private var fetchProviders: [String: any WebFetchExecutingProvider] = [:]
  private var sources: [String: RegisteredSource] = [:]

  public init(searchPriority: [String], fetchPriority: [String], sourceTTL: TimeInterval = 600) {
    self.searchPriority = searchPriority
    self.fetchPriority = fetchPriority
    self.sourceTTL = max(60, sourceTTL)
  }

  public func register(search provider: any WebSearchExecutingProvider) throws {
    guard searchProviders[provider.id] == nil else { throw WebRuntimeError.providerFailure("重复 Search Provider：\(provider.id)") }
    searchProviders[provider.id] = provider
  }

  public func register(fetch provider: any WebFetchExecutingProvider) throws {
    guard fetchProviders[provider.id] == nil else { throw WebRuntimeError.providerFailure("重复 Fetch Provider：\(provider.id)") }
    fetchProviders[provider.id] = provider
  }

  public func search(_ request: WebSearchRequest) async throws -> WebSearchResult {
    guard !request.query.isEmpty else { throw WebRuntimeError.providerFailure("web.search 缺少 query") }
    var lastError: Error?
    for (index, id) in searchPriority.enumerated() {
      guard let provider = searchProviders[id], await provider.isAvailable() else { continue }
      do {
        let result = try await provider.search(request)
        let selectedSources = Array(result.sources.prefix(request.maxResults))
        selectedSources.forEach { source in
          sources[source.id] = RegisteredSource(source: source, expiresAt: Date().addingTimeInterval(sourceTTL))
        }
        return WebSearchResult(
          providerID: result.providerID,
          sources: selectedSources,
          cached: result.cached,
          fallbackUsed: result.fallbackUsed || index > 0,
          elapsedMilliseconds: result.elapsedMilliseconds
        )
      } catch {
        lastError = error
      }
    }
    if let lastError { throw lastError }
    throw WebRuntimeError.unavailable("没有已配置的 Web Search Provider")
  }

  public func fetch(_ request: WebFetchRequest) async throws -> WebFetchResult {
    guard !request.url.isEmpty else { throw WebRuntimeError.providerFailure("web.fetch 缺少 url") }
    if let sourceID = request.sourceID {
      guard let registered = sources[sourceID], registered.expiresAt > .now else {
        sources.removeValue(forKey: sourceID)
        throw WebRuntimeError.providerFailure("Web 来源已过期，请先重新搜索")
      }
      guard registered.source.url == request.url else {
        throw WebRuntimeError.providerFailure("sourceID 与 URL 不匹配")
      }
    }
    var lastError: Error?
    for id in fetchPriority {
      guard let provider = fetchProviders[id], await provider.isAvailable() else { continue }
      do { return try await provider.fetch(request) }
      catch { lastError = error }
    }
    if let lastError { throw lastError }
    throw WebRuntimeError.unavailable("没有已配置的 Web Fetch Provider")
  }
}

/// Native HTTP(S) fetcher. It disables cookies, follows redirects manually and
/// re-validates each hop against the same public-network policy.
public final class HTTPWebFetchProvider: NSObject, WebFetchExecutingProvider, @unchecked Sendable {
  public struct Limits: Sendable {
    public let timeout: TimeInterval
    public let maxRedirects: Int
    public let maxResponseBytes: Int
    public let userAgent: String

    public init(timeout: TimeInterval = 10, maxRedirects: Int = 5, maxResponseBytes: Int = 5_000_000, userAgent: String = "KimiCodeAgent/0.3.0") {
      self.timeout = min(max(timeout, 1), 60)
      self.maxRedirects = min(max(maxRedirects, 0), 10)
      self.maxResponseBytes = min(max(maxResponseBytes, 1_024), 5_000_000)
      self.userAgent = userAgent
    }
  }

  public let id: String
  private let limits: Limits
  private let resolver: WebHostResolver

  public init(id: String = "http", limits: Limits = Limits(), resolver: @escaping WebHostResolver = WebFetchPolicy.defaultResolver) {
    self.id = id
    self.limits = limits
    self.resolver = resolver
  }

  public func isAvailable() async -> Bool { true }

  public func fetch(_ request: WebFetchRequest) async throws -> WebFetchResult {
    var current = try WebFetchPolicy.validate(url: request.url)
    let startedAt = Date()
    for redirectCount in 0...limits.maxRedirects {
      try await WebFetchPolicy.assertPublic(url: current, resolver: resolver)
      let response = try await retrieve(current)
      if isRedirect(response.http.statusCode) {
        guard redirectCount < limits.maxRedirects else { throw WebRuntimeError.redirectLimitExceeded }
        guard let location = response.http.value(forHTTPHeaderField: "Location"),
              let next = URL(string: location, relativeTo: current)?.absoluteURL else {
          throw WebRuntimeError.invalidResponse
        }
        current = try WebFetchPolicy.validate(url: next.absoluteString)
        continue
      }
      let contentType = response.http.value(forHTTPHeaderField: "Content-Type") ?? ""
      guard let kind = classify(contentType) else { throw WebRuntimeError.unsupportedContentType(contentType.isEmpty ? "未知" : contentType) }
      let text = try decode(response.data, contentType: contentType)
      let readable = kind == .html
        ? WebReadableDocument.extract(fromHTML: text)
        : WebReadableDocument.Result(title: nil, content: WebReadableDocument.normalize(text))
      let content = String(readable.content.prefix(request.maxCharacters))
      return WebFetchResult(
        url: current.absoluteString,
        statusCode: response.http.statusCode,
        contentType: contentType,
        kind: kind,
        title: readable.title ?? current.host ?? current.absoluteString,
        content: content,
        truncated: response.truncated || readable.content.count > request.maxCharacters,
        elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
      )
    }
    throw WebRuntimeError.redirectLimitExceeded
  }

  private func retrieve(_ url: URL) async throws -> (http: HTTPURLResponse, data: Data, truncated: Bool) {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = limits.timeout
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("text/html,application/xhtml+xml,text/plain,application/json,application/xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
    request.setValue(limits.userAgent, forHTTPHeaderField: "User-Agent")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = limits.timeout
    let delegate = ManualRedirectDelegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      // Read incrementally so a hostile server cannot force a multi-megabyte
      // allocation before we notice the response cap. Invalidating the local
      // session in `defer` stops the transfer as soon as the cap is crossed.
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw WebRuntimeError.invalidResponse }
      if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > limits.maxResponseBytes {
        throw WebRuntimeError.responseTooLarge
      }
      var data = Data()
      data.reserveCapacity(min(limits.maxResponseBytes, 64 * 1024))
      for try await byte in bytes {
        guard data.count < limits.maxResponseBytes else { throw WebRuntimeError.responseTooLarge }
        data.append(byte)
      }
      return (http, data, false)
    } catch let error as WebRuntimeError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw WebRuntimeError.timeout
    } catch {
      throw WebRuntimeError.providerFailure(error.localizedDescription)
    }
  }

  private func classify(_ contentType: String) -> WebFetchContentKind? {
    let mime = contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if mime == "text/html" || mime == "application/xhtml+xml" { return .html }
    if mime.hasPrefix("text/") || mime == "application/json" || mime == "application/xml" || mime.hasSuffix("+json") || mime.hasSuffix("+xml") { return .text }
    return nil
  }

  private func decode(_ data: Data, contentType: String) throws -> String {
    let lower = contentType.lowercased()
    if lower.contains("charset=iso-8859-1") || lower.contains("charset=windows-1252") {
      guard let value = String(data: data, encoding: .isoLatin1) else { throw WebRuntimeError.invalidResponse }
      return value
    }
    guard let value = String(data: data, encoding: .utf8) else { throw WebRuntimeError.invalidResponse }
    return value
  }

  private func isRedirect(_ statusCode: Int) -> Bool { [301, 302, 303, 307, 308].contains(statusCode) }
}

private final class ManualRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public enum WebReadableDocument {
  public struct Result: Sendable {
    public let title: String?
    public let content: String
  }

  public static func extract(fromHTML value: String) -> Result {
    let title = capture(#"(?is)<title\b[^>]*>(.*?)</title>"#, from: value).map(decodeEntities).map(normalize)
    var body = value
    for pattern in [#"(?is)<script\b[^>]*>.*?</script>"#, #"(?is)<style\b[^>]*>.*?</style>"#, #"(?is)<noscript\b[^>]*>.*?</noscript>"#, #"(?is)<svg\b[^>]*>.*?</svg>"#] {
      body = body.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
    }
    body = body.replacingOccurrences(of: #"(?i)</(p|div|section|article|main|li|h[1-6]|br)\s*>"#, with: "\n", options: .regularExpression)
    body = body.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
    return Result(title: title, content: normalize(decodeEntities(body)))
  }

  public static func normalize(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\r\\n", with: "\n")
      .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\n[ \t]*\n+"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func capture(_ pattern: String, from value: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: value) else { return nil }
    return String(value[range])
  }

  private static func decodeEntities(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
      .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
      .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
      .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
      .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
      .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
  }
}

/// Kimi's Formula-based web search adapter implemented directly in Swift.
/// It deliberately owns only model-assisted search orchestration; public page
/// retrieval remains the separately sandboxed `HTTPWebFetchProvider`.
public final class KimiOfficialWebProvider: WebSearchExecutingProvider, @unchecked Sendable {
  public let id = "kimi_official"

  private let apiKey: String
  private let baseURL: URL
  private let modelID: String
  private let session: URLSession
  private let maxRounds: Int
  private let maxResults: Int

  public init(
    apiKey: String,
    baseURL: URL,
    modelID: String,
    session: URLSession = .shared,
    maxRounds: Int = 4,
    maxResults: Int = 8
  ) {
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.baseURL = baseURL
    self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.session = session
    self.maxRounds = min(max(maxRounds, 1), 6)
    self.maxResults = min(max(maxResults, 1), 8)
  }

  public func isAvailable() async -> Bool { !apiKey.isEmpty && !modelID.isEmpty }

  public func search(_ request: WebSearchRequest) async throws -> WebSearchResult {
    guard await isAvailable() else { throw WebRuntimeError.unavailable("Kimi API Key 或模型未配置") }
    guard !request.query.isEmpty else { throw WebRuntimeError.providerFailure("web.search 缺少 query") }
    let startedAt = Date()
    let tools = try await formulaTools()
    let limit = min(request.maxResults, maxResults)
    let system = [
      "你是桌面应用的联网研究工具。",
      "在尚未获得搜索结果时，必须调用提供的 web_search 工具查询用户问题。",
      "获得工具结果后，不得再调用工具；只返回 JSON：{\"sources\":[{\"title\":\"\",\"url\":\"https://...\",\"snippet\":\"\",\"date\":\"\"}]}。",
      "只返回可验证的公开 URL，最多 \(limit) 条。",
      "没有可靠来源时返回 {\"sources\":[]}。"
    ].joined(separator: "\n")
    let initialMessages: [[String: Any]] = [
      ["role": "system", "content": system],
      ["role": "user", "content": request.query]
    ]
    var inputTokens = 0
    var outputTokens = 0
    var sawToolCall = false
    let maximumAttempts = 3
    for attempt in 0..<maximumAttempts {
      // A bounded retry starts a fresh Formula conversation. This avoids
      // repeatedly asking a reasoning model to repair an empty JSON answer in
      // the same context while keeping every request auditable and finite.
      var messages = initialMessages
      if attempt > 0 {
        messages.append([
          "role": "user",
          "content": "上一次检索没有返回可验证来源。请换一种关键词重新搜索，并继续使用 web_search；最终只返回包含真实 URL 的 JSON。"
        ])
      }

      for _ in 0..<maxRounds {
        // Formula keeps its complete tool declaration on every model turn. The
        // assistant message and Fiber result determine whether the model calls
        // it again; removing the schema after the first Fiber violates Kimi's
        // protocol and breaks real multi-turn search finalization.
        let completion = try await chatCompletion(messages: messages, tools: tools)
        let usage = dictionary(completion["usage"])
        inputTokens += integer(usage["prompt_tokens"])
        outputTokens += integer(usage["completion_tokens"])
        let choice = (completion["choices"] as? [[String: Any]])?.first ?? [:]
        let assistant = dictionary(choice["message"])
        guard !assistant.isEmpty else { throw WebRuntimeError.invalidResponse }
        let calls = assistant["tool_calls"] as? [[String: Any]] ?? []
        if calls.isEmpty {
          if !sawToolCall && attempt == 0 {
            throw WebRuntimeError.providerFailure("Kimi 官方联网未触发 web_search 工具调用")
          }
          let sources = parseSources(string(assistant["content"]))
          if !sources.isEmpty {
            return WebSearchResult(
              providerID: id,
              sources: Array(sources.prefix(limit)),
              elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
          }
          break
        }

        sawToolCall = true
        messages.append(compactAssistant(assistant))
        for call in calls {
          let function = dictionary(call["function"])
          guard string(function["name"]) == "web_search" else {
            throw WebRuntimeError.providerFailure("Kimi 官方联网返回了不支持的工具：\(string(function["name"]))")
          }
          let arguments = string(function["arguments"]).nonEmpty ?? "{}"
          let fiber = try await invokeFiber(name: "web_search", arguments: arguments)
          let context = dictionary(fiber["context"])
          let output = string(context["output"]).nonEmpty ?? string(context["encrypted_output"]).nonEmpty
          guard let output else { throw WebRuntimeError.providerFailure("Kimi 官方 Web Search 工具没有返回内容") }
          let sources = parseSources(output)
          if !sources.isEmpty {
            return WebSearchResult(
              providerID: id,
              sources: Array(sources.prefix(limit)),
              elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
          }
          messages.append([
            "role": "tool",
            "tool_call_id": string(call["id"]),
            "content": output
          ])
        }
      }
    }
    throw WebRuntimeError.providerFailure("Kimi 官方联网已执行搜索，但没有返回可验证来源。请稍后重试或更换关键词。")
  }

  private func formulaTools() async throws -> [[String: Any]] {
    let response = try await request(method: "GET", path: "formulas/moonshot/web-search:latest/tools")
    guard let tools = response["tools"] as? [[String: Any]], !tools.isEmpty else {
      throw WebRuntimeError.providerFailure("Kimi 官方联网未返回 Web Search 工具声明")
    }
    return tools
  }

  private func invokeFiber(name: String, arguments: String) async throws -> [String: Any] {
    try await request(
      method: "POST",
      path: "formulas/moonshot/web-search:latest/fibers",
      body: ["name": name, "arguments": arguments]
    )
  }

  private func chatCompletion(messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
    try await request(
      method: "POST",
      path: "chat/completions",
      body: ["model": modelID, "messages": messages, "tools": tools]
    )
  }

  private func request(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
    let url = baseURL.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 15
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw WebRuntimeError.invalidResponse }
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      guard (200..<300).contains(http.statusCode) else {
        let message = string(dictionary(object["error"])["message"]).nonEmpty ?? "HTTP \(http.statusCode)"
        throw WebRuntimeError.providerFailure(message)
      }
      return object
    } catch let error as WebRuntimeError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw WebRuntimeError.timeout
    } catch {
      throw WebRuntimeError.providerFailure(error.localizedDescription)
    }
  }

  private func compactAssistant(_ message: [String: Any]) -> [String: Any] {
    var value: [String: Any] = [
      "role": "assistant",
      "content": string(message["content"]),
      "tool_calls": message["tool_calls"] ?? []
    ]
    if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
      value["reasoning_content"] = reasoning
    }
    return value
  }

  private func parseSources(_ rawContent: String) -> [WebSource] {
    guard let opening = rawContent.firstIndex(of: "{"),
          let closing = rawContent.lastIndex(of: "}"),
          opening <= closing,
          let data = String(rawContent[opening...closing]).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
    let candidates = (object["sources"] as? [[String: Any]]) ?? (object["results"] as? [[String: Any]]) ?? []
    var seen: Set<String> = []
    return candidates.compactMap { candidate in
      let url = string(candidate["url"]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard (try? WebFetchPolicy.validate(url: url)) != nil, seen.insert(url).inserted else { return nil }
      return WebSource(
        title: string(candidate["title"]).nonEmpty ?? url,
        url: url,
        snippet: string(candidate["snippet"]).nonEmpty ?? string(candidate["description"]),
        publishedAt: string(candidate["date"]).nonEmpty ?? string(candidate["publishedAt"]).nonEmpty
      )
    }
  }

  private func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
  private func string(_ value: Any?) -> String { value as? String ?? "" }
  private func integer(_ value: Any?) -> Int { value as? Int ?? 0 }
}

/// Direct Brave Search adapter.  It is intentionally a Search-only provider;
/// all result pages still go through the common safe HTTP Fetch provider.
public final class BraveWebSearchProvider: WebSearchExecutingProvider, @unchecked Sendable {
  public let id = "brave"
  private let apiKey: String
  private let endpoint: URL
  private let session: URLSession

  public init(apiKey: String, endpoint: URL, session: URLSession = .shared) {
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.endpoint = endpoint
    self.session = session
  }

  public func isAvailable() async -> Bool { !apiKey.isEmpty }

  public func search(_ request: WebSearchRequest) async throws -> WebSearchResult {
    guard await isAvailable() else { throw WebRuntimeError.unavailable("Brave Search API Key 未配置") }
    guard !request.query.isEmpty else { throw WebRuntimeError.providerFailure("web.search 缺少 query") }
    let startedAt = Date()
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    var items = components?.queryItems ?? []
    items += [
      URLQueryItem(name: "q", value: request.query),
      URLQueryItem(name: "count", value: String(request.maxResults))
    ]
    if let language = request.language { items.append(URLQueryItem(name: "search_lang", value: language)) }
    components?.queryItems = items
    guard let url = components?.url else { throw WebRuntimeError.invalidURL(endpoint.absoluteString) }
    var urlRequest = URLRequest(url: url)
    urlRequest.timeoutInterval = 15
    urlRequest.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await session.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse else { throw WebRuntimeError.invalidResponse }
      guard (200..<300).contains(http.statusCode) else { throw WebRuntimeError.providerFailure("Brave Search HTTP \(http.statusCode)") }
      let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      let web = object["web"] as? [String: Any] ?? [:]
      let values = web["results"] as? [[String: Any]] ?? []
      let sources = values.compactMap { value -> WebSource? in
        let url = value["url"] as? String ?? ""
        guard (try? WebFetchPolicy.validate(url: url)) != nil else { return nil }
        return WebSource(
          title: (value["title"] as? String)?.nonEmpty ?? url,
          url: url,
          snippet: value["description"] as? String ?? "",
          publishedAt: value["age"] as? String
        )
      }
      return WebSearchResult(providerID: id, sources: sources, elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000))
    } catch let error as WebRuntimeError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw WebRuntimeError.timeout
    } catch {
      throw WebRuntimeError.providerFailure(error.localizedDescription)
    }
  }
}

/// Adapter for an explicitly configured self-hosted SearxNG endpoint.
public final class SearxNGWebSearchProvider: WebSearchExecutingProvider, @unchecked Sendable {
  public let id = "searxng"
  private let endpoint: URL
  private let session: URLSession

  public init(endpoint: URL, session: URLSession = .shared) {
    self.endpoint = endpoint
    self.session = session
  }

  public func isAvailable() async -> Bool { endpoint.scheme == "https" || endpoint.scheme == "http" }

  public func search(_ request: WebSearchRequest) async throws -> WebSearchResult {
    guard !request.query.isEmpty else { throw WebRuntimeError.providerFailure("web.search 缺少 query") }
    let startedAt = Date()
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    var items = components?.queryItems ?? []
    items += [
      URLQueryItem(name: "q", value: request.query),
      URLQueryItem(name: "format", value: "json")
    ]
    if let language = request.language { items.append(URLQueryItem(name: "language", value: language)) }
    if let freshness = request.freshness, freshness != "any" { items.append(URLQueryItem(name: "time_range", value: freshness)) }
    components?.queryItems = items
    guard let url = components?.url else { throw WebRuntimeError.invalidURL(endpoint.absoluteString) }
    var urlRequest = URLRequest(url: url)
    urlRequest.timeoutInterval = 15
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await session.data(for: urlRequest)
      guard let http = response as? HTTPURLResponse else { throw WebRuntimeError.invalidResponse }
      guard (200..<300).contains(http.statusCode) else { throw WebRuntimeError.providerFailure("SearxNG HTTP \(http.statusCode)") }
      let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      let values = object["results"] as? [[String: Any]] ?? []
      let sources = values.compactMap { value -> WebSource? in
        let url = value["url"] as? String ?? ""
        guard (try? WebFetchPolicy.validate(url: url)) != nil else { return nil }
        return WebSource(
          title: (value["title"] as? String)?.nonEmpty ?? url,
          url: url,
          snippet: value["content"] as? String ?? "",
          publishedAt: (value["publishedDate"] as? String) ?? (value["published_date"] as? String)
        )
      }
      return WebSearchResult(providerID: id, sources: Array(sources.prefix(request.maxResults)), elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000))
    } catch let error as WebRuntimeError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw WebRuntimeError.timeout
    } catch {
      throw WebRuntimeError.providerFailure(error.localizedDescription)
    }
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
