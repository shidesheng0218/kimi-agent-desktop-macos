import Foundation

/// Actor-free registry of live engine process handles. During
/// `applicationWillTerminate` the run loop is already draining, so awaiting an
/// actor to reach `KimiRuntimeSupervisor.stop()` is unreliable; the app
/// delegate instead calls `terminateAll()` here, which SIGTERMs every live
/// engine synchronously.
public final class KimiEngineTerminationRegistry: @unchecked Sendable {
  public static let shared = KimiEngineTerminationRegistry()

  private let lock = NSLock()
  private var handles: [Int32: KimiProcessHandle] = [:]

  public func register(_ handle: KimiProcessHandle) {
    lock.lock()
    handles[handle.processIdentifier] = handle
    lock.unlock()
  }

  public func unregister(processIdentifier: Int32) {
    lock.lock()
    handles.removeValue(forKey: processIdentifier)
    lock.unlock()
  }

  public func terminateAll() {
    lock.lock()
    let live = Array(handles.values)
    lock.unlock()
    for handle in live where handle.isRunning {
      handle.terminate()
    }
  }
}

public struct KimiRuntimeEndpoint: Codable, Equatable, Sendable {
  public let host: String
  public let port: Int
  public let token: String

  public init(host: String = "127.0.0.1", port: Int, token: String) {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    self.host = ["127.0.0.1", "localhost", "::1"].contains(normalizedHost.lowercased()) ? normalizedHost : "127.0.0.1"
    self.port = min(max(port, 1), 65_535)
    self.token = token
  }

  public var baseURL: URL {
    URL(string: "http://\(host):\(port)")!
  }

  public var authorizationHeader: String {
    let credentials = Data("kimi:\(token)".utf8).base64EncodedString()
    return "Basic \(credentials)"
  }
}

public struct KimiRuntimeConfiguration: Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let workingDirectory: URL?
  public let environment: [String: String]
  public let endpoint: KimiRuntimeEndpoint
  public let healthTimeout: TimeInterval
  public let restartLimit: Int
  public let restartDelay: TimeInterval

  public init(
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String] = [:],
    endpoint: KimiRuntimeEndpoint,
    healthTimeout: TimeInterval = 30,
    restartLimit: Int = 3,
    restartDelay: TimeInterval = 0.5
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.endpoint = endpoint
    self.healthTimeout = min(max(healthTimeout, 1), 120)
    self.restartLimit = min(max(restartLimit, 0), 10)
    self.restartDelay = min(max(restartDelay, 0.01), 30)
  }
}

public enum KimiRuntimeError: LocalizedError, Equatable, Sendable {
  case alreadyRunning
  case notRunning
  case healthTimeout(URL)
  case invalidResponse
  case requestFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning: "后台执行引擎已在运行。"
    case .notRunning: "后台执行引擎尚未启动。"
    case let .healthTimeout(url): "后台执行引擎未在规定时间内就绪：\(url.absoluteString)"
    case .invalidResponse: "后台执行引擎返回了无效响应。"
    case let .requestFailed(message): message
    }
  }
}

/// Process-management surface an `EngineProvider` backend needs only when it
/// actually runs as a child process. An in-process backend (an SDK call with
/// no subprocess, no port to health-check) implements `EngineProvider` alone
/// and never conforms to this — `KimiAppKernel` holds it as an optional so
/// such backends aren't forced to fake a process lifecycle they don't have.
public protocol EngineProcessLifecycle: Actor {
  func snapshot() -> (state: KimiRuntimeState, endpoint: KimiRuntimeEndpoint)
  func stateChanges() -> AsyncStream<KimiRuntimeState>
  func start() throws -> KimiRuntimeEndpoint
  func stop()
  func restart() throws -> KimiRuntimeEndpoint
  func reconfigure(_ newConfiguration: KimiRuntimeConfiguration) async throws
  func waitUntilReady() async throws
}

/// Owns the embedded engine server process without exposing Process management to the
/// SwiftUI layer. The production bundle supplies the executable and runtime;
/// development may point this at a local Bun/Node command.
public actor KimiRuntimeSupervisor: EngineProcessLifecycle {
  private var configuration: KimiRuntimeConfiguration
  private var process: KimiProcessHandle?
  private var state: KimiRuntimeState = .stopped {
    didSet { publishState(state) }
  }
  /// Bumped every time `beginMonitoring` registers a termination handler for
  /// a new process. `Process.terminationHandler` fires on an arbitrary
  /// background thread and is bridged back onto the actor via `Task { ... }`,
  /// so a handler for a since-superseded process (already stopped/restarted)
  /// must be able to recognize it's stale and no-op instead of racing a
  /// newer launch's state.
  private var monitorGeneration = 0
  private var intentionalStop = false
  private var unexpectedExitRestarts = 0
  private var stateContinuations: [UUID: AsyncStream<KimiRuntimeState>.Continuation] = [:]

  public init(configuration: KimiRuntimeConfiguration) {
    self.configuration = configuration
  }

  public func snapshot() -> (state: KimiRuntimeState, endpoint: KimiRuntimeEndpoint) {
    (state, configuration.endpoint)
  }

  /// Observers (the app kernel) follow engine state transitions here so an
  /// unexpected-exit restart is visible outside this actor — previously the
  /// state simply went stale in the UI after a crash recovery.
  public func stateChanges() -> AsyncStream<KimiRuntimeState> {
    let token = UUID()
    return AsyncStream { continuation in
      continuation.yield(state)
      stateContinuations[token] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeStateContinuation(token) }
      }
    }
  }

  private func publishState(_ value: KimiRuntimeState) {
    stateContinuations.values.forEach { $0.yield(value) }
  }

  private func removeStateContinuation(_ token: UUID) {
    stateContinuations.removeValue(forKey: token)
  }

  public func start() throws -> KimiRuntimeEndpoint {
    try launch(resetRestartCount: true)
  }

  public func unexpectedExitRestartCount() -> Int {
    unexpectedExitRestarts
  }

  private func launch(resetRestartCount: Bool) throws -> KimiRuntimeEndpoint {
    guard process?.isRunning != true else { throw KimiRuntimeError.alreadyRunning }
    if resetRestartCount { unexpectedExitRestarts = 0 }
    intentionalStop = false
    state = .starting
    let command = KimiCommand(executableURL: configuration.executableURL, arguments: configuration.arguments)
    do {
      process = try KimiProcessRunner.start(
        command,
        workingDirectory: configuration.workingDirectory,
        environment: configuration.environment
      )
      if let process {
        KimiEngineTerminationRegistry.shared.register(process)
        beginMonitoring(process)
      }
      return configuration.endpoint
    } catch {
      state = .failed
      throw error
    }
  }

  public func markReady() {
    guard process?.isRunning == true else { return }
    state = .ready
  }

  public func markDegraded() {
    guard process?.isRunning == true else { return }
    state = .degraded
  }

  public func stop() {
    intentionalStop = true
    monitorGeneration += 1
    guard let process else {
      state = .stopped
      return
    }
    state = .stopping
    KimiEngineTerminationRegistry.shared.unregister(processIdentifier: process.processIdentifier)
    process.terminate()
    self.process = nil
    state = .stopped
  }

  public func restart() throws -> KimiRuntimeEndpoint {
    stop()
    return try start()
  }

  /// Swaps the runtime configuration (e.g. after a model change) and
  /// relaunches the engine. The endpoint is preserved so existing session
  /// clients keep working without re-handshaking.
  public func reconfigure(_ newConfiguration: KimiRuntimeConfiguration) async throws {
    stop()
    configuration = KimiRuntimeConfiguration(
      executableURL: newConfiguration.executableURL,
      arguments: newConfiguration.arguments,
      workingDirectory: newConfiguration.workingDirectory,
      environment: newConfiguration.environment,
      endpoint: configuration.endpoint,
      healthTimeout: newConfiguration.healthTimeout,
      restartLimit: newConfiguration.restartLimit,
      restartDelay: newConfiguration.restartDelay
    )
    _ = try start()
    try await waitUntilReady()
  }

  public func waitUntilReady() async throws {
    guard process?.isRunning == true else { throw KimiRuntimeError.notRunning }
    let deadline = Date().addingTimeInterval(configuration.healthTimeout)
    while Date() < deadline {
      if await Self.isHealthy(configuration.endpoint) {
        state = .ready
        return
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    state = .degraded
    throw KimiRuntimeError.healthTimeout(configuration.endpoint.baseURL)
  }

  private static func isHealthy(_ endpoint: KimiRuntimeEndpoint) async -> Bool {
    for path in ["/global/health", "/api/health"] {
      guard let url = URL(string: path, relativeTo: endpoint.baseURL)?.absoluteURL else { continue }
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
      request.timeoutInterval = 2
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
          return true
        }
      } catch {}
    }
    return false
  }

  /// Replaces a 50ms busy-poll with `Process.terminationHandler`: the OS
  /// notifies us exactly when the process dies instead of us asking
  /// repeatedly. The handler fires on an arbitrary background thread, so it
  /// only captures the generation token and hops back onto the actor via
  /// `Task` before touching any actor-isolated state.
  private func beginMonitoring(_ handle: KimiProcessHandle) {
    monitorGeneration += 1
    let generation = monitorGeneration
    let pid = handle.processIdentifier
    handle.onTermination { [weak self] _ in
      Task { [weak self] in
        await self?.handleUnexpectedExit(processID: pid, generation: generation)
      }
    }
  }

  private func handleUnexpectedExit(processID: Int32, generation: Int) async {
    // A termination handler for a process this supervisor has since moved
    // past (stopped, or already relaunched into a newer generation) must
    // no-op rather than race the current state.
    guard generation == monitorGeneration else { return }
    guard let current = process, current.processIdentifier == processID else { return }
    guard !intentionalStop else { return }
    KimiEngineTerminationRegistry.shared.unregister(processIdentifier: processID)
    guard unexpectedExitRestarts < configuration.restartLimit else {
      state = .failed
      return
    }
    unexpectedExitRestarts += 1
    state = .starting
    try? await Task.sleep(for: .seconds(configuration.restartDelay))
    guard generation == monitorGeneration, !intentionalStop else { return }
    do {
      _ = try launch(resetRestartCount: false)
      // A relaunched engine must prove health before observers see `ready`;
      // otherwise the state would sit in `.starting` forever and the UI
      // would never re-subscribe to the event stream.
      try await waitUntilReady()
    } catch {
      state = .failed
    }
  }
}
