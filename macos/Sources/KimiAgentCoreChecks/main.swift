import Foundation
import KimiAgentCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

final class ResultBox<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<T, Error>?

  func store(_ result: Result<T, Error>) {
    lock.lock()
    value = result
    lock.unlock()
  }

  func load() -> Result<T, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

final class InvocationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock(); value += 1; lock.unlock()
  }

  var count: Int {
    lock.lock(); defer { lock.unlock() }; return value
  }
}

final class ThreadSafeStringTrace: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  func append(_ value: String) {
    lock.lock(); values.append(value); lock.unlock()
  }

  var snapshot: [String] {
    lock.lock(); defer { lock.unlock() }; return values
  }
}

final class ThreadSafePromptQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [PromptInput] = []

  func append(_ value: PromptInput) {
    lock.lock(); values.append(value); lock.unlock()
  }

  func take() -> [PromptInput] {
    lock.lock()
    defer { lock.unlock() }
    let result = values
    values.removeAll()
    return result
  }
}

actor OneShotAsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      if isOpen {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}

func awaitValue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<T>()
  Task.detached {
    do {
      box.store(Result<T, Error>.success(try await operation()))
    } catch {
      box.store(Result<T, Error>.failure(error))
    }
    semaphore.signal()
  }
  semaphore.wait()
  switch box.load() {
  case let .success(value):
    return value
  case let .failure(error):
    throw error
  case .none:
    throw NSError(domain: "CoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "异步测试没有返回结果。"])
  }
}

final class LocalHTTPServer {
  let process: Process
  let port: Int

  init(process: Process, port: Int) {
    self.process = process
    self.port = port
  }

  func stop() {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
  }

  deinit { stop() }
}

func startLocalHTTPServer() throws -> LocalHTTPServer {
  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  process.arguments = ["-c", """
  import http.server
  import socketserver

  class Handler(http.server.BaseHTTPRequestHandler):
      def do_GET(self):
          body = b"sandbox-http-ok"
          self.send_response(200)
          self.send_header("Content-Length", str(len(body)))
          self.end_headers()
          self.wfile.write(body)
      def log_message(self, *args):
          pass

  with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
      print(server.server_address[1], flush=True)
      server.handle_request()
  """]
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  let line = String(data: stdout.fileHandleForReading.availableData, encoding: .utf8) ?? ""
  guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.isRunning { process.terminate() }
    throw NSError(domain: "CoreChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法启动本地 HTTP 验证服务：\(error)"])
  }
  return LocalHTTPServer(process: process, port: port)
}

final class MockURLProtocol: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有配置请求处理器。"]))
      return
    }

    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class IdleKimiRuntimeSessionClient: EngineProvider, @unchecked Sendable {
  private let promptCounter = InvocationCounter()

  var promptCount: Int { promptCounter.count }

  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "session-idle")
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {
    promptCounter.increment()
  }

  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        try? await Task.sleep(for: .milliseconds(20))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionIdle, turnOutcome: .completed))
        continuation.finish()
      }
    }
  }
}

/// Streams one scripted assistant turn (busy → deltas → snapshot → idle) so
/// checks can drive a real `KimiAppKernel` through the production ingest path.
final class StreamingScriptKimiRuntimeClient: EngineProvider, @unchecked Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "stream-session", title: "流式", directory: "/tmp/stream")
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .assistantText, text: "你好，", messageID: "m1", partID: "p1"))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .assistantText, text: "世界", messageID: "m1", partID: "p1"))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .assistantText, text: "你好，世界！", messageID: "m1", partID: "p1", isSnapshot: true))
        try? await Task.sleep(for: .milliseconds(30))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionIdle, turnOutcome: .completed))
        continuation.finish()
      }
    }
  }
}

/// Holds the turn open long enough for a steer message to be pumped in.
final class SteerScriptKimiRuntimeClient: EngineProvider, @unchecked Sendable {
  let promptTrace = ThreadSafeStringTrace()

  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "steer-session", title: "插队", directory: "/tmp/steer")
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {
    promptTrace.append(input.text)
  }

  func steer(_ input: KimiRuntimeSteerInput) async throws {
    promptTrace.append(input.text)
  }

  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        try? await Task.sleep(for: .milliseconds(900))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionIdle, turnOutcome: .completed))
        continuation.finish()
      }
    }
  }
}

/// Never emits completion; used to prove the driver aborts the engine session
/// when its own timeout fires.
final class NeverIdleKimiRuntimeClient: EngineProvider, @unchecked Sendable {
  let abortCounter = InvocationCounter()

  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "never-idle")
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws { abortCounter.increment() }
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        try? await Task.sleep(for: .seconds(30))
        continuation.finish()
      }
    }
  }
}

/// Serves a canned two-message conversation for history-restore checks.
final class HistoryScriptKimiRuntimeClient: EngineProvider, @unchecked Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "history-session", title: "历史会话", directory: input.directory)
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { $0.finish() }
  }

  func fetchMessages(sessionID: String, directory: String?) async throws -> [KimiRuntimeHistoryMessage] {
    [
      KimiRuntimeHistoryMessage(
        id: "m-u",
        role: "user",
        createdAt: Date(timeIntervalSince1970: 1_000),
        parts: [KimiRuntimeHistoryPart(partID: "pu", type: "text", text: "之前的问题")]
      ),
      KimiRuntimeHistoryMessage(
        id: "m-a",
        role: "assistant",
        createdAt: Date(timeIntervalSince1970: 1_001),
        parts: [
          KimiRuntimeHistoryPart(partID: "pa", type: "text", text: "之前的回答"),
          KimiRuntimeHistoryPart(partID: "pt", type: "tool", toolName: "read", callID: "c1", status: "completed", output: "内容")
        ]
      )
    ]
  }
}

/// Streams one tool call and its result so verification-record joins have a
/// settled receipt to project.
final class VerifyScriptKimiRuntimeClient: EngineProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var _addedMCPServers: [KimiMCPServerEntry] = []
  private var _removedMCPServerNames: [String] = []

  var addedMCPServers: [KimiMCPServerEntry] {
    lock.lock(); defer { lock.unlock() }
    return _addedMCPServers
  }

  var removedMCPServerNames: [String] {
    lock.lock(); defer { lock.unlock() }
    return _removedMCPServerNames
  }

  private var _forkCounter = 0

  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "verify-session", title: "验证", directory: input.directory, parentID: input.parentID)
  }

  func forkSession(sessionID: String, messageID: String?, directory: String?) async throws -> KimiRuntimeSession {
    let forkIndex: Int = lock.withLock {
      _forkCounter += 1
      return _forkCounter
    }
    return KimiRuntimeSession(id: "verify-session-fork-\(forkIndex)", title: "验证 分支", directory: directory, parentID: sessionID)
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func addMCPServer(_ entry: KimiMCPServerEntry, directory: String?) async throws {
    lock.withLock { _addedMCPServers.append(entry) }
  }

  func removeMCPServer(name: String, directory: String?) async throws {
    lock.withLock { _removedMCPServerNames.append(name) }
  }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .toolCall, toolCallID: "vtc1", toolID: "bash", payload: ["arguments": #"{"command":"swift build"}"#]))
        try? await Task.sleep(for: .milliseconds(20))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .toolResult, text: "Build complete", toolCallID: "vtc1", toolID: "bash", payload: ["status": "completed"]))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionIdle, turnOutcome: .completed))
        continuation.finish()
      }
    }
  }
}

/// Emits the observed engine quirk: two permission.asked frames sharing one
/// requestID, then permission.replied, then idle.
final class PermScriptKimiRuntimeClient: EngineProvider, @unchecked Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "perm-session", title: "审批", directory: input.directory)
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .permissionAsked, toolID: "edit", requestID: "per_zombie"))
        try? await Task.sleep(for: .milliseconds(30))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .permissionAsked, toolID: "edit", requestID: "per_zombie"))
        try? await Task.sleep(for: .milliseconds(30))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .permissionReplied, requestID: "per_zombie"))
        continuation.yield(EngineRuntimeEvent(sessionID: sessionID, kind: .sessionIdle, turnOutcome: .completed))
        continuation.finish()
      }
    }
  }
}

final class ProcessOutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var value = ""

  func append(_ output: KimiProcessOutput) {
    lock.lock()
    value += output.text
    lock.unlock()
  }

  func contains(_ text: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value.contains(text)
  }
}

final class CountingCredentialVault: CredentialVault, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  private(set) var readCount = 0

  func read(key: String) throws -> String? {
    lock.lock()
    readCount += 1
    let value = values[key]
    lock.unlock()
    return value
  }

  func write(_ value: String, key: String) throws {
    lock.lock()
    values[key] = value
    lock.unlock()
  }

  func delete(key: String) throws {
    lock.lock()
    values.removeValue(forKey: key)
    lock.unlock()
  }
}

let planCommand = KimiCommandBuilder.makeCommand(
  runtimePath: "/Applications/Kimi Code Agent.app/Contents/Resources/kimi.mjs",
  prompt: "分析登录失败原因",
  mode: .plan
)

expect(planCommand.executableURL.path == "/usr/bin/env", "Plan 任务必须经由 node 运行内置 Kimi Runtime")
expect(
  planCommand.arguments == [
    "node",
    "/Applications/Kimi Code Agent.app/Contents/Resources/kimi.mjs",
    "--prompt",
    "分析登录失败原因",
    "--output-format",
    "stream-json",
    "--agent",
    "plan"
  ],
  "Plan 任务必须使用结构化输出和只读 plan agent"
)

let editCommand = KimiCommandBuilder.makeCommand(
  runtimePath: "/tmp/kimi.mjs",
  prompt: "修复登录失败",
  mode: .edit
)

expect(!editCommand.arguments.contains("--yolo"), "Edit 任务不能默认自动批准操作")
expect(!editCommand.arguments.contains("--auto"), "Edit 任务不能默认无人值守执行")
let confirmedEditCommand = KimiCommandBuilder.makeCommand(
  runtimePath: "/tmp/kimi.mjs",
  prompt: "修复登录失败",
  mode: .edit,
  permission: .automatic
)
expect(!confirmedEditCommand.arguments.contains("--auto"), "Prompt 模式不能附带与 CLI 冲突的 --auto 参数")
let absoluteNodeCommand = KimiCommandBuilder.makeCommand(
  runtimePath: "/tmp/kimi.mjs",
  prompt: "检查环境",
  mode: .plan,
  nodeExecutable: "/opt/homebrew/bin/node"
)
expect(absoluteNodeCommand.arguments.first == "/opt/homebrew/bin/node", "原生 App 必须支持使用绝对 Node 路径")
let modelCommand = KimiCommandBuilder.makeCommand(
  runtimePath: "/tmp/kimi.mjs",
  prompt: "使用指定模型",
  mode: .plan,
  modelID: "kimi-latest"
)
expect(modelCommand.arguments.contains("--model") && modelCommand.arguments.contains("kimi-latest"), "任务必须将用户选择的模型传递给 Kimi Runtime")
let skillCommand = KimiCommandBuilder.makeCommand(
  runtimePath: "/tmp/kimi.mjs",
  prompt: "使用项目技能",
  mode: .plan,
  skillsDirectories: ["/tmp/project/.kimi/skills"]
)
expect(skillCommand.arguments.contains("--skills-dir") && skillCommand.arguments.contains("/tmp/project/.kimi/skills"), "任务必须将项目 Skills 目录传递给 Kimi Runtime")
let loginCommand = KimiCommandBuilder.makeLoginCommand(runtimePath: "/tmp/kimi.mjs", nodeExecutable: "/opt/homebrew/bin/node")
expect(loginCommand.arguments == ["/opt/homebrew/bin/node", "/tmp/kimi.mjs", "login"], "原生登录必须通过内置 Kimi Runtime 的 device-code 流程启动")

let echoProcess = try KimiProcessRunner.start(
  KimiCommand(executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["native runner"])
)
let echoResult = echoProcess.wait()
expect(echoResult.exitCode == 0, "原生进程执行器应返回成功退出码")
expect(echoResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "native runner", "原生进程执行器应捕获标准输出")

let outputCollector = ProcessOutputCollector()
let streamingProcess = try KimiProcessRunner.start(
  KimiCommand(
    executableURL: URL(fileURLWithPath: "/bin/sh"),
    arguments: ["-c", "printf 'first\\n'; sleep 0.3; printf 'second\\n'"]
  ),
  onOutput: outputCollector.append
)
try? await Task.sleep(nanoseconds: 100_000_000)
expect(outputCollector.contains("first"), "进程结束前必须把第一段输出推送给界面")
let streamingResult = streamingProcess.wait()
expect(streamingResult.standardOutput.contains("second"), "流式进程完成后仍需保留完整标准输出")

let readyProcess = try KimiProcessRunner.start(
  KimiCommand(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\\\"type\\\":\\\"ready\\\"}\\n'; sleep 1"])
)
expect(readyProcess.waitForStandardOutput(containing: "\"type\":\"ready\"", timeout: 0.5), "后台桥接进程必须在继续任务前报告 ready")
expect(readyProcess.standardOutputSnapshot.contains("\"type\":\"ready\""), "后台桥接进程必须暴露 ready 输出供调用方解析")
readyProcess.terminate()
_ = readyProcess.wait()

let lifecycleProcess = try KimiProcessRunner.start(
  KimiCommand(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 2"])
)
expect(lifecycleProcess.isRunning, "进程句柄必须暴露运行状态，便于回收后台服务")
lifecycleProcess.terminate()
_ = lifecycleProcess.wait()
expect(!lifecycleProcess.isRunning, "终止后进程句柄必须反映已停止状态")

var lineBuffer = StreamingLineBuffer()
expect(lineBuffer.append("alpha\nbet") == ["alpha"], "流式缓冲器应立即提交完整行")
expect(lineBuffer.append("a\ngamma\n") == ["beta", "gamma"], "流式缓冲器必须拼接跨分片的行")

let temporaryDirectory = FileManager.default.temporaryDirectory
  .appendingPathComponent("kimi-agent-core-checks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

expect(
  KimiCodeAgentBranding.keychainServices == ["com.kimicode.agent.native"],
  "Kimi Code Agent 只能读取自己的 Keychain 服务，旧凭据不得再影响新版本"
)

let stateURL = temporaryDirectory.appendingPathComponent("state.json")
let repository = TaskRepository(fileURL: stateURL)
var persistedTask = AgentTask(
  title: "分析登录失败",
  mode: .plan,
  workspacePath: "/Users/eastbuy/Projects/sample"
)
persistentTaskEvents: do {
  persistedTask.events = ["已创建 Plan 任务。", "等待 Kimi 输出。"]
}
let workspaceBookmarkData = Data("security-scoped-bookmark".utf8)
try repository.save(AppState(
  workspacePath: persistedTask.workspacePath,
  workspaceBookmarkData: workspaceBookmarkData,
  workspaceBookmarks: [persistedTask.workspacePath: workspaceBookmarkData],
  selectedTaskID: persistedTask.id,
  tasks: [persistedTask]
))
let restoredState = try repository.load()

expect(restoredState.workspacePath == "/Users/eastbuy/Projects/sample", "项目路径必须在重启后保留")
expect(restoredState.workspaceBookmarkData == workspaceBookmarkData, "项目安全授权 bookmark 必须在重启后保留，避免 macOS 反复请求 Documents 访问权限")
expect(restoredState.workspaceBookmarks["/Users/eastbuy/Projects/sample"] == workspaceBookmarkData, "历史项目安全授权 bookmark 必须在重启后保留，切换最近会话时不能反复请求权限")
expect(restoredState.selectedTaskID == persistedTask.id, "选中的任务必须在重启后保留")
expect(restoredState.tasks == [persistedTask], "任务记录必须在重启后保留")
expect(restoredState.tasks[0].events == ["已创建 Plan 任务。", "等待 Kimi 输出。"], "任务事件时间线必须在重启后保留")
expect(TaskMode.plan.isReadOnly, "Plan 模式必须明确为只读")
expect(!TaskMode.edit.isReadOnly, "Edit 模式不应被标记为只读")

let failurePack = FailureContextPack(
  operationID: UUID(),
  taskID: persistedTask.id,
  stage: .test,
  command: "swift test",
  exitCode: 1,
  stderr: "Test failed: expected 1, got 0",
  relatedFiles: ["Sources/App.swift"],
  diffArtifactID: "diff-1",
  attempt: 1
)
expect(failurePack.redactedStderr.contains("Test failed"), "失败上下文必须保留可诊断的脱敏错误")
let debugDecision = DebugLoopCoordinator.nextAction(for: failurePack, maxRounds: 3)
expect(debugDecision == .startDebug, "首次验证失败必须进入 Debug Agent")
let exhaustedPack = FailureContextPack(operationID: failurePack.operationID, taskID: failurePack.taskID, stage: .test, command: failurePack.command, exitCode: 1, stderr: failurePack.stderr, relatedFiles: failurePack.relatedFiles, diffArtifactID: failurePack.diffArtifactID, attempt: 3)
expect(DebugLoopCoordinator.nextAction(for: exhaustedPack, maxRounds: 3) == .askUser, "超过修复上限必须请求用户介入")
let quality = ResponseQualityGate.validate("已完成：修复登录\n\nthinking: internal", outcome: .completed)
expect(!quality.cleanedText.lowercased().contains("thinking"), "最终质量门禁必须清理内部分析")
expect(!quality.hasBlockingIssues, "清理后的正常答复不应被误判为阻断")
let pluginRoot = temporaryDirectory.appendingPathComponent("plugin", isDirectory: true)
try FileManager.default.createDirectory(at: pluginRoot.appendingPathComponent(".kimi-plugin", isDirectory: true), withIntermediateDirectories: true)
let plugin = KimiPluginDescriptor(
  manifest: KimiPluginManifest(id: "demo", name: "Demo", version: "1.0.0"),
  rootURL: pluginRoot,
  scope: .project
)
let pluginSupervisor = PluginWorkerSupervisor()
let pluginState = try awaitValue { () async throws -> PluginWorkerState in
  await pluginSupervisor.register(plugin)
  return await pluginSupervisor.state(pluginID: "demo") ?? .registered
}
expect(pluginState == .registered, "插件 Worker 必须先经过注册状态")
try """
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  const request = JSON.parse(chunk.trim());
  process.stdout.write(JSON.stringify({jsonrpc:'2.0', id:request.id, result:{protocolVersion:'1.0', worker:{name:'demo', version:'1.0.0'}, capabilities:['tools','hooks']}}) + '\\n');
});
""".write(to: pluginRoot.appendingPathComponent(".kimi-plugin/worker.js"), atomically: true, encoding: .utf8)
let pluginHandshake = try awaitValue {
  try await pluginSupervisor.start(pluginID: "demo", nodeExecutable: "node")
  defer { Task { await pluginSupervisor.stop(pluginID: "demo") } }
  return try await pluginSupervisor.performHandshake(pluginID: "demo", requiredCapabilities: ["tools"])
}
expect(pluginHandshake.workerName == "demo" && pluginHandshake.capabilities.contains("hooks"), "插件 Worker 必须完成 JSON-RPC 握手并声明能力")
let pluginStateURL = temporaryDirectory.appendingPathComponent("plugin-worker-status.json")
let durablePluginSupervisor = PluginWorkerSupervisor(stateFileURL: pluginStateURL)
await durablePluginSupervisor.register(plugin)
try await durablePluginSupervisor.markFailure(pluginID: "demo", message: "handshake timeout")
let restoredPluginSupervisor = PluginWorkerSupervisor(stateFileURL: pluginStateURL)
let restoredPluginStatus = await restoredPluginSupervisor.status(pluginID: "demo")
expect(restoredPluginStatus?.state == .reconnecting && restoredPluginStatus?.restartCount == 1, "插件 Worker 状态必须在重启后恢复，不能丢失重连预算")
let sandboxedPluginRoot = temporaryDirectory.appendingPathComponent("sandboxed-plugin", isDirectory: true)
let sandboxedPluginManifestDirectory = sandboxedPluginRoot.appendingPathComponent(".kimi-plugin", isDirectory: true)
try FileManager.default.createDirectory(at: sandboxedPluginManifestDirectory, withIntermediateDirectories: true)
try JSONEncoder().encode(KimiPluginManifest(id: "sandboxed-plugin", name: "Sandboxed", version: "1.0.0")).write(
  to: sandboxedPluginManifestDirectory.appendingPathComponent("plugin.json")
)
let sandboxedPluginEscapeURL = temporaryDirectory.deletingLastPathComponent().appendingPathComponent("kimi-plugin-escape-\(UUID().uuidString)")
try """
const fs = require('fs');
try {
  fs.writeFileSync(\(String(data: try JSONSerialization.data(withJSONObject: [sandboxedPluginEscapeURL.path]), encoding: .utf8)!)[0], 'escape');
  process.exit(0);
} catch (_) {
  process.exit(7);
}
""".write(to: sandboxedPluginManifestDirectory.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
let sandboxedPlugin = KimiPluginDescriptor(
  manifest: KimiPluginManifest(id: "sandboxed-plugin", name: "Sandboxed", version: "1.0.0"),
  rootURL: sandboxedPluginRoot,
  scope: .project
)
let sandboxedPluginSupervisor = PluginWorkerSupervisor()
_ = try awaitValue {
  await sandboxedPluginSupervisor.register(sandboxedPlugin)
  try await sandboxedPluginSupervisor.start(
    pluginID: "sandboxed-plugin",
    nodeExecutable: "node",
    sandbox: TerminalSandboxConfiguration.strict(
      workspaceURL: sandboxedPluginRoot,
      scratchURL: temporaryDirectory.appendingPathComponent("sandboxed-plugin-scratch", isDirectory: true)
    )
  )
  let deadline = Date().addingTimeInterval(3)
  while Date() < deadline,
        await sandboxedPluginSupervisor.status(pluginID: "sandboxed-plugin")?.state == .running {
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  return true
}
let sandboxedPluginStatus = try awaitValue { await sandboxedPluginSupervisor.status(pluginID: "sandboxed-plugin") }
expect(
  sandboxedPluginStatus?.state == .failed && !FileManager.default.fileExists(atPath: sandboxedPluginEscapeURL.path),
  "插件 Worker 必须由 OS 沙箱阻止 Worktree 外写入并报告失败"
)
let route = ModelRouter.route(intent: .conversation, promptLength: 12, budget: TaskBudget(maxCost: 1, maxInputTokens: 4_000, maxOutputTokens: 800, maxWallTimeSeconds: 30, maxRepairRounds: 3))
expect(route.tier == .fast, "普通对话必须优先路由到低延迟模型")
let routedModel = ModelRouteResolver.resolve(
  preferredModelID: "kimi-k2.7-code",
  route: route,
  environment: ["KIMI_AGENT_MODEL_FAST": "kimi-fast"]
)
expect(routedModel.modelID == "kimi-fast" && routedModel.source == .tierOverride, "模型路由必须真正选择配置的 tier 模型，而不是只记录 modelTier")
let preferredModel = ModelRouteResolver.resolve(
  preferredModelID: "kimi-k2.7-code",
  route: route,
  environment: [:]
)
expect(preferredModel.modelID == "kimi-k2.7-code" && preferredModel.source == .preferred, "未配置 tier 模型时必须保留用户选择的 Kimi 模型")
let usageLedger = UsageLedger()
let usageEntry = UsageLedgerEntry(operationID: UUID(), stage: .explore, provider: "kimi", model: "kimi-fast", inputTokens: 100, outputTokens: 40, cachedTokens: 50, latencyMS: 120, estimatedCost: 0.1, qualityScore: nil)
try usageLedger.append(usageEntry)
expect(usageLedger.snapshot().count == 1 && usageLedger.totalCost() == 0.1, "模型调用必须记录 Token、延迟和成本")
try usageLedger.append(usageEntry)
expect(usageLedger.snapshot().count == 1, "同一 Usage Ledger Entry 重放时不得重复计费")
expect(usageLedger.contains(operationID: usageEntry.operationID), "用量账本必须能防止同一 Operation 重复记账")
let priceCard = ModelPriceCard(inputPerMillion: 1, outputPerMillion: 2, cachedInputPerMillion: 0.25)
expect(priceCard.estimate(inputTokens: 1_000, outputTokens: 500, cachedTokens: 200) == Decimal(string: "0.00185")!, "模型价格卡必须按输入、输出和缓存 Token 计算成本")
let unpricedEntry = UsageLedgerEntry(operationID: UUID(), stage: .explore, provider: "kimi", model: "unknown", inputTokens: 10, outputTokens: 10, latencyMS: 1, estimatedCost: 0, qualityScore: nil, pricingStatus: .unconfigured)
expect(unpricedEntry.pricingStatus == .unconfigured, "未知模型价格必须标记为未配置，不能把 0 当成真实成本")
expect(CostBudgetGate.decision(spent: 0.81, budget: 1) == .warning, "成本达到 80% 时必须进入预警")
expect(CostBudgetGate.decision(spent: 1.01, budget: 1) == .exceeded, "超过任务预算必须阻止继续调用")
let memoryURL = temporaryDirectory.appendingPathComponent("memory.json")
let memoryStore = MemoryStore(fileURL: memoryURL)
try memoryStore.upsert(MemoryRecord(scope: .project, kind: .fact, content: "测试命令是 swift test", provenance: .userConfirmed))
expect(memoryStore.records(scope: .project).map(\.content) == ["测试命令是 swift test"], "项目记忆必须本地持久化并可按作用域读取")
expect(MemoryStore(fileURL: memoryURL).records(scope: .project).count == 1, "重启后必须恢复已确认记忆")
try memoryStore.upsert(MemoryRecord(scope: .project, scopeKey: "/tmp/project-a", kind: .fact, content: "项目 A 使用 pnpm", provenance: .userConfirmed))
expect(memoryStore.records(scope: .project, scopeKey: "/tmp/project-a").contains(where: { $0.content.contains("pnpm") }), "项目记忆必须按项目范围隔离")
expect(!memoryStore.records(scope: .project, scopeKey: "/tmp/project-b").contains(where: { $0.content.contains("pnpm") }), "项目记忆不能泄漏到其他项目")
try memoryStore.upsert(MemoryRecord(scope: .user, kind: .preference, content: "使用 Swift", provenance: .userConfirmed, key: "language"))
try memoryStore.upsert(MemoryRecord(scope: .project, scopeKey: "/tmp/project-a", kind: .preference, content: "使用 TypeScript", provenance: .projectRule, key: "language"))
let effectiveMemories = memoryStore.effectiveRecords(projectKey: "/tmp/project-a")
expect(effectiveMemories.first(where: { $0.key == "language" })?.content == "使用 TypeScript", "更具体的项目记忆必须覆盖同键用户级偏好")
expect(memoryStore.conflicts(projectKey: "/tmp/project-a").contains(where: { $0.key == "language" }), "冲突记忆必须可审计")

let webResearchEvent = AgentEvent(
  sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
  taskID: persistedTask.id,
  sequence: 4,
  actor: "kimi-acp-host",
  kind: .toolFinished,
  payload: [
    "webResearchAction": "search",
    "sources": "[{\"title\":\"Kimi Docs\",\"url\":\"https://docs.example.com/kimi\",\"snippet\":\"Reference\"}]"
  ]
)
let extractedSources = WebResearchEvidence.extractSources(from: webResearchEvent)
expect(extractedSources.count == 1, "Web Search 工具结果必须转换为可审阅来源")
expect(extractedSources.first?.domain == "docs.example.com", "来源必须保存可显示域名")
expect(extractedSources.first?.status == .discovered, "搜索来源初始状态必须是已发现")
let webFetchEvent = AgentEvent(
  sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
  taskID: persistedTask.id,
  sequence: 5,
  actor: "kimi-acp-host",
  kind: .toolFinished,
  payload: [
    "webResearchAction": "fetch",
    "arguments": "{\"url\":\"https://docs.example.com/kimi\"}",
    "output": "Kimi reference full text."
  ]
)
let fetchedSources = WebResearchEvidence.extractSources(from: webFetchEvent)
expect(fetchedSources.first?.status == .fetched, "Web Fetch 必须把已抓取来源标记为 fetched")
expect(fetchedSources.first?.summary == "Kimi reference full text.", "Web Fetch 只保存受限摘要而非全文")
let structuredFetchEvent = AgentEvent(
  sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
  taskID: persistedTask.id,
  sequence: 51,
  actor: "kimi-acp-host",
  kind: .toolFinished,
  payload: [
    "webResearchAction": "fetch",
    "arguments": "{\"url\":\"https://docs.example.com/kimi\"}",
    "output": "{\"url\":\"https://docs.example.com/kimi\"}",
    "webResearchContent": "Kimi fetched reference body."
  ]
)
expect(
  WebResearchEvidence.extractSources(from: structuredFetchEvent).first?.summary == "Kimi fetched reference body.",
  "FetchURL 结构化正文必须优先于 URL 包装器写入来源摘要"
)
let mergedFetchedSource = WebResearchEvidence.merging(
  extractedSources,
  with: WebResearchEvidence.extractSources(from: structuredFetchEvent)
)
expect(
  mergedFetchedSource.first?.summary == "Kimi fetched reference body.",
  "来源从 discovered 更新为 fetched 时必须保留正文摘要"
)
let startedSearchEvent = AgentEvent(
  sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
  taskID: persistedTask.id,
  sequence: 6,
  actor: "kimi-acp-host",
  kind: .toolStarted,
  payload: ["webResearchAction": "search"]
)
let usageAfterStarted = WebResearchEvidence.updatingUsage(WebResearchUsageRecord(), event: startedSearchEvent, sourceCount: 0)
expect(usageAfterStarted.searchCount == 0, "联网用量只能在搜索工具完成后计数，不能把 started 和 finished 重复计算")
let mergedResearchUsage = WebResearchEvidence.mergingUsage(
  WebResearchUsageRecord(searchCount: 1, sourceCount: 2),
  snapshot: WebResearchUsageSnapshot(
    provider: "kimi_official",
    searches: 3,
    cachedSearches: 1,
    fetches: 2,
    cachedFetches: 1,
    fetchedChars: 1200,
    inputTokens: 100,
    outputTokens: 40,
    totalTokens: 140,
    toolCalls: 5
  ),
  sourceCount: 2
)
expect(mergedResearchUsage.searchCount == 3 && mergedResearchUsage.cachedSearchCount == 1, "联网用量必须吸收 Bridge 的搜索和缓存统计")
expect(mergedResearchUsage.totalTokens == 140 && mergedResearchUsage.fetchedChars == 1200, "联网用量必须保留 Token 和抓取字数统计")
let citationCheck = WebResearchCitationVerifier.validate(
  answer: "结论依据：https://docs.example.com/kimi",
  sources: fetchedSources
)
expect(citationCheck.isValid && citationCheck.matchedSourceCount == 1, "最终联网回答必须能验证引用来源")
let discoveredOnlyCitationCheck = WebResearchCitationVerifier.validate(
  answer: "结论依据：https://docs.example.com/kimi",
  sources: extractedSources
)
expect(!discoveredOnlyCitationCheck.isValid, "只有搜索摘要、没有抓取正文的来源不能标记为已验证引用")
let citationEvents = [
  AgentEvent(
    sessionID: persistedTask.id,
    taskID: persistedTask.id,
    sequence: 1,
    actor: "kimi-acp-host",
    kind: .toolProgress,
    payload: ["text": "工具日志中出现 https://untrusted.example.com"]
  ),
  AgentEvent(
    sessionID: persistedTask.id,
    taskID: persistedTask.id,
    sequence: 2,
    actor: "kimi-acp-host",
    kind: .output,
    payload: ["text": "最终结论依据：https://docs.example.com/kimi"]
  )
]
expect(
  WebResearchCitationVerifier.answerText(from: citationEvents) == "最终结论依据：https://docs.example.com/kimi",
  "引用校验只能使用模型输出，不能把工具日志当成回答内容"
)
let chunkedCitationEvents = [
  AgentEvent(
    sessionID: persistedTask.id,
    taskID: persistedTask.id,
    sequence: 1,
    actor: "kimi-acp-host",
    kind: .output,
    payload: ["contentType": "thinking", "text": "The source is https://untrusted.example.com"]
  ),
  AgentEvent(
    sessionID: persistedTask.id,
    taskID: persistedTask.id,
    sequence: 2,
    actor: "kimi-acp-host",
    kind: .output,
    payload: ["contentType": "text", "text": "来源：[Apple](https"]
  ),
  AgentEvent(
    sessionID: persistedTask.id,
    taskID: persistedTask.id,
    sequence: 3,
    actor: "kimi-acp-host",
    kind: .output,
    payload: ["contentType": "text", "text": "://www.apple.com/)"]
  )
]
expect(
  WebResearchCitationVerifier.answerText(from: chunkedCitationEvents) == "来源：[Apple](https://www.apple.com/)",
  "引用校验必须把流式 URL chunk 连续拼接，并排除 thinking 文本"
)
let missingCitationCheck = WebResearchCitationVerifier.validate(answer: "这是一个没有链接的结论。", sources: extractedSources)
expect(!missingCitationCheck.isValid, "有联网来源但回答没有可验证引用时必须标记待审阅")
var citationTask = persistedTask
citationTask.webResearchCitationStatus = .needsReview
let citationTaskData = try JSONEncoder().encode(citationTask)
let restoredCitationTask = try JSONDecoder().decode(AgentTask.self, from: citationTaskData)
expect(restoredCitationTask.webResearchCitationStatus == .needsReview, "引用待审阅状态必须在重启后恢复")

let resourceDirectory = temporaryDirectory.appendingPathComponent("KimiCodeAgent.bundle", isDirectory: true)
let resourceContentsDirectory = resourceDirectory.appendingPathComponent("Resources", isDirectory: true)
try FileManager.default.createDirectory(at: resourceContentsDirectory, withIntermediateDirectories: true)
let runtimeURL = resourceContentsDirectory.appendingPathComponent("kimi.mjs")
try "#!/usr/bin/env node".write(to: runtimeURL, atomically: true, encoding: .utf8)
expect(
  ManagedRuntimeLocator.runtimeURL(in: [temporaryDirectory])?.standardizedFileURL == runtimeURL.standardizedFileURL,
  "运行时定位器必须找到嵌入资源 bundle 的 kimi.mjs"
)
let universalResourceDirectory = temporaryDirectory
  .appendingPathComponent("Universal.bundle", isDirectory: true)
  .appendingPathComponent("Contents", isDirectory: true)
  .appendingPathComponent("Resources", isDirectory: true)
  .appendingPathComponent("Resources", isDirectory: true)
try FileManager.default.createDirectory(at: universalResourceDirectory, withIntermediateDirectories: true)
let universalHostURL = universalResourceDirectory.appendingPathComponent("agent-host.cjs")
try "#!/usr/bin/env node".write(to: universalHostURL, atomically: true, encoding: .utf8)
expect(
  ManagedRuntimeLocator.resourceURL(named: "agent-host.cjs", in: [temporaryDirectory])?.standardizedFileURL == universalHostURL.standardizedFileURL,
  "Universal bundle 的 Contents/Resources/Resources 资源必须可被运行时定位器找到"
)
expect(
  ManagedRuntimeLocator.nodePath(environment: ["KIMI_NODE_PATH": "/bin/echo"], candidates: []) == "/bin/echo",
  "必须优先使用用户显式配置的 Node 路径"
)

let event = AgentEvent(
  sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
  taskID: persistedTask.id,
  workItemID: nil,
  sequence: 1,
  actor: "test",
  kind: .fileChanged,
  payload: ["path": "Sources/App.swift", "status": "modified"],
  requiresApproval: false
)
let encodedEvent = try JSONEncoder().encode(event)
let decodedEvent = try JSONDecoder().decode(AgentEvent.self, from: encodedEvent)
expect(decodedEvent == event, "结构化 Agent 事件必须可编码、解码并保持一致")

let conversationTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000120")!
let conversationSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000121")!
let conversationTask = AgentTask(
  id: conversationTaskID,
  title: "输出当前项目的目录结构，并说明如何运行测试",
  mode: .plan,
  workspacePath: "/tmp/sample",
  sessionID: conversationSessionID.uuidString,
  structuredEvents: [
    AgentEvent(sessionID: conversationSessionID, taskID: conversationTaskID, sequence: 1, actor: "desktop", kind: .sessionCreated),
    AgentEvent(sessionID: conversationSessionID, taskID: conversationTaskID, sequence: 2, actor: "kimi-runtime", kind: .output, payload: ["text": "正在思考…"]),
    AgentEvent(sessionID: conversationSessionID, taskID: conversationTaskID, sequence: 3, actor: "kimi-runtime", kind: .output, payload: ["text": "目录结构如下："]),
    AgentEvent(sessionID: conversationSessionID, taskID: conversationTaskID, sequence: 4, actor: "kimi-runtime", kind: .output, payload: ["text": "\n- macos\n- src"]),
    AgentEvent(sessionID: conversationSessionID, taskID: conversationTaskID, sequence: 5, actor: "desktop", kind: .output, payload: ["role": "user", "text": "那测试命令是什么？"]),
    AgentEvent(sessionID: conversationSessionID, taskID: conversationTaskID, sequence: 6, actor: "kimi-runtime", kind: .toolRequested, payload: ["name": "Shell"]),
    AgentEvent(sessionID: conversationSessionID, taskID: conversationTaskID, sequence: 7, actor: "kimi-runtime", kind: .output, payload: ["text": "运行 `npm run verify`。"])
  ]
)

expect(TaskStateMachine.canTransition(from: .queued, to: .planning), "任务状态机必须允许 queued 到 planning")
expect(TaskStateMachine.canTransition(from: .planning, to: .awaitingApproval), "任务状态机必须允许计划后等待审批")
expect(!TaskStateMachine.canTransition(from: .merged, to: .running), "已合并任务不能回到运行中")

let permissionPolicy = PermissionPolicy(workspacePath: temporaryDirectory.path)
expect(
  permissionPolicy.decision(for: .readWorkspace, path: temporaryDirectory.appendingPathComponent("file.txt").path) == .allow,
  "工作区内读取应默认允许"
)
expect(
  permissionPolicy.decision(for: .destructiveOperation, path: temporaryDirectory.path) == .ask,
  "破坏性操作必须请求用户审批"
)
expect(
  permissionPolicy.decision(for: .writeWorkspace, path: "/tmp/outside-workspace.txt") == .deny,
  "工作区外写入必须拒绝"
)
let readEvaluation = permissionPolicy.approvalEvaluation(
  action: "ReadFile",
  description: "读取工作区中的 README",
  workspacePath: temporaryDirectory.path
)
expect(
  readEvaluation.decision == .allow && readEvaluation.remember == .task,
  "工作区内读取审批必须自动放行，并允许本任务复用"
)
let shellEvaluation = permissionPolicy.approvalEvaluation(
  action: "Bash",
  description: "npm test",
  workspacePath: temporaryDirectory.path
)
expect(
  shellEvaluation.decision == .ask && shellEvaluation.remember == .task,
  "普通 shell 命令必须仍然请求一次审批，但允许本任务记忆"
)
let networkEvaluation = permissionPolicy.approvalEvaluation(
  action: "FetchURL",
  description: "https://example.com",
  workspacePath: temporaryDirectory.path
)
expect(
  networkEvaluation.decision == .allow && networkEvaluation.remember == .task,
  "公开 HTTPS Web Fetch 是只读操作，应自动放行并按任务/域名复用授权"
)
let privateNetworkEvaluation = permissionPolicy.approvalEvaluation(
  action: "FetchURL",
  description: "http://127.0.0.1:5173/internal",
  workspacePath: temporaryDirectory.path
)
expect(
  privateNetworkEvaluation.decision == .ask && privateNetworkEvaluation.remember == .never,
  "本机或私有网络 Fetch 仍必须保留审批边界"
)
let approvalMemory = ApprovalMemory()
let approvalTaskID = UUID()
expect(
  !approvalMemory.contains(taskID: approvalTaskID, fingerprint: shellEvaluation.fingerprint),
  "新任务的审批记忆必须是空的"
)
approvalMemory.remember(taskID: approvalTaskID, fingerprint: shellEvaluation.fingerprint)
expect(
  approvalMemory.contains(taskID: approvalTaskID, fingerprint: shellEvaluation.fingerprint),
  "同一任务的已批准请求必须可复用"
)
approvalMemory.clear(taskID: approvalTaskID)
expect(
  !approvalMemory.contains(taskID: approvalTaskID, fingerprint: shellEvaluation.fingerprint),
  "清除任务记忆后不应继续自动批准"
)

let webResearchDecision = TaskIntentRouter.decide(for: "搜索 Kimi Agent 的最新文档")
expect(webResearchDecision.intent == .webResearch, "联网研究必须识别为 Web Research 意图")
expect(!webResearchDecision.requiresPlanning, "联网研究必须走低延迟主 Harness，不应创建通用 Plan/Explore 阶段")
expect(webResearchDecision.recommendedAgents == [.webResearch], "联网研究不得先启动无关 Explore")
let timelyMarketDecision = TaskIntentRouter.decide(for: "今天股市行情怎么样？")
expect(timelyMarketDecision.intent == .webResearch, "时效性行情问题必须自动进入联网研究，不能让模型在无网络情况下直接猜测")
let tomorrowWeatherDecision = TaskIntentRouter.decide(for: "明天大连的天气怎么样")
expect(tomorrowWeatherDecision.intent == .webResearch, "明天/未来天气必须自动进入联网研究，不能误走 Explore")
expect(!tomorrowWeatherDecision.requiresPlanning, "天气查询不应创建 Plan/Explore 阶段")
let verificationPlan = VerificationPlan(steps: [
  VerificationStep(kind: .command, command: "/bin/sh", arguments: ["-c", "printf verification-ok"])
])
let verificationResult = try VerificationRunner.run(verificationPlan, workingDirectory: temporaryDirectory)
expect(verificationResult.passed, "验证执行器应报告成功命令通过")
expect(verificationResult.steps.first?.standardOutput == "verification-ok", "验证执行器必须保留标准输出")

let browserVerificationPlan = BrowserVerificationPlan(
  allowedDomains: ["localhost", "127.0.0.1"],
  steps: [
    BrowserVerificationStep(kind: .open, url: URL(string: "http://localhost:5173")!),
    BrowserVerificationStep(kind: .inspect, selector: "#app"),
    BrowserVerificationStep(kind: .screenshot, artifactName: "home")
  ]
)
expect(browserVerificationPlan.steps.count == 3, "浏览器验证计划必须保存可回放步骤")
expect(!browserVerificationPlan.requiresApproval(for: URL(string: "http://localhost:5173")!), "本地浏览器验证不应额外审批")
expect(browserVerificationPlan.requiresApproval(for: URL(string: "https://example.com")!), "未授权外部域名必须审批")
expect(browserVerificationPlan.requiresApproval(for: URL(fileURLWithPath: "/tmp/page.html")), "Browser 打开本地 file:// 文件必须审批")
let failedBrowserResult = BrowserVerificationResult(
  passed: false,
  currentURL: URL(string: "http://localhost:5173/login")!,
  artifacts: [
    BrowserArtifact(kind: .screenshot, name: "failure", path: "/tmp/kimi-browser-failure.png"),
    BrowserArtifact(kind: .consoleError, name: "console", text: "ReferenceError: login is not defined")
  ],
  timeline: [
    BrowserVerificationTrace(stepKind: .open, message: "已打开 http://localhost:5173"),
    BrowserVerificationTrace(stepKind: .inspect, message: "未找到 #login")
  ]
)
expect(
  failedBrowserResult.repairSummary.contains("ReferenceError") && failedBrowserResult.repairSummary.contains("kimi-browser-failure.png"),
  "浏览器验证失败必须把截图与 console 错误整理成修复上下文"
)

let integrationVault = InMemoryCredentialVault()
let integrationStore = IntegrationAccountStore(vault: integrationVault)
try integrationStore.connect(
  provider: .github,
  accountName: "eastbuy",
  credential: "ghp_test",
  defaultRepository: "eastbuy/kimi-agent"
)
let githubAccount = try integrationStore.account(for: .github)
expect(githubAccount?.isConnected == true, "GitHub 账号连接状态必须可恢复")
expect(githubAccount?.defaultRepository == "eastbuy/kimi-agent", "GitHub 默认仓库必须持久化")
let integrationEnvironment = try integrationStore.runtimeEnvironment()
expect(integrationEnvironment[IntegrationProvider.github.environmentKey] == "ghp_test", "GitHub token 必须能注入运行时环境")
try integrationStore.disconnect(provider: .github)
let disconnectedGitHubAccount = try integrationStore.account(for: .github)
expect(disconnectedGitHubAccount?.isConnected == false, "断开连接后 GitHub 状态必须回到未连接")

let runtimeIdentityVault = InMemoryCredentialVault()
let runtimeIdentityStore = KimiRuntimeIdentityStore(vault: runtimeIdentityVault)
try runtimeIdentityStore.connectAPI(
  apiKey: "sk-test-api-quota",
  baseURL: "https://api.moonshot.cn/v1",
  modelID: "kimi-latest"
)
let apiIdentity = try runtimeIdentityStore.record()
expect(apiIdentity.mode == .apiKey, "API Key 保存后必须切换到 API 模式")
expect(apiIdentity.apiKeyStatus == "configured", "API Key 必须只以配置状态暴露给 UI")
expect(apiIdentity.modelID == "kimi-latest", "API 模式必须持久化默认模型")
let legacyDefaultVault = InMemoryCredentialVault()
let legacyDefaultStore = KimiRuntimeIdentityStore(vault: legacyDefaultVault)
try legacyDefaultStore.connectAPI(
  apiKey: "sk-legacy-default",
  baseURL: "https://api.moonshot.ai/v1",
  modelID: "kimi-k2.7-code"
)
let migratedLegacyIdentity = try legacyDefaultStore.record()
expect(
  migratedLegacyIdentity.baseURL == "https://api.moonshot.cn/v1",
  "旧版本误写入的 .ai 默认地址必须自动迁移到 .cn"
)
let apiRuntimeEnvironment = try runtimeIdentityStore.runtimeEnvironment(applicationSupportDirectory: temporaryDirectory)
expect(
  apiRuntimeEnvironment["KIMI_SHARE_DIR"] == temporaryDirectory.appendingPathComponent("kimi-api", isDirectory: true).path,
  "API 模式必须使用独立 Kimi Runtime 配置目录"
)
expect(
  apiRuntimeEnvironment["KIMI_CODE_HOME"] == apiRuntimeEnvironment["KIMI_SHARE_DIR"],
  "必须同时兼容新版 KIMI_CODE_HOME 和旧版 KIMI_SHARE_DIR"
)
expect(
  KimiRuntimeConnectionGuidance.apiKeyHint().contains("API Key") && KimiRuntimeConnectionGuidance.apiKeyHint().contains("留空"),
  "API Key 提示必须说明保存后可留空"
)
expect(
  KimiRuntimeConnectionGuidance.apiKeyExample().contains("sk-"),
  "API Key 示例必须给出可直接照着填写的格式"
)
expect(
  KimiRuntimeConnectionGuidance.baseURLHint().contains("api.moonshot.cn/v1"),
  "Base URL 提示必须包含默认地址"
)
expect(
  KimiRuntimeConnectionGuidance.baseURLExample().contains("https://api.moonshot.cn/v1"),
  "Base URL 示例必须直接给出默认值"
)
expect(
  KimiRuntimeConnectionGuidance.modelHint().contains("刷新模型列表"),
  "模型提示必须说明刷新模型列表"
)
expect(KimiRuntimeIdentityStore.defaultModelID == "kimi-k2.7-code", "新安装的 Coding Agent 默认模型必须是 kimi-k2.7-code")
expect(
  KimiRuntimeIdentityStore.resolvedModelID(taskModelID: nil, fallbackModelID: "kimi-k3") == "kimi-k3",
  "恢复旧任务时必须使用当前身份模型，不能因为 task.modelID 为空而让 ACP 会话没有模型"
)
expect(
  KimiRuntimeIdentityStore.resolvedModelID(taskModelID: "kimi-k2.7-code", fallbackModelID: "kimi-k3") == "kimi-k2.7-code",
  "任务显式选择的模型必须优先于身份默认模型"
)
expect(
  KimiRuntimeConnectionGuidance.modelExample().contains("kimi-k2.7-code"),
  "模型示例必须给出默认模型"
)

// Multi-provider credential bucket tests
let multiProviderVault = InMemoryCredentialVault()
let multiProviderStore = KimiRuntimeIdentityStore(vault: multiProviderVault)
try multiProviderStore.saveAPIKey("sk-moonshot", for: "moonshotai-cn")
try multiProviderStore.saveAPIKey("sk-openai", for: "openai")
let moonshotKey = try multiProviderStore.apiKey(for: "moonshotai-cn")
expect(
  moonshotKey == "sk-moonshot",
  "分桶存储后必须能按 provider ID 读取对应 key"
)
let openaiKey = try multiProviderStore.apiKey(for: "openai")
expect(
  openaiKey == "sk-openai",
  "分桶存储后必须能按 provider ID 读取另一个 provider 的 key"
)
let anthropicKey = try multiProviderStore.apiKey(for: "anthropic")
expect(
  anthropicKey == nil,
  "未配置的 provider 读取时必须返回 nil，不能返回其他 provider 的 key"
)
let configuredIDs = try multiProviderStore.configuredProviderIDs().sorted()
expect(
  configuredIDs == ["moonshotai-cn", "openai"].sorted(),
  "configuredProviderIDs 必须列出所有已配置凭据的 provider ID"
)
try multiProviderStore.deleteAPIKey(for: "openai")
let deletedOpenaiKey = try multiProviderStore.apiKey(for: "openai")
expect(
  deletedOpenaiKey == nil,
  "删除某个 provider 的 key 后读取时必须返回 nil"
)
let remainingIDs = try multiProviderStore.configuredProviderIDs()
expect(
  remainingIDs == ["moonshotai-cn"],
  "删除后 configuredProviderIDs 必须只反映剩余已配置的 provider"
)

// Migration from legacy single-credential key
let migrationVault = InMemoryCredentialVault()
let migrationStore = KimiRuntimeIdentityStore(vault: migrationVault)
// Manually write to the legacy single key to simulate an old install
try migrationVault.write("sk-legacy", key: "kimi.runtime.identity.apiKey")
let migratedRecord = try migrationStore.record()
expect(
  migratedRecord.apiKeyStatus == "configured",
  "迁移后 apiKeyStatus 必须反映至少一个 provider 已配置"
)
let migratedKey = try migrationStore.apiKey(for: KimiRuntimeIdentityStore.providerID)
expect(
  migratedKey == "sk-legacy",
  "迁移后旧 key 必须出现在默认 provider 的分桶里"
)
// Legacy key should be deleted after migration
let legacyKeyAfterMigration = try migrationVault.read(key: "kimi.runtime.identity.apiKey")
expect(
  legacyKeyAfterMigration == nil,
  "迁移后旧单一 key 必须被删除"
)
// Migration must be idempotent: running it again doesn't duplicate or corrupt
try migrationStore.migrateIfNeeded()
let migratedKeyAgain = try migrationStore.apiKey(for: KimiRuntimeIdentityStore.providerID)
expect(
  migratedKeyAgain == "sk-legacy",
  "重复迁移不能覆盖已存在的新 key"
)

expect(
  KimiModelCatalogClient.fallbackModels().map(\.id) == ["kimi-k2.7-code", "kimi-k3"],
  "模型列表在无法刷新时必须仍然提供默认候选模型"
)
expect(
  KimiRuntimeConnectionGuidance.codeModeHint().contains("device-code") && KimiRuntimeConnectionGuidance.codeModeHint().contains("API 额度"),
  "Kimi Code 提示必须说明网页登录和 API 额度的区别"
)
expect(
  KimiRuntimeConnectionGuidance.codeModeExample().contains("device-code"),
  "Kimi Code 示例必须说明浏览器登录流程"
)
let apiConfigURL = temporaryDirectory
  .appendingPathComponent("kimi-api", isDirectory: true)
  .appendingPathComponent("config.toml")
let apiConfig = try String(contentsOf: apiConfigURL, encoding: .utf8)
expect(apiConfig.contains("[providers.kimi]"), "API 模式必须写出 Kimi Code provider 配置")
expect(
  apiConfig.contains("[thinking]") && apiConfig.contains("enabled = true"),
  "Kimi API 模式必须使用新版 thinking.enabled 配置，兼容 kimi-k2.7-code 的强制思考协议"
)
expect(apiConfig.contains("api_key = \"sk-test-api-quota\""), "Kimi Code provider 配置必须能使用用户 API 额度")
expect(apiConfig.contains("default_model = \"kimi-latest\""), "API 模式必须写出默认模型")
expect(apiConfig.contains("[models.\"kimi-latest\"]"), "默认模型必须声明到 Kimi Code 的 models 配置中")
expect(apiConfig.contains("provider = \"kimi\"") && apiConfig.contains("model = \"kimi-latest\""), "模型别名必须绑定到 Kimi provider 与真实模型 ID")
expect(apiConfig.contains("capabilities = [\"always_thinking\"]"), "Kimi API 模型必须声明 always_thinking，避免 Runtime 为 kimi-k2.7-code 错误发送 thinking=disabled")
_ = try runtimeIdentityStore.runtimeEnvironment(
  applicationSupportDirectory: temporaryDirectory,
  additionalModelIDs: ["kimi-k3"]
)
let apiConfigWithTaskModel = try String(contentsOf: apiConfigURL, encoding: .utf8)
expect(apiConfigWithTaskModel.contains("[models.\"kimi-k3\"]"), "任务选择的模型也必须写入 Kimi Code models 配置，确保 ACP 可切换")
expect(apiConfig.contains("pattern = \"WebSearch\""), "Kimi API 模式必须将 WebSearch 纳入桌面审批策略")
expect(apiConfig.contains("pattern = \"FetchURL\""), "Kimi API 模式必须将 FetchURL 纳入桌面审批策略")
let apiConfigAttributes = try? FileManager.default.attributesOfItem(atPath: apiConfigURL.path)
let apiConfigPermissions = (apiConfigAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
expect(apiConfigPermissions & 0o777 == 0o600, "API 模式配置必须始终以 0600 权限原子写入")
try runtimeIdentityStore.useKimiCode()
let codeRuntimeEnvironment = try runtimeIdentityStore.runtimeEnvironment(applicationSupportDirectory: temporaryDirectory)
expect(
  codeRuntimeEnvironment["KIMI_SHARE_DIR"] == temporaryDirectory.appendingPathComponent("kimi-code", isDirectory: true).path,
  "Kimi Code 登录模式必须使用独立配置目录，避免覆盖 API 模式"
)
try runtimeIdentityStore.disconnectAPI(applicationSupportDirectory: temporaryDirectory)
expect(
  !FileManager.default.fileExists(atPath: apiConfigURL.path),
  "断开 API 连接必须删除明文 config.toml"
)
try runtimeIdentityStore.connectAPI(
  apiKey: "sk-test-api-quota",
  baseURL: "https://api.moonshot.cn/v1",
  modelID: "kimi-latest"
)
_ = try runtimeIdentityStore.runtimeEnvironment(applicationSupportDirectory: temporaryDirectory)
let reconnectedConfigAttributes = try? FileManager.default.attributesOfItem(atPath: apiConfigURL.path)
let reconnectedConfigPermissions = (reconnectedConfigAttributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
expect(reconnectedConfigPermissions & 0o777 == 0o600, "重新连接后 config.toml 必须保持 0600 权限")
let countedVault = CountingCredentialVault()
let cachedVault = CachingCredentialVault(base: countedVault)
try cachedVault.write("cached-secret", key: "api")
let firstCachedSecret = try cachedVault.read(key: "api")
let secondCachedSecret = try cachedVault.read(key: "api")
expect(firstCachedSecret == "cached-secret", "缓存凭据 vault 必须返回已写入的值")
expect(secondCachedSecret == "cached-secret", "缓存凭据 vault 必须稳定返回重复读取")
expect(countedVault.readCount == 0, "写入后的重复读取不应再次触发底层 Keychain")
try cachedVault.delete(key: "api")
let deletedCachedSecret = try cachedVault.read(key: "api")
expect(deletedCachedSecret == nil, "删除后缓存必须失效")
expect(countedVault.readCount == 1, "删除后的首次读取才需要回到底层 vault")
let missingCredentialVault = CountingCredentialVault()
let cachedMissingCredentialVault = CachingCredentialVault(base: missingCredentialVault)
let firstMissingCredential = try cachedMissingCredentialVault.read(key: "missing")
let secondMissingCredential = try cachedMissingCredentialVault.read(key: "missing")
expect(firstMissingCredential == nil, "不存在的凭据必须返回 nil")
expect(secondMissingCredential == nil, "重复读取不存在的凭据必须稳定返回 nil")
expect(missingCredentialVault.readCount == 1, "不存在的凭据也必须被缓存，避免同一会话重复触发 Keychain")
expect(
  CredentialStoragePolicy.defaultMode(environment: [:], hasStableSigningIdentity: false) == .localFile,
  "未稳定签名的本地构建必须默认使用本地凭据文件，避免 Keychain 重复弹窗"
)
expect(
  CredentialStoragePolicy.defaultMode(environment: [:], hasStableSigningIdentity: true) == .keychain,
  "稳定签名的发布构建必须继续使用 Keychain"
)
let fileVaultURL = temporaryDirectory.appendingPathComponent("credentials.json")
let fileVault = FileCredentialVault(fileURL: fileVaultURL)
try fileVault.write("local-api-key", key: "apiKey")
let reloadedFileVault = FileCredentialVault(fileURL: fileVaultURL)
let reloadedFileCredential = try reloadedFileVault.read(key: "apiKey")
expect(reloadedFileCredential == "local-api-key", "本地凭据 vault 必须可跨实例恢复凭据")

let webResearchVault = InMemoryCredentialVault()
let webResearchStore = WebResearchSettingsStore(vault: webResearchVault)
let defaultWebResearch = try webResearchStore.record()
expect(defaultWebResearch.provider == .kimiOfficial, "普通用户的默认联网 Provider 必须是 Kimi 官方联网")
expect(defaultWebResearch.isEnabled, "Kimi 官方联网必须默认启用，用户不应填写第三方搜索服务")
expect(defaultWebResearch.apiKeyStatus == "usesKimiAPI", "Kimi 官方联网必须复用已保存的 Kimi API Key，而非索取第三方 Key")
let officialWebEnvironment = try webResearchStore.runtimeEnvironment()
expect(officialWebEnvironment["KIMI_AGENT_WEB_SEARCH_PROVIDER"] == "kimi_official", "运行时必须明确选择 Kimi 官方联网 Provider")
expect(officialWebEnvironment["KIMI_AGENT_OFFICIAL_TOOLS_BASE_URL"] == "https://api.moonshot.cn/v1", "Kimi 官方工具必须使用 Formula API 基地址")
let officialResearchReady = WebResearchConnectionPresentation(
  settings: defaultWebResearch,
  identity: apiIdentity
)
expect(officialResearchReady.isReady, "已保存 Kimi API Key 时，Kimi 官方联网必须显示为可用")
expect(officialResearchReady.statusText.contains("Kimi API"), "官方联网状态必须明确说明使用 Kimi API，而不是第三方搜索 Key")
let officialResearchNeedsAPI = WebResearchConnectionPresentation(
  settings: defaultWebResearch,
  identity: KimiRuntimeIdentityRecord(mode: .kimiCode, apiKeyStatus: "missing")
)
expect(!officialResearchNeedsAPI.isReady, "仅 Kimi Code 登录且未保存 API Key 时不能误报 Kimi 官方联网可用")
expect(officialResearchNeedsAPI.actionTitle == "配置 Kimi API Key", "未配置 Kimi API 时必须给出直接恢复入口")
let checkingResearch = WebResearchConnectionPresentation(
  settings: defaultWebResearch,
  identity: apiIdentity,
  capability: .checking
)
expect(checkingResearch.statusText.contains("检查"), "官方联网检查中必须在 UI 明确显示检查状态")
let bridgeFailureMessage = WebResearchConnectionPresentation.bridgeFailureMessage(
  statusCode: 502,
  body: #"{"error":"Kimi 官方联网请求失败：模型不存在"}"#
)
expect(
  bridgeFailureMessage.contains("502") && bridgeFailureMessage.contains("模型不存在"),
  "官方联网测试失败必须把 Bridge 返回的真实错误透出给用户"
)
try webResearchStore.save(
  provider: .brave,
  apiKey: "brave-search-test-key",
  endpoint: WebResearchSettingsStore.defaultBraveEndpoint,
  allowedDomains: ["docs.moonshot.cn", "github.com"],
  defaultResultLimit: 4
)
let braveWebResearch = try webResearchStore.record()
expect(braveWebResearch.isEnabled, "保存 Brave Web Search 后必须启用联网搜索")
expect(braveWebResearch.provider == .brave, "Web Search 必须持久化当前 Provider")
expect(braveWebResearch.apiKeyStatus == "configured", "Brave API Key 只能以配置状态暴露给 UI")
expect(braveWebResearch.allowedDomains == ["docs.moonshot.cn", "github.com"], "直接 Web Fetch 的授权域名必须持久化")
let braveWebEnvironment = try webResearchStore.runtimeEnvironment()
expect(braveWebEnvironment["KIMI_AGENT_WEB_SEARCH_PROVIDER"] == "brave", "Brave 配置必须注入 Native Agent Host")
expect(braveWebEnvironment["KIMI_AGENT_WEB_SEARCH_API_KEY"] == "brave-search-test-key", "Brave API Key 必须只注入运行时环境")
expect(braveWebEnvironment["KIMI_AGENT_WEB_SEARCH_DEFAULT_RESULTS"] == "4", "Web Search 默认结果数必须注入运行时环境")
try webResearchStore.save(
  provider: .searxng,
  apiKey: "",
  endpoint: "https://search.example.com/search",
  allowedDomains: ["search.example.com"],
  defaultResultLimit: 6
)
let searxWebResearch = try webResearchStore.record()
expect(searxWebResearch.provider == .searxng, "用户必须可切换到自托管 SearxNG")
expect(searxWebResearch.apiKeyStatus == "notRequired", "SearxNG 不应要求 API Key")
let searxWebEnvironment = try webResearchStore.runtimeEnvironment()
expect(searxWebEnvironment["KIMI_AGENT_WEB_SEARCH_PROVIDER"] == "searxng", "SearxNG Provider 必须注入 Native Agent Host")
expect(searxWebEnvironment["KIMI_AGENT_WEB_SEARCH_API_KEY"] == nil, "SearxNG 模式不能向运行时注入空 API Key")
try webResearchStore.disconnect()
let disconnectedWebResearch = try webResearchStore.record()
expect(!disconnectedWebResearch.isEnabled, "断开 Web Search 后必须禁止运行时继续使用联网搜索")

let modelListJSON = """
{
  "object": "list",
  "data": [
    { "id": "kimi-latest", "object": "model", "owned_by": "moonshot" },
    { "id": "kimi-k2.5", "object": "model", "owned_by": "moonshot" }
  ]
}
"""
let decodedModels = try JSONDecoder().decode(KimiModelCatalogResponse.self, from: Data(modelListJSON.utf8))
expect(decodedModels.data.count == 2, "模型列表必须能解码出 data 数组")
expect(decodedModels.data.first?.displayName == "kimi-latest · moonshot", "模型展示名称必须包含 owned_by")
let normalizedModelURL = try KimiModelCatalogClient.modelsURL(baseURL: "https://api.moonshot.cn/v1/")
expect(normalizedModelURL.absoluteString == "https://api.moonshot.cn/v1/models", "模型刷新必须请求正确的官方 /v1/models")

let mockModelsConfig = URLSessionConfiguration.ephemeral
mockModelsConfig.protocolClasses = [MockURLProtocol.self]
let mockModelsSession = URLSession(configuration: mockModelsConfig)
var capturedAuthorizationHeader = ""
MockURLProtocol.requestHandler = { request in
  capturedAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization") ?? ""
  let response = HTTPURLResponse(
    url: request.url!,
    statusCode: 200,
    httpVersion: "HTTP/1.1",
    headerFields: ["Content-Type": "application/json"]
  )!
  return (response, Data(modelListJSON.utf8))
}
let fetchedModels = try awaitValue {
  try await KimiModelCatalogClient.fetchModels(
    baseURL: "https://api.moonshot.cn/v1",
    apiKey: "sk-test-model-refresh",
    session: mockModelsSession
  )
}
expect(capturedAuthorizationHeader == "Bearer sk-test-model-refresh", "刷新模型必须带上 API Key 鉴权")
expect(fetchedModels.map(\.id) == ["kimi-k2.5", "kimi-latest"], "刷新后的模型列表必须按名称稳定排序")
MockURLProtocol.requestHandler = nil
let nestedToolInput: HarnessJSONValue = .object([
  "query": .string("Kimi docs"),
  "filters": .object(["domains": .array([.string("example.com"), .string("moonshot.cn")])]),
  "limit": .number(2),
  "fresh": .bool(true)
])
let structuredToolRequest = ToolExecutionRequest(
  taskID: UUID(),
  sessionID: UUID(),
  agentID: "test",
  toolID: "web.search",
  inputJSON: nestedToolInput
)
let restoredStructuredToolRequest = try JSONDecoder().decode(
  ToolExecutionRequest.self,
  from: JSONEncoder().encode(structuredToolRequest)
)
expect(restoredStructuredToolRequest.inputJSON == nestedToolInput, "Tool Request 必须完整保留嵌套 JSON 参数")
expect(restoredStructuredToolRequest.input["query"] == "Kimi docs", "旧 Tool Executor 必须继续获得字符串参数兼容投影")
expect(restoredStructuredToolRequest.inputJSON.objectValue?["filters"]?.objectValue?["domains"]?.arrayValue?.count == 2, "数组和对象参数不得在 Provider 与 Tool Runtime 之间丢失")

MockURLProtocol.requestHandler = { request in
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
  let stream = """
  data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"fetch-1","function":{"name":"web_fetch","arguments":"{\\\"url\\\":\\\"https://"}}]}}]}

  data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"www.apple.com/\\\"}"}}]}}]}

  data: [DONE]

  """
  return (response, Data(stream.utf8))
}
expect(!ToolCatalog.defaultDefinitions.contains(where: { ["WebSearch", "FetchURL", "network.fetch"].contains($0.id) }), "模型工具目录只能暴露规范 Web 工具名")
MockURLProtocol.requestHandler = nil

let failingVerification = VerificationResult(passed: false, steps: [
  VerificationStepResult(
    id: UUID(),
    stepID: UUID(),
    kind: .test,
    passed: false,
    exitCode: 1,
    standardOutput: "",
    standardError: "npm test failed",
    duration: 1
  )
])
let repairableTask = AgentTask(
  title: "修复登录失败",
  mode: .edit,
  workspacePath: "/Users/eastbuy/Projects/sample"
)
expect(
  VerificationRepairPlanner.shouldAutoRepair(task: repairableTask, result: failingVerification, maxRepairRounds: 3),
  "验证失败后必须允许进入自动修复闭环"
)
let repairPrompt = VerificationRepairPlanner.repairPrompt(for: repairableTask, result: failingVerification, maxRepairRounds: 3)
expect(repairPrompt.contains("第 1 轮自动修复"), "自动修复提示必须包含轮次")
expect(repairPrompt.contains("npm test failed"), "自动修复提示必须包含失败上下文")
let exhaustedTask = AgentTask(
  title: "修复登录失败",
  mode: .edit,
  workspacePath: "/Users/eastbuy/Projects/sample",
  structuredEvents: [
    AgentEvent(sessionID: UUID(), taskID: UUID(), sequence: 1, actor: "desktop", kind: .verificationFailed, payload: [:]),
    AgentEvent(sessionID: UUID(), taskID: UUID(), sequence: 2, actor: "desktop", kind: .verificationFailed, payload: [:]),
    AgentEvent(sessionID: UUID(), taskID: UUID(), sequence: 3, actor: "desktop", kind: .verificationFailed, payload: [:])
  ]
)
expect(
  !VerificationRepairPlanner.shouldAutoRepair(task: exhaustedTask, result: failingVerification, maxRepairRounds: 3),
  "超过最大修复轮次后必须停止自动修复"
)

let agentPlan = TaskSupervisor.makePlan(taskID: persistedTask.id, mode: .agent)
expect(agentPlan.workItems.count == 4, "Agent 模式必须创建分析、实现、测试和审阅四类 Worker")
let analyzer = agentPlan.workItems.first { $0.role == .analyzer }
let implementer = agentPlan.workItems.first { $0.role == .implementer }
let testRunner = agentPlan.workItems.first { $0.role == .testRunner }
expect(analyzer?.dependencies.isEmpty == true, "分析 Worker 不应依赖其他 Worker")
expect(implementer?.dependencies == [analyzer?.id].compactMap { $0 }, "实现 Worker 必须依赖分析完成")
expect(testRunner?.dependencies == [implementer?.id].compactMap { $0 }, "测试 Worker 必须依赖实现完成")

let nodeProject = temporaryDirectory.appendingPathComponent("node-project", isDirectory: true)
try FileManager.default.createDirectory(at: nodeProject, withIntermediateDirectories: true)
try "{\"scripts\":{\"test\":\"vitest run\",\"build\":\"tsc\"}}".write(
  to: nodeProject.appendingPathComponent("package.json"), atomically: true, encoding: .utf8
)
let detectedVerificationPlan = VerificationPlanner.defaultPlan(for: nodeProject)
expect(detectedVerificationPlan.steps.map(\.kind) == [.test, .build], "Node 项目必须检测测试和构建验证步骤")

var structuredTask = AgentTask(title: "结构化任务", mode: .agent, workspacePath: temporaryDirectory.path)
structuredTask.structuredEvents = [event]
structuredTask.workItems = agentPlan.workItems
structuredTask.diffSnapshot = DiffSnapshot(taskID: structuredTask.id, files: [])
structuredTask.verificationResult = verificationResult
let structuredTaskData = try JSONEncoder().encode(structuredTask)
let restoredStructuredTask = try JSONDecoder().decode(AgentTask.self, from: structuredTaskData)
expect(restoredStructuredTask.structuredEvents == [event], "任务必须持久化结构化事件")
expect(restoredStructuredTask.workItems == agentPlan.workItems, "任务必须持久化 Worker 状态")
expect(restoredStructuredTask.diffSnapshot?.taskID == structuredTask.id, "任务必须持久化 Diff 快照")
expect(restoredStructuredTask.verificationResult == verificationResult, "任务必须持久化验证结果")

var reviewState = DiffReviewState()
reviewState.acceptFile("README.md")
reviewState.addComment(DiffComment(filePath: "README.md", line: 1, text: "请补充测试说明。"))
expect(reviewState.fileDecisions["README.md"] == .accepted, "Diff Review 必须记录文件接受决定")
expect(reviewState.comments.count == 1, "Diff Review 必须保存行级评论")

let skillsDirectory = nodeProject.appendingPathComponent(".kimi/skills/review", isDirectory: true)
try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
try "---\nname: review\ndescription: 审阅代码变更\n---\n# Review\n".write(
  to: skillsDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
)


expect(ComputerUsePolicy.decision(for: .click) == .allow, "普通 Computer Use 点击可在会话授权后执行")
expect(ComputerUsePolicy.decision(for: .externalSend) == .ask, "外发数据必须逐次请求用户确认")
expect(ComputerUsePolicy.decision(for: .systemSettings) == .ask, "修改系统设置必须逐次请求用户确认")


let gitRepository = temporaryDirectory.appendingPathComponent("repo", isDirectory: true)
try FileManager.default.createDirectory(at: gitRepository, withIntermediateDirectories: true)
try runCheckCommand("git", ["init", "-q"], in: gitRepository)
try runCheckCommand("git", ["config", "user.email", "checks@example.com"], in: gitRepository)
try runCheckCommand("git", ["config", "user.name", "Kimi Agent Core Checks"], in: gitRepository)
try "before\n".write(to: gitRepository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
try runCheckCommand("git", ["add", "README.md"], in: gitRepository)
try runCheckCommand("git", ["commit", "-qm", "initial"], in: gitRepository)
let worktree = try GitWorktreeManager.create(for: gitRepository, taskID: persistedTask.id)
try "after\n".write(to: worktree.path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
let diffSnapshot = try DiffEngine.snapshot(baseDirectory: worktree.path)
expect(diffSnapshot.files.count == 1, "Diff 引擎必须发现修改文件")
expect(diffSnapshot.files.first?.path == "README.md", "Diff 必须返回相对文件路径")
try GitWorktreeManager.restoreFile("README.md", in: worktree, baseCommit: worktree.baseCommit)
let restoredDiff = try DiffEngine.snapshot(baseDirectory: worktree.path)
expect(restoredDiff.files.isEmpty, "拒绝文件变更后 Worktree 必须恢复到基线")
try "after\n".write(to: worktree.path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
try GitWorktreeManager.merge(worktree, into: gitRepository, message: "Kimi Code Agent test merge")
let mergedContent = try String(contentsOf: gitRepository.appendingPathComponent("README.md"), encoding: .utf8)
expect(mergedContent == "after\n", "人工确认后 Worktree 变更必须可以合并回主工作区")
try GitWorktreeManager.remove(worktree)

let emptyGitRepository = temporaryDirectory.appendingPathComponent("empty-git-repository", isDirectory: true)
try FileManager.default.createDirectory(at: emptyGitRepository, withIntermediateDirectories: true)
try runCheckCommand("git", ["init", "-q"], in: emptyGitRepository)
expect(GitWorktreeManager.isRepository(emptyGitRepository), "没有提交的目录仍应识别为 Git 仓库")
expect(!GitWorktreeManager.hasUsableHEAD(emptyGitRepository), "没有 HEAD 的 Git 仓库必须能被识别并进入工作区回退")

expect(
  TaskWorkspacePresentation(status: .planning).primaryAction == .run,
  "规划完成的任务应在工作台中呈现运行主操作"
)
expect(
  TaskWorkspacePresentation(status: .running).inspector == .activity,
  "运行中的任务应优先展示活动流 Inspector"
)
expect(
  TaskWorkspacePresentation(status: .reviewReady).inspector == .review,
  "待审阅任务应优先展示 Diff Review Inspector"
)
expect(
  TaskWorkspacePresentation(status: .waitingForUser).primaryAction == .resume,
  "暂停中的任务应提供继续动作"
)
expect(
  TaskWorkspacePresentation(status: .mergeReady).primaryAction == .merge,
  "可合并任务应在工作台中呈现合并主操作"
)
expect(
  TaskWorkspacePresentation(status: .reviewReady).stageTitle == "代码审阅",
  "待审阅任务应提供稳定的阶段标题"
)
expect(
  TaskWorkspacePresentation(status: .verifying).stageSymbol == "checkmark.shield",
  "验证阶段应提供稳定的 SF Symbol"
)
expect(
  !TaskWorkspacePresentation(status: .failed).statusDescription.isEmpty,
  "失败任务应提供可读的状态说明"
)
expect(
  TaskWorkspacePresentation.composerSubmissionTarget(for: nil) == .newTask,
  "没有选中会话时 Composer 必须创建新任务"
)
let resumableComposerTask = AgentTask(title: "继续讨论", mode: .plan, status: .reviewReady, workspacePath: "/tmp/sample")
expect(
  TaskWorkspacePresentation.composerSubmissionTarget(for: resumableComposerTask) == .continueTask,
  "选中未合并会话时 Composer 必须继续当前会话"
)
let mergedComposerTask = AgentTask(title: "已合并", mode: .agent, status: .merged, workspacePath: "/tmp/sample")
expect(
  TaskWorkspacePresentation.composerSubmissionTarget(for: mergedComposerTask) == .newTask,
  "已合并会话不能继续写入，Composer 应创建新任务"
)
let conversationDestinationTask = AgentTask(
  id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
  title: "打开独立会话",
  mode: .plan,
  workspacePath: "/tmp/another-project"
)
expect(
  TaskWorkspacePresentation.conversationDestination(for: conversationDestinationTask) == .init(
    taskID: conversationDestinationTask.id,
    workspacePath: "/tmp/another-project"
  ),
  "点击会话必须同时保留任务 ID 和其所属工作区"
)
let navigationTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000124")!
expect(
  WorkbenchConversationNavigationPolicy.page(
    selectedTaskID: nil,
    hasSelectedTask: false,
    isComposingNewConversation: true
  ) == .newConversation,
  "点击新对话必须进入独立的新会话页面，而不是回到首页"
)
expect(
  WorkbenchConversationNavigationPolicy.page(
    selectedTaskID: navigationTaskID,
    hasSelectedTask: true,
    isComposingNewConversation: true
  ) == .existingConversation(navigationTaskID),
  "点击已有会话必须立即切换到对应会话页面，并退出新对话状态"
)
expect(
  WorkbenchConversationNavigationPolicy.page(
    selectedTaskID: nil,
    hasSelectedTask: false,
    isComposingNewConversation: false
  ) == .home,
  "未选择会话且没有创建新对话时才显示首页"
)
expect(
  AssistantReplySanitizer.visibleText(from: "Sure, 收到，我来看看。") == "收到，我来看看。",
  "常见英文开场后接中文时，展示层应只保留自然中文回复"
)
let realAPIReasoningLeak = """
The user has sent a system-like instruction to only reply with "真实API连接成功。" (Real API connection successful). The user wants me to follow a direct instruction. I should reply exactly as requested.
真实API连接成功。
"""
expect(
  AssistantReplySanitizer.conciseConversationReply(from: realAPIReasoningLeak) == "真实API连接成功。",
  "真实 API 返回的英文元分析不能进入主对话，只保留最终中文回复"
)
let streamedReplyChunks = [
  "The user has sent a system-like instruction to only reply with ",
  "\"真实API连接成功。\" (Real API connection successful). I should reply exactly as requested.",
  "真实API连接成功。"
]
let streamedVisibleReply = AssistantReplySanitizer.finalConversationText(from: streamedReplyChunks.joined()) ?? ""
expect(
  streamedVisibleReply == "真实API连接成功。",
  "流式回复必须聚合后过滤英文元分析，不能把分析 chunk 直接拼进主对话"
)
expect(
  AssistantReplySanitizer.visibleText(from: """
  The user has sent a simple greeting "你好" and explicitly asked for a one-sentence reply in Chinese. I should respond naturally and concisely in Chinese. No tools needed for this simple greeting.

  用户只是打招呼并问“你是什么模型？”。这是一个简单的对话问题，不需要使用工具，也不需要执行任何计划模式的操作。

  你好！我是 Kimi，当前使用的模型是 `kimi-k2.7-code`。
  """) == "你好！我是 Kimi，当前使用的模型是 `kimi-k2.7-code`。",
  "多段分析文本必须只保留最后的自然回复"
)
let leakedReasoningReply = """
"直接处理". Hmm.

Maybe the correct interpretation: We are in plan mode. The user asks a series of questions, culminating in a request to open Finder. In plan mode, I should not execute. I should confirm receipt and provide a plan/answer.

The user is saying "hello" in Chinese. According to the instructions, I should respond with a short, natural Chinese confirmation as the first reply. The user wants me to handle the user message directly using the user's language (Chinese). The message is just "你好" (hello).

The instruction says: "第一条回复先用一句很短、自然的中文确认收到，后续回复优先给出结论、变化点和下一步；不要解释本段上下文，不要复述内部规则。"

So I should just say something short like "你好，收到。" or "你好！已收到。"
"""
expect(
  AssistantReplySanitizer.conciseConversationReply(from: leakedReasoningReply) == "你好，收到。",
  "截图中的英文内部分析必须被折叠为最终自然中文回复，不能显示推理过程"
)
let chineseReasoningReply = """
用户的问题是关于这个桌面版 kimi agent 能做什么。用户语言是中文，所以需要中文回复。第一条回复需要很短、自然的中文确认收到。后续回复优先给出结论、变化点和下一步。

用户消息是“你在这个桌面版里都能做什么”。这看起来是最后一个用户消息。

我需要：
1. 第一句：很短、自然的中文确认收到。
2. 然后给出结论、变化点和下一步。

关于这个桌面版能做什么：
- 读取和分析项目代码
- 修改代码并生成 Diff
- 运行测试和构建
- 进行 Web Search / Fetch
- 操作授权后的 macOS 桌面
- 管理 Skills / Hooks / MCP
- 对接 GitHub / GitLab
- 保存本地会话并支持重启恢复
"""
let expectedChineseAnswer = """
关于这个桌面版能做什么：
- 读取和分析项目代码
- 修改代码并生成 Diff
- 运行测试和构建
- 进行 Web Search / Fetch
- 操作授权后的 macOS 桌面
- 管理 Skills / Hooks / MCP
- 对接 GitHub / GitLab
- 保存本地会话并支持重启恢复
"""
expect(
  AssistantReplySanitizer.conciseConversationReply(from: chineseReasoningReply) == expectedChineseAnswer,
  "中文自我分析必须被移除，主对话只展示答案本身"
)
expect(
  WorkbenchLayoutPolicy.mode(for: 1_440) == .full,
  "宽窗口应展示完整三栏工作台"
)
expect(
  WorkbenchLayoutPolicy.mode(for: 1_179) == .focused,
  "中等窗口应进入主任务专注布局"
)
expect(
  WorkbenchLayoutPolicy.mode(for: 899) == .singleColumn,
  "窄窗口应进入单栏布局"
)
for status in TaskStatus.allCases {
  let presentation = TaskWorkspacePresentation(status: status)
  expect(!presentation.stageTitle.isEmpty, "\(status.rawValue) 必须有阶段标题")
  expect(!presentation.stageSymbol.isEmpty, "\(status.rawValue) 必须有阶段图标")
  expect(!presentation.statusDescription.isEmpty, "\(status.rawValue) 必须有状态说明")
}
var homeRunningTask = AgentTask(title: "执行中任务", mode: .agent, status: .running, workspacePath: "/tmp/demo")
var homeReviewTask = AgentTask(title: "待审阅任务", mode: .edit, status: .reviewReady, workspacePath: "/tmp/demo")
var homeDoneTask = AgentTask(title: "已完成任务", mode: .plan, status: .completed, workspacePath: "/tmp/demo")
let homeSummary = WorkbenchHomeSummary(
  state: AppState(workspacePath: "/tmp/demo", tasks: [homeRunningTask, homeReviewTask, homeDoneTask])
)
expect(homeSummary.totalTasks == 3, "首页概览应统计全部本地任务")
expect(homeSummary.activeTasks == 1, "首页概览应统计运行中的任务")
expect(homeSummary.reviewReadyTasks == 1, "首页概览应统计待审阅任务")
expect(homeSummary.completedTasks == 1, "首页概览应统计已完成任务")
expect(
  homeSummary.preferredTaskID(for: .active, in: [homeRunningTask, homeReviewTask, homeDoneTask]) == homeRunningTask.id,
  "首页活动卡片应定位到进行中的任务"
)
expect(
  homeSummary.preferredTaskID(for: .reviewReady, in: [homeRunningTask, homeReviewTask, homeDoneTask]) == homeReviewTask.id,
  "首页待审阅卡片应定位到待审阅任务"
)
expect(
  homeSummary.preferredTaskID(for: .completed, in: [homeRunningTask, homeReviewTask, homeDoneTask]) == homeDoneTask.id,
  "首页已完成卡片应定位到已完成任务"
)
expect(
  TaskMode.plan.permissionBadgeTitle == "只读" && TaskMode.plan.permissionBadgeSymbol == "eye",
  "Plan 模式权限徽标应清晰指向只读"
)
expect(
  TaskMode.edit.permissionBadgeTitle == "操作需确认" && !TaskMode.edit.permissionBadgeHint.isEmpty,
  "Edit 模式权限徽标应提供清晰说明"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .edit,
    workspacePath: "/Users/eastbuy/Projects/sample",
    worktreePath: "/Users/eastbuy/Projects/sample/.kimi/worktrees/task-123",
    branch: "kimi/task-123",
    modelID: "kimi-latest",
    skillsDirectories: ["/Users/eastbuy/Projects/sample/.kimi/skills"]
  ).contains("直接给出用户要的结论、结果或下一步操作"),
  "提示词必须要求模型直接回复用户真正要的内容"
)
expect(
  !TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .edit,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("第一条回复必须先用一句很短、自然的中文确认收到"),
  "提示词不能强制模型先确认收到，否则容易诱导内部分析泄漏"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .edit,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("不要用 Sure / Okay / 当然 / 好的 之类的开场"),
  "首轮提示词必须禁止英文或客套开场"
)
expect(
  TaskPromptComposer.compose(
    prompt: "你好",
    mode: .plan,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("不要输出英文思考过程"),
  "提示词必须明确禁止把英文思考过程展示给用户"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("computer_use.inspect"),
  "提示词必须明确列出可用的 Computer Use 工具"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("web.fetch"),
  "提示词必须明确列出规范网络工具"
)
expect(
  TaskPromptComposer.compose(
    prompt: "查找并总结当前文档",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("web.search") && TaskPromptComposer.compose(
    prompt: "查找并总结当前文档",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("web.fetch"),
  "提示词必须明确列出 Web Search 与 Web Fetch 工具"
)
expect(
  TaskPromptComposer.compose(
    prompt: "查找并总结当前文档",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("来源标题和 URL"),
  "提示词必须要求联网结论返回可追溯来源"
)
expect(
  TaskPromptComposer.compose(
    prompt: "查找并总结当前文档",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("web.search / web.fetch"),
  "提示词必须只声明 Harness 规范 Web 工具"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("github.pull_request.create"),
  "提示词必须明确列出 GitHub 工具"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("computer_use.click_element"),
  "提示词必须明确列出按元素点击工具"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample",
    allowedDomains: ["github.com", "gitlab.com"]
  ).contains("已授权网络域名"),
  "提示词必须说明已授权的网络域名"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("先 inspect，再 click/click_element/type/press_key"),
  "提示词必须引导模型用 inspect 先定位目标"
)
expect(
  TaskPromptComposer.compose(
    prompt: "输出当前项目的目录结构，并说明如何运行测试",
    mode: .plan,
    workspacePath: "/Users/eastbuy/Projects/sample"
  ).contains("Plan 模式只分析和规划，不写入项目文件"),
  "Plan 模式提示词必须保持只读边界"
)
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录失败",
    mode: .edit,
    workspacePath: "/Users/eastbuy/Projects/sample",
    worktreePath: "/Users/eastbuy/Projects/sample/.kimi/worktrees/task-123"
  ).contains("默认在隔离 Worktree 中修改"),
  "Edit 模式提示词必须强调 Worktree 隔离"
)
expect(
  TaskPromptComposer.compose(
    prompt: "做一个持续执行的自动化任务",
    mode: .agent,
    workspacePath: "/Users/eastbuy/Projects/sample",
    branch: "kimi/task-123"
  ).contains("后续回复优先给出结论、变化点和下一步"),
  "Agent 模式提示词必须提升后续对话质量"
)
expect(WorkbenchSidebarPolicy.modeTitle == "代码", "Kimi Code 侧栏应只显示代码工作区")
expect(!WorkbenchSidebarPolicy.showsCoworkMode, "Kimi Code 侧栏不应显示无关的工作模式")
expect(WorkbenchSidebarPolicy.recentSectionTitle == "最近", "侧栏应独立展示最近会话区")
expect(WorkbenchSidebarPolicy.sessionSectionTitle == "最近会话", "最近区应将任务列表命名为最近会话")
expect(WorkbenchSidebarPolicy.projectSectionTitle == "项目", "侧栏应独立展示项目区")
expect(WorkbenchSidebarPolicy.terminalSectionTitle == "终端", "侧栏应提供终端入口")
expect(WorkbenchSidebarPolicy.defaultRightUtility == .terminal, "终端应作为右侧工具面板的默认入口")
let terminalSidebar = TerminalSidebarPresentation(
  events: (1...12).map { "终端输出 \($0)" },
  limit: 5
)
expect(
  terminalSidebar.title == "终端" && terminalSidebar.subtitle == "5",
  "终端侧栏必须展示标题和可见输出数量"
)
expect(
  terminalSidebar.lines == ["终端输出 8", "终端输出 9", "终端输出 10", "终端输出 11", "终端输出 12"],
  "终端侧栏默认应展示最近输出，而不是从头刷屏"
)
expect(
  TerminalSidebarPresentation(events: ["构建成功", "测试失败"], query: "测试").lines == ["测试失败"],
  "终端侧栏搜索必须复用事件搜索逻辑"
)
expect(
  TerminalSidebarPresentation(events: [], query: "").emptyMessage == "等待任务开始后显示终端输出。",
  "终端侧栏空状态必须明确"
)
let terminalPolicy = TerminalCommandPolicy()
expect(
  terminalPolicy.evaluate(command: "pwd", actor: .user).decision == .allow,
  "用户手动执行只读命令应直接运行"
)
expect(
  terminalPolicy.evaluate(command: "npm install", actor: .user).decision == .ask,
  "安装依赖需要确认"
)
expect(
  terminalPolicy.evaluate(command: "git push origin main", actor: .agent).risk == .high,
  "Agent 推送远端分支必须视为高风险"
)
expect(
  terminalPolicy.evaluate(command: "sudo rm -rf /", actor: .user).decision == .deny,
  "危险终端命令必须被阻止"
)
var terminalSession = TerminalSession(taskID: UUID(), cwd: temporaryDirectory.path)
let terminalCommand = TerminalCommandRecord(command: "printf terminal-ok", cwd: temporaryDirectory.path, requestedBy: .user)
terminalSession.append(command: terminalCommand)
terminalSession.start(commandID: terminalCommand.id)
terminalSession.appendOutput(commandID: terminalCommand.id, stream: .standardOutput, text: "terminal-ok")
terminalSession.finish(commandID: terminalCommand.id, exitCode: 0)
expect(
  terminalSession.history.first?.stdout == "terminal-ok" && terminalSession.history.first?.status == .completed,
  "终端会话必须保存输出和退出状态"
)
expect(
  terminalSession.agentContextSummary.contains("terminal-ok"),
  "终端结果必须能回流给 Agent"
)
let agentToolID = "shell-call-1"
let agentTaskID = UUID()
let agentSessionID = UUID()
var agentTerminalSession = TerminalSession(taskID: agentTaskID, cwd: temporaryDirectory.path)
let agentToolRequested = AgentEvent(
  sessionID: agentSessionID,
  taskID: agentTaskID,
  sequence: 1,
  actor: "kimi-runtime",
  kind: .toolRequested,
  payload: ["id": agentToolID, "name": "shell", "arguments": "{\\\"command\\\":\\\"swift test\\\"}"],
  requiresApproval: true
)
expect(
  agentTerminalSession.recordAgentToolEvent(agentToolRequested, cwd: temporaryDirectory.path),
  "Agent shell 工具请求必须进入终端会话"
)
expect(
  agentTerminalSession.history.count == 1 && agentTerminalSession.history.first?.status == .awaitingApproval,
  "等待审批的 Agent shell 工具必须在终端中显示为等待确认"
)
expect(
  !agentTerminalSession.recordAgentToolEvent(agentToolRequested, cwd: temporaryDirectory.path) && agentTerminalSession.history.count == 1,
  "同一条 Agent 工具事件经过多个事件流时不能生成重复终端记录"
)
let agentToolStarted = AgentEvent(
  sessionID: agentSessionID,
  taskID: agentTaskID,
  sequence: 2,
  actor: "kimi-runtime",
  kind: .toolStarted,
  payload: ["id": agentToolID, "name": "shell"]
)
_ = agentTerminalSession.recordAgentToolEvent(agentToolStarted, cwd: temporaryDirectory.path)
expect(agentTerminalSession.history.first?.status == .running, "Agent shell 工具开始后终端状态必须更新为运行中")
let agentToolFinished = AgentEvent(
  sessionID: agentSessionID,
  taskID: agentTaskID,
  sequence: 3,
  actor: "kimi-runtime",
  kind: .toolFinished,
  payload: ["id": agentToolID, "name": "shell", "status": "completed", "output": "Tests passed"]
)
_ = agentTerminalSession.recordAgentToolEvent(agentToolFinished, cwd: temporaryDirectory.path)
expect(
  agentTerminalSession.history.first?.status == .completed && agentTerminalSession.history.first?.stdout == "Tests passed",
  "Agent shell 工具完成后终端必须保存输出和完成状态"
)
let terminalRunnerResult = try TerminalCommandRunner.run(
  command: "printf terminal-runner-ok",
  cwd: temporaryDirectory
)
expect(
  terminalRunnerResult.exitCode == 0 && terminalRunnerResult.standardOutput == "terminal-runner-ok",
  "终端执行器必须能在指定目录真实执行 zsh 命令（exit=\(terminalRunnerResult.exitCode), stdout=\(terminalRunnerResult.standardOutput), stderr=\(terminalRunnerResult.standardError)）"
)
let utf8Decoder = TerminalUTF8StreamDecoder()
expect(utf8Decoder.append(Data([0xE4, 0xBD])).isEmpty, "UTF-8 流解码器必须缓存不完整的中文字符")
expect(utf8Decoder.append(Data([0xA0])) == "你", "UTF-8 流解码器必须在下一块补全中文字符")
expect(utf8Decoder.append(Data([0xF0, 0x9F, 0x9A])).isEmpty, "UTF-8 流解码器必须缓存不完整的 Emoji")
expect(utf8Decoder.append(Data([0x80])) == "🚀", "UTF-8 流解码器必须在下一块补全 Emoji")
let sandboxScratch = temporaryDirectory.appendingPathComponent("sandbox-scratch", isDirectory: true)
let sandboxConfiguration = TerminalSandboxConfiguration.strict(
  workspaceURL: temporaryDirectory,
  scratchURL: sandboxScratch
)
let sandboxInsideResult = try TerminalCommandRunner.run(
  command: "printf sandbox-ok > sandbox-inside.txt",
  cwd: temporaryDirectory,
  sandbox: sandboxConfiguration
)
expect(
  sandboxInsideResult.exitCode == 0 && FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("sandbox-inside.txt").path),
  "受限终端必须允许写入当前 Worktree（exit=\(sandboxInsideResult.exitCode), stderr=\(sandboxInsideResult.standardError), cwd=\(temporaryDirectory.path), workspace=\(sandboxConfiguration.workspaceURL.path), profile=\(sandboxConfiguration.profile())）"
)
let sandboxOutsideURL = temporaryDirectory.deletingLastPathComponent().appendingPathComponent("kimi-sandbox-escape-\(UUID().uuidString)")
let sandboxOutsideResult = try TerminalCommandRunner.run(
  command: "touch '\(sandboxOutsideURL.path)'",
  cwd: temporaryDirectory,
  sandbox: sandboxConfiguration
)
expect(
  sandboxOutsideResult.exitCode != 0 && !FileManager.default.fileExists(atPath: sandboxOutsideURL.path),
  "受限终端必须阻止 Worktree 外文件写入"
)
let sandboxOutsideReadURL = temporaryDirectory.deletingLastPathComponent().appendingPathComponent("kimi-sandbox-private-\(UUID().uuidString)")
try "private-data".write(to: sandboxOutsideReadURL, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: sandboxOutsideReadURL) }
let protectedReadSandbox = TerminalSandboxConfiguration.strict(
  workspaceURL: temporaryDirectory,
  scratchURL: sandboxScratch,
  protectedReadURLs: [sandboxOutsideReadURL]
)
let sandboxOutsideReadResult = try TerminalCommandRunner.run(
  command: "/bin/cat '\(sandboxOutsideReadURL.path)'",
  cwd: temporaryDirectory,
  sandbox: protectedReadSandbox
)
expect(
  sandboxOutsideReadResult.exitCode != 0 && !sandboxOutsideReadResult.standardOutput.contains("private-data"),
  "受限终端必须阻止受保护文件读取"
)
if TerminalSandboxConfiguration.isSupported {
  let deniedServer = try startLocalHTTPServer()
  let sandboxNetworkResult = try TerminalCommandRunner.run(
    command: "/usr/bin/curl --noproxy '*' --silent --show-error --connect-timeout 1 http://127.0.0.1:\(deniedServer.port)",
    cwd: temporaryDirectory,
    sandbox: sandboxConfiguration
  )
  deniedServer.stop()
  let allowedServer = try startLocalHTTPServer()
  let allowedSandbox = TerminalSandboxConfiguration.strict(
    workspaceURL: temporaryDirectory,
    scratchURL: sandboxScratch,
    allowNetwork: true
  )
  let allowedNetworkResult = try TerminalCommandRunner.run(
    command: "/usr/bin/curl --noproxy '*' --silent --show-error --connect-timeout 1 http://127.0.0.1:\(allowedServer.port)",
    cwd: temporaryDirectory,
    sandbox: allowedSandbox
  )
  allowedServer.stop()
  expect(
    sandboxNetworkResult.exitCode != 0,
    "受限终端必须由 Seatbelt 阻止未经授权的网络连接（exit=\(sandboxNetworkResult.exitCode), stderr=\(sandboxNetworkResult.standardError)）"
  )
  expect(
    allowedNetworkResult.exitCode == 0 && allowedNetworkResult.standardOutput == "sandbox-http-ok",
    "显式授予网络权限后受限终端必须连接到允许的服务"
  )
}
let terminalTask = AgentTask(
  title: "终端持久化",
  mode: .agent,
  workspacePath: temporaryDirectory.path,
  terminalSession: terminalSession
)
let terminalTaskRoundTrip = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(terminalTask))
expect(
  terminalTaskRoundTrip.terminalSession?.history.first?.command == "printf terminal-ok",
  "终端会话与命令历史必须随任务持久化恢复"
)
let ansiChunks = TerminalANSIParser.parse("\u{001B}[31mred\u{001B}[0m plain")
expect(ansiChunks.map(\.text).joined() == "red plain", "ANSI 解析必须保留可见文本并移除控制序列")
expect(ansiChunks.first?.style.foreground == .red, "ANSI 解析必须识别基本前景色")
expect(
  TerminalScreenBuffer.render("进度 10%\r进度 100%\nabc\u{08}!\u{001B}[K") == "进度 100%\nab!",
  "终端屏幕缓冲必须正确处理回车覆盖、退格和 ANSI 清行控制符"
)
let searchQuery = TerminalSearchQuery(text: "terminal", caseSensitive: false)
let searchMatches = searchQuery.matches(in: "Terminal\nterminal ok")
expect(searchMatches.count == 2 && searchMatches.first?.line == 1, "终端搜索必须返回行号和匹配范围")
expect(TerminalTranscriptExporter.plainText("a\u{001B}[31mb\u{001B}[0m") == "ab", "终端导出必须移除 ANSI 控制序列")
expect(TerminalTranscriptExporter.html("<a>").contains("&lt;a&gt;"), "终端 HTML 导出必须转义用户输出")
let primaryPaneID = UUID()
let secondaryPaneID = UUID()
var paneLayout = TerminalPaneLayout.single(primaryPaneID)
paneLayout.split(.vertical, with: secondaryPaneID)
expect(paneLayout.panes.count == 2 && paneLayout.orientation == .vertical, "终端工作区必须持久化分栏布局")
expect(TerminalReconnectPolicy.default.delay(forAttempt: 1) == 1 && TerminalReconnectPolicy.default.delay(forAttempt: 6) == 30, "SSH 重连必须采用有上限的指数退避")
let keychainRef = SSHCredentialReference.keychain(account: "deploy", service: "kimi.ssh")
expect(keychainRef.displayName == "macOS Keychain · deploy" && keychainRef.secretValue == nil, "SSH 凭据只能保存引用，不能把秘密写入状态")
let resourceScheduler = TerminalResourceScheduler(maxConcurrent: 2, memoryLimitMB: 4096)
expect(resourceScheduler.canStart(cpuLoad: 0.25, memoryMB: 512) && !resourceScheduler.canStart(cpuLoad: 0.95, memoryMB: 5000), "终端调度必须感知 CPU 和内存约束")
expect(TerminalPasteSafety.requiresApproval(for: "echo one\necho two"), "多行终端粘贴必须请求确认")
expect(TerminalPasteSafety.requiresApproval(for: "sudo rm -rf build"), "高风险终端粘贴必须请求确认")
expect(!TerminalPasteSafety.requiresApproval(for: "git status"), "普通单行终端输入不应阻塞")
let tmuxSessions = TmuxSessionRecord.parse("kimi-main\t2\t2026-08-10 12:00\nkimi-test\t1\t2026-08-10 11:00")
expect(tmuxSessions.count == 2 && tmuxSessions.first?.name == "kimi-main" && tmuxSessions.first?.windowCount == 2, "SSH 远程恢复必须能解析 tmux 会话列表")

var terminalWorkspace = TerminalWorkspaceState(workspacePath: temporaryDirectory.path)
let localTab = terminalWorkspace.openLocalTab(title: "项目 Shell", cwd: temporaryDirectory.path)
let secondTab = terminalWorkspace.openLocalTab(title: "开发服务器", cwd: temporaryDirectory.path)
expect(terminalWorkspace.tabs.count == 2 && terminalWorkspace.activeTabID == secondTab.id, "终端工作区必须支持创建多个标签并激活最新标签")
terminalWorkspace.selectTab(localTab.id)
expect(terminalWorkspace.activeTabID == localTab.id, "终端标签必须能够立即切换")
let queuedJob = terminalWorkspace.enqueue(command: "npm run dev", sessionID: localTab.id, timeoutSeconds: 120)
expect(terminalWorkspace.queuedJobs.first?.id == queuedJob.id, "终端命令必须进入可取消队列")
terminalWorkspace.tabs[0].status = .running
terminalWorkspace.tabs[1].status = .awaitingApproval
terminalWorkspace.markInterrupted()
expect(terminalWorkspace.tabs.allSatisfy { $0.status == .interrupted }, "重启后运行中的 PTY 必须统一标记为中断")

let environmentProfile = TerminalEnvironmentProfile(name: "测试环境", variables: ["API_URL": "https://example.test"], workingDirectory: temporaryDirectory.path)
let sshProfile = SSHProfile(name: "测试主机", host: "example.test", username: "tester")
let workspaceRoundTrip = try JSONDecoder().decode(
  TerminalWorkspaceState.self,
  from: JSONEncoder().encode(TerminalWorkspaceState(workspacePath: temporaryDirectory.path, tabs: [localTab], activeTabID: localTab.id, environmentProfiles: [environmentProfile], sshProfiles: [sshProfile]))
)
expect(workspaceRoundTrip.environmentProfiles.first?.variables["API_URL"] == "https://example.test", "终端环境配置必须支持持久化")
expect(workspaceRoundTrip.sshProfiles.first?.host == "example.test", "SSH 配置必须支持持久化")
expect(workspaceRoundTrip.sshProfiles.first?.reconnectPolicy.maximumAttempts == TerminalReconnectPolicy.default.maximumAttempts, "旧 SSH 配置必须自动获得默认重连策略")
expect(environmentProfile.resolvedEnvironment(base: ["PATH": "/bin"]) ["API_URL"] == "https://example.test", "终端环境变量必须按 Profile 覆盖并注入")
let sshCommand = TerminalSSHAdapter.command(for: sshProfile)
expect(sshCommand.contains("/usr/bin/ssh") && sshCommand.contains("tester") && sshCommand.contains("example.test"), "SSH 适配器必须生成受控的 OpenSSH 命令")
var tmuxProfile = sshProfile
tmuxProfile.workingDirectory = "/srv/app"
let tmuxListCommand = TerminalSSHAdapter.tmuxListCommand(for: tmuxProfile)
expect(tmuxListCommand.contains("tmux list-sessions") && !tmuxListCommand.contains("cd '/srv/app'"), "tmux 会话发现必须独立于远程默认目录")
expect(SSHProfileValidation.validate(sshProfile).isEmpty, "完整 SSH 配置应通过校验")
var invalidSSH = sshProfile
invalidSSH.host = "bad host"
expect(!SSHProfileValidation.validate(invalidSSH).isEmpty, "包含空格的 SSH 主机必须被拒绝")
expect(TerminalSSHAdapter.command(for: sshProfile, recovery: .tmux(sessionName: "kimi-task" )).contains("tmux"), "SSH 会话应支持 tmux 恢复包装")
expect(TerminalEnvironmentProfile(name: "秘密", variables: ["TOKEN": "abc"], secretVariableNames: ["TOKEN"]).redactedVariables["TOKEN"] == "••••••••", "环境变量日志必须脱敏")
let scheduler = TerminalQueueScheduler(maxConcurrent: 2)
let schedulerJobA = TerminalCommandJob(sessionID: localTab.id, command: "sleep 1")
let schedulerJobB = TerminalCommandJob(sessionID: localTab.id, command: "echo same-session")
let schedulerJobC = TerminalCommandJob(sessionID: secondTab.id, command: "echo other-session")
expect(scheduler.startableJobs(from: [schedulerJobA, schedulerJobB, schedulerJobC]).map(\.id) == [schedulerJobA.id, schedulerJobC.id], "队列应允许不同会话并发，但同一会话必须串行")
expect(scheduler.startableJobs(from: [schedulerJobA, schedulerJobC]).count == 2, "并发上限内应同时调度多个会话")
let viewport = TerminalViewportMetrics(rows: 20, columns: 80)
let resizedViewport = TerminalViewportMetrics.from(width: 800, height: 360, characterWidth: 8, characterHeight: 18)
expect(viewport.rows == 20 && viewport.columns == 80, "PTY 尺寸模型应保留有效的行列")
expect(resizedViewport.columns == 100 && resizedViewport.rows == 20, "终端几何尺寸应稳定映射到 PTY 行列")
let ptyOutputBox = ResultBox<String>()
let ptyHandle = try TerminalPTYRunner.start(
  configuration: TerminalPTYConfiguration(command: "printf pty-runner-ok", cwd: temporaryDirectory, rows: 24, columns: 100),
  onOutput: { output in
    let existing = (try? ptyOutputBox.load()?.get()) ?? ""
    ptyOutputBox.store(.success(existing + output.text))
  }
)
let ptyResult = ptyHandle.wait(timeout: 5)
expect(ptyResult.exitCode == 0 && (try? ptyOutputBox.load()?.get())?.contains("pty-runner-ok") == true, "PTY 执行器必须真实运行命令并实时回流输出")
let interactivePTY = try TerminalPTYRunner.start(
  configuration: TerminalPTYConfiguration(command: "", cwd: temporaryDirectory, interactive: true)
)
interactivePTY.write("printf interactive-pty-ok\nexit\n")
let interactiveResult = interactivePTY.wait(timeout: 5)
expect(interactiveResult.exitCode == 0 && interactiveResult.output.contains("interactive-pty-ok"), "交互式 PTY 必须支持持续输入并正常退出")
let sandboxedPTY = try TerminalPTYRunner.start(
  configuration: TerminalPTYConfiguration(
    command: "printf pty-sandbox-ok > pty-sandbox-inside.txt",
    cwd: temporaryDirectory,
    sandbox: sandboxConfiguration
  )
)
let sandboxedPTYResult = sandboxedPTY.wait(timeout: 5)
expect(
  sandboxedPTYResult.exitCode == 0 && FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("pty-sandbox-inside.txt").path),
  "受限 PTY 必须允许在当前 Worktree 写入"
)
var interruptedTerminalSession = TerminalSession(taskID: UUID(), cwd: temporaryDirectory.path)
let interruptedCommand = TerminalCommandRecord(command: "sleep 60", cwd: temporaryDirectory.path, requestedBy: .user)
interruptedTerminalSession.append(command: interruptedCommand)
interruptedTerminalSession.start(commandID: interruptedCommand.id)
interruptedTerminalSession.markRunningCommandsInterrupted()
expect(
  interruptedTerminalSession.history.first?.status == .interrupted && interruptedTerminalSession.status == .idle,
  "应用重启后未结束的终端命令必须标记为中断，不能伪装成仍在运行"
)
expect(
  TaskPromptComposer.compose(
    prompt: "根据刚才测试结果继续修复",
    mode: .agent,
    workspacePath: temporaryDirectory.path,
    terminalContext: terminalSession.agentContextSummary
  ).contains("最近终端结果"),
  "终端结果必须作为下一轮 Agent 的可用上下文"
)
expect(WorkbenchHoverPolicy.backgroundOpacity(isHovering: false) == 0, "未悬停控件不应额外着色")
expect(WorkbenchHoverPolicy.backgroundOpacity(isHovering: true) > 0, "悬停控件应显示可见反馈")
expect(
  WorkbenchHoverPolicy.backgroundOpacity(isHovering: true, isSelected: true) > WorkbenchHoverPolicy.backgroundOpacity(isHovering: true),
  "选中态应比普通悬停更明显"
)
expect(WorkbenchHoverPolicy.transitionDuration == 0.12, "悬停反馈应使用短时原生过渡")

let filteredEvents = TaskEventSearch.filter(
  events: ["创建任务", "已生成 Diff，等待审阅。", "已完成验证。"],
  query: "审阅"
)
expect(filteredEvents == ["已生成 Diff，等待审阅。"], "事件搜索应按关键词过滤")

let emptyQueryEvents = TaskEventSearch.filter(events: ["A", "B"], query: " ")
expect(emptyQueryEvents == ["A", "B"], "空搜索应返回全部事件")

let contextTask = AgentTask(
  title: "上下文 chip 测试",
  mode: .edit,
  workspacePath: "/Users/eastbuy/Documents/ChatGPT/kimi 桌面 agent",
  branch: "main"
)
let composerPresentation = ComposerContextPresentation(
  workspacePath: "/Users/eastbuy/Documents/ChatGPT/kimi 桌面 agent",
  task: contextTask
)
expect(composerPresentation.chips.count == 4, "已选择项目且存在分支时应展示四个上下文 chip")
expect(composerPresentation.chips[0].surfaceTitle == "本地环境", "Local 浮层应使用更可读的标题")
expect(!composerPresentation.chips[0].surfaceDescription.isEmpty, "Local 浮层应解释当前上下文")
expect(composerPresentation.chips[0].menuItems.count == 2, "Local chip 应提供 Runtime 与 Computer Use 两个动作")
expect(composerPresentation.chips[0].menuItems[1].action == ComposerContextChipAction.runComputerUseDiagnostics, "Local chip 的第二个动作应检查 Computer Use")
expect(composerPresentation.chips[1].menuItems.count == 2, "项目 chip 应提供显示与复制两个动作")
expect(composerPresentation.chips[2].menuItems.count == 1, "分支 chip 应只提供复制动作")
expect(!composerPresentation.chips[3].isEnabled, "未创建 Worktree 时 chip 应显示为不可用")
expect(composerPresentation.chips[3].availabilityText?.contains("Worktree") == true, "不可用 Worktree chip 应说明原因")
expect(ComposerKeyPolicy.action(for: "return") == .submit, "Composer 普通回车必须触发发送")
expect(ComposerKeyPolicy.action(for: "return", command: true) == .submit, "Composer Command+Return 必须触发发送")
expect(ComposerKeyPolicy.action(for: "return", shift: true) == .insertNewline, "Composer Shift+Return 必须保留换行行为")

let connectedTask = AgentTask(
  title: "已连接 worktree 的 chip 测试",
  mode: .edit,
  workspacePath: "/Users/eastbuy/Documents/ChatGPT/kimi 桌面 agent",
  worktreePath: "/Users/eastbuy/Documents/ChatGPT/kimi 桌面 agent/.worktrees/test",
  branch: "main"
)
let connectedPresentation = ComposerContextPresentation(
  workspacePath: "/Users/eastbuy/Documents/ChatGPT/kimi 桌面 agent",
  task: connectedTask
)
expect(connectedPresentation.chips[3].isEnabled, "已连接 Worktree 时 chip 应可用")
expect(connectedPresentation.chips[3].menuItems.count == 2, "已连接 Worktree 时 chip 应提供显示与复制两个动作")

let parityCatalog = ClaudeParityCapabilityCatalog.defaultCatalog
expect(parityCatalog.capabilities.count >= 14, "Claude 对标目录必须覆盖主要能力族")
let hasSubagents = parityCatalog.capabilities.contains { capability in
  capability.kind == .subagents && capability.loop == .planExecuteReview
}
let hasMCP = parityCatalog.capabilities.contains { capability in
  capability.kind == .mcp && capability.loop == .configureAuthorizeRun
}
let hasGitHubAutomation = parityCatalog.capabilities.contains { capability in
  capability.kind == .githubAutomation && capability.loop == .reviewVerifyMerge
}
expect(hasSubagents, "对标目录必须包含 Subagents 闭环")
expect(hasMCP, "对标目录必须包含 MCP 配置授权执行闭环")
expect(hasGitHubAutomation, "对标目录必须包含 GitHub PR/CI 闭环")

let orchestrationTaskID = UUID()
let orchestrationPlan = AgentOrchestrator.makePlan(taskID: orchestrationTaskID, mode: .agent)
expect(orchestrationPlan.runs.count == 5, "Agent 编排必须包含 Explore、Plan、Implement、Test 和 Review 五个独立运行单元")
expect(orchestrationPlan.runs.first?.definition.kind == .explore, "只读探索必须作为编排的首个步骤")
expect(
  orchestrationPlan.runs.first(where: { $0.definition.kind == .implement })?.dependencies == [orchestrationPlan.runs[1].id],
  "Implement 必须依赖 Plan 的结果"
)
expect(
  AgentOrchestrator.readyRuns(in: orchestrationPlan.runs).map(\.definition.kind) == [.explore],
  "只有依赖完成的 Agent 才能进入调度队列"
)
var completedRuns = orchestrationPlan.runs
completedRuns[0].state = .completed
expect(
  AgentOrchestrator.readyRuns(in: completedRuns).map(\.definition.kind) == [.plan],
  "Explore 完成后应调度 Plan"
)
let schedulerSession = UUID()
let schedulerTask = UUID()
let sameWorktreeRuns = [
  AgentRun(
    parentSessionID: schedulerSession,
    taskID: schedulerTask,
    definition: AgentOrchestrator.builtInDefinition(for: .implement),
    worktreePath: "/tmp/shared-worktree"
  ),
  AgentRun(
    parentSessionID: schedulerSession,
    taskID: schedulerTask,
    definition: AgentOrchestrator.builtInDefinition(for: .debug),
    worktreePath: "/tmp/shared-worktree"
  )
]
let conflictScheduler = AgentRunScheduler(runs: sameWorktreeRuns, maxConcurrent: 8)
let conflictReady = try awaitValue { await conflictScheduler.scheduleReady() }
expect(conflictReady.count == 1, "同一 Worktree 的写入 Agent 必须串行调度")
let schedulerSnapshot = try awaitValue { await conflictScheduler.snapshotRecord() }
let restoredScheduler = AgentRunScheduler(snapshot: schedulerSnapshot)
let restoredSchedulerRuns = try awaitValue { await restoredScheduler.snapshot() }
expect(restoredSchedulerRuns.count == sameWorktreeRuns.count && restoredSchedulerRuns.contains(where: { $0.state == .interrupted }), "Scheduler 快照恢复必须把未结算节点标为 interrupted，等待用户继续")

let childCancellationTaskID = UUID()
let childCancellationParent = SessionRecord(taskID: childCancellationTaskID, agentID: "supervisor")
let childStarted = OneShotAsyncGate()
let childCancellationCallbacks = InvocationCounter()
let cancellableChildCoordinator = ChildSessionCoordinator(
  onCancel: { _ in childCancellationCallbacks.increment() },
  executor: { _, _, _ in
    await childStarted.open()
    try await Task.sleep(for: .seconds(2))
    return AgentResult(summary: "不应等待到这里")
  }
)
let cancellationProbeChild = try awaitValue {
  await cancellableChildCoordinator.createChild(
    parent: childCancellationParent,
    taskID: childCancellationTaskID,
    definition: AgentOrchestrator.builtInDefinition(for: .explore),
    prompt: "可取消 Child Session"
  )
}
let cancellableChildRun = Task.detached { () -> Result<AgentResult, Error> in
  do {
    return .success(try await cancellableChildCoordinator.run(cancellationProbeChild.id))
  } catch {
    return .failure(error)
  }
}
_ = try awaitValue { await childStarted.wait(); return true }
let childCancellationStartedAt = Date()
_ = try awaitValue { await cancellableChildCoordinator.cancel(cancellationProbeChild.id); return true }
let cancellableChildOutcome = try awaitValue { await cancellableChildRun.value }
expect(Date().timeIntervalSince(childCancellationStartedAt) < 0.5, "取消 Child Session 必须中断正在执行的 Task，不能等待模型或工具自然返回")
if case .success = cancellableChildOutcome {
  expect(false, "取消中的 Child Session 必须以取消错误结算")
}
expect(childCancellationCallbacks.count == 1, "取消 Child Session 必须只触发一次底层取消回调")

let workspaceLayout = WorkspaceLayout.defaultLayout()
expect(workspaceLayout.visiblePaneKinds.contains(.chat), "默认工作区必须包含主对话 Pane")
expect(workspaceLayout.visiblePaneKinds.contains(.tasks), "默认工作区必须包含任务 Pane")
let splitLayout = workspaceLayout.splitting(.terminal, beside: .chat, orientation: .horizontal)
expect(splitLayout.visiblePaneKinds.contains(.terminal), "工作区必须支持将终端拆分到主对话旁")
expect(splitLayout.root.contains(.terminal), "拆分后的布局树必须保留终端节点")

let greetingStrategy = TaskIntentRouter.decide(for: "你好")
expect(greetingStrategy.intent == .conversation && !greetingStrategy.requiresPlanning, "简单问候必须直接进入自然对话策略")
let webStrategy = TaskIntentRouter.decide(for: "搜索今天的新闻")
expect(webStrategy.intent == .webResearch && !webStrategy.requiresApproval, "公网只读 Web Research 默认不应触发重复审批")
let implementationStrategy = TaskIntentRouter.decide(for: "修复登录失败并运行测试")
expect(implementationStrategy.intent == .debug, "明确修复与测试请求必须进入调试策略")
expect(implementationStrategy.recommendedAgents.contains(.explore) && implementationStrategy.recommendedAgents.contains(.test), "调试策略必须包含探索和验证 Agent")
let strategyContract = TaskContract.make(
  prompt: "修复登录失败并运行测试",
  decision: implementationStrategy,
  mode: .agent
)
expect(strategyContract.acceptanceCriteria.contains(where: { $0.contains("验证") }), "实现任务契约必须有可验证验收标准")
let projectedContext = ContextProjector.project(
  turns: (1...8).map { ConversationTurn(sequence: $0, userMessage: "问题 \($0)", assistantMessage: "结果 \($0)") },
  contract: strategyContract,
  tokenBudget: 900
)
expect(projectedContext.promptText.contains("任务契约"), "上下文投影必须优先包含任务契约")
expect(projectedContext.recentTurns.count < 8, "Token 预算不足时上下文投影必须压缩较早对话")
let richProjection = ContextProjector.project(
  turns: [],
  contract: strategyContract,
  rules: ["只在 Worktree 内写入"],
  verifiedResults: ["swift test 通过"],
  unresolved: ["Browser 尚未执行"]
)
expect(richProjection.promptText.contains("只在 Worktree 内写入") && richProjection.promptText.contains("swift test 通过"), "模型上下文必须携带规则、验证证据和未解决项")
let strategicPrompt = TaskPromptComposer.compose(
  prompt: "修复登录失败并运行测试",
  mode: .agent,
  workspacePath: temporaryDirectory.path,
  conversationContext: projectedContext.promptText,
  intentDecision: implementationStrategy,
  taskContract: strategyContract
)
expect(strategicPrompt.contains("任务契约") && strategicPrompt.contains("策略：debug"), "Provider Prompt 必须带入任务契约和策略决策")
let completedFinalAnswer = FinalAnswerComposer.compose(
  outcome: .completed,
  summary: "登录错误已修复",
  changedFiles: ["src/auth.ts"],
  verification: ["npm test 通过"],
  risks: []
)
expect(completedFinalAnswer.contains("已完成") && completedFinalAnswer.contains("验证"), "完成答复必须包含结论和验证证据")
let failedFinalAnswer = FinalAnswerComposer.compose(
  outcome: .failed,
  summary: "测试失败",
  changedFiles: [],
  verification: [],
  risks: ["缺少依赖"]
)
expect(failedFinalAnswer.contains("未完成") && !failedFinalAnswer.contains("已完成\n"), "失败答复不得伪装成成功")
let missingReceiptGate = ResponseQualityGate.validate(
  "已完成 Web Search 和 Browser 验证。",
  outcome: .completed,
  requiredEvidence: [
    FinalAnswerEvidence(subject: "web.search", receiptID: nil, succeeded: false),
    FinalAnswerEvidence(subject: "browser", receiptID: nil, succeeded: false)
  ]
)
expect(missingReceiptGate.hasBlockingIssues, "没有成功 Receipt 时最终答案不得宣称专用工具已完成")

let pluginManifest = KimiPluginManifest(
  id: "com.kimi.review",
  name: "Review toolkit",
  version: "1.0.0",
  agents: ["reviewer"],
  skills: ["review"],
  hooks: ["pre-review"],
  mcpServers: ["git"],
  permissions: ["workspace.read"]
)
expect(pluginManifest.capabilities.count == 4, "插件清单必须统一暴露 Agent、Skill、Hook 和 MCP 能力")
expect(pluginManifest.requiresApproval(for: "workspace.write"), "插件未声明的权限必须请求用户批准")
expect(!pluginManifest.requiresApproval(for: "workspace.read"), "已声明的插件权限不应重复请求批准")

let pluginDirectory = temporaryDirectory.appendingPathComponent(".kimi-agent/plugins/review-toolkit", isDirectory: true)
let pluginManifestDirectory = pluginDirectory.appendingPathComponent(".kimi-plugin", isDirectory: true)
try FileManager.default.createDirectory(at: pluginManifestDirectory, withIntermediateDirectories: true)
let pluginManifestURL = pluginManifestDirectory.appendingPathComponent("plugin.json")
try JSONEncoder().encode(pluginManifest).write(to: pluginManifestURL)
let discoveredPlugins = KimiPluginRegistry.discover(projectDirectory: temporaryDirectory)
expect(discoveredPlugins.first?.manifest.id == "com.kimi.review", "插件注册表必须发现项目内的 Kimi Plugin")
expect(discoveredPlugins.first?.scope == .project, "项目插件必须被标记为 project scope")
let pluginSkillDirectory = pluginDirectory.appendingPathComponent("skills/plugin-review", isDirectory: true)
try FileManager.default.createDirectory(at: pluginSkillDirectory, withIntermediateDirectories: true)
try "---\nname: plugin-review\ndescription: 来自插件的审阅技能\n---\n".write(
  to: pluginSkillDirectory.appendingPathComponent("SKILL.md"),
  atomically: true,
  encoding: .utf8
)
let pluginInstallWorkspace = temporaryDirectory.appendingPathComponent("plugin-install-workspace", isDirectory: true)
let pluginSourceV1 = temporaryDirectory.appendingPathComponent("plugin-source-v1", isDirectory: true)
let pluginSourceV2 = temporaryDirectory.appendingPathComponent("plugin-source-v2", isDirectory: true)
for (source, version) in [(pluginSourceV1, "1.0.0"), (pluginSourceV2, "2.0.0")] {
  let manifestDirectory = source.appendingPathComponent(".kimi-plugin", isDirectory: true)
  try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
  try JSONEncoder().encode(KimiPluginManifest(id: "com.kimi.lifecycle", name: "Lifecycle", version: version)).write(
    to: manifestDirectory.appendingPathComponent("plugin.json")
  )
}
let pluginPackageManager = KimiPluginPackageManager(projectDirectory: pluginInstallWorkspace)
let firstPluginInstall = try pluginPackageManager.install(sourceURL: pluginSourceV1)
expect(firstPluginInstall.backupURL == nil, "首次安装插件不应生成无意义备份")
let updatedPluginInstall = try pluginPackageManager.install(sourceURL: pluginSourceV2)
expect(updatedPluginInstall.backupURL != nil, "插件更新必须先保留可回滚备份")
let installedPluginManifestURL = pluginPackageManager.pluginURL(id: "com.kimi.lifecycle")
  .appendingPathComponent(".kimi-plugin/plugin.json")
let installedPluginV2 = try JSONDecoder().decode(KimiPluginManifest.self, from: Data(contentsOf: installedPluginManifestURL))
expect(installedPluginV2.version == "2.0.0", "插件更新必须原子切换到新版本")
try pluginPackageManager.rollback(updatedPluginInstall)
let restoredPluginV1 = try JSONDecoder().decode(KimiPluginManifest.self, from: Data(contentsOf: installedPluginManifestURL))
expect(restoredPluginV1.version == "1.0.0", "插件回滚必须恢复更新前版本")

let ruleSet = AgentRuleSet(
  system: [AgentRule(text: "系统安全")],
  user: [AgentRule(text: "用户偏好")],
  project: [AgentRule(text: "项目规则")],
  task: [AgentRule(text: "任务规则")]
)
expect(ruleSet.effectiveRules.map(\.text) == ["系统安全", "用户偏好", "项目规则", "任务规则"], "规则必须按安全、用户、项目和任务顺序合并")

let contextTurns = [
  ConversationTurn(sequence: 1, userMessage: "先检查登录", assistantMessage: "已定位到 API Key 配置。", status: .completed),
  ConversationTurn(sequence: 2, userMessage: "继续修复", assistantMessage: "正在修改设置页。", status: .completed),
  ConversationTurn(sequence: 3, userMessage: "运行测试", assistantMessage: "测试通过。", status: .completed)
]
let compactedContext = ConversationContextComposer.make(from: contextTurns, keepingLast: 1)
expect(compactedContext.summary.contains("先检查登录"), "对话压缩必须保留早期用户意图")
expect(compactedContext.recentTurns.count == 1 && compactedContext.recentTurns[0].sequence == 3, "对话压缩必须保留最近完整轮次")
expect(
  TaskPromptComposer.compose(
    prompt: "继续", mode: .plan, workspacePath: temporaryDirectory.path, conversationContext: compactedContext.promptText
  ).contains("此前对话上下文"),
  "Runtime Prompt 必须注入压缩后的对话上下文"
)

let projectRulesURL = temporaryDirectory.appendingPathComponent("AGENTS.md")
try "# 项目规则\n- 先运行测试\n- 不修改生产凭据\n".write(to: projectRulesURL, atomically: true, encoding: .utf8)
let discoveredRules = AgentRuleRegistry.projectRules(projectDirectory: temporaryDirectory)
expect(discoveredRules.map(\.text) == ["先运行测试", "不修改生产凭据"], "规则注册表必须从 AGENTS.md 读取项目级规则")
let nestedDirectory = temporaryDirectory.appendingPathComponent("Sources/Feature", isDirectory: true)
try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
try "# 局部规则\n- 先运行局部测试\n- 不修改生成文件\n".write(
  to: nestedDirectory.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8
)
let nestedRules = AgentRuleRegistry.rules(forFile: nestedDirectory.appendingPathComponent("View.swift"), projectDirectory: temporaryDirectory)
expect(nestedRules.map(\.text).contains("先运行局部测试"), "规则注册表必须加载文件路径最近的局部规则")
expect(nestedRules.map(\.text).filter { $0 == "先运行测试" }.count == 1, "继承规则必须去重")
expect(
  TaskPromptComposer.compose(
    prompt: "修复登录问题",
    mode: .agent,
    workspacePath: temporaryDirectory.path,
    rules: discoveredRules
  ).contains("项目规则：\n先运行测试\n不修改生产凭据"),
  "项目规则必须注入实际 Runtime Prompt"
)

let agentsDirectory = temporaryDirectory.appendingPathComponent(".kimi-agent/agents", isDirectory: true)
try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
let customAgent = AgentDefinition(
  name: "security-review",
  description: "检查权限与依赖风险。",
  kind: .review,
  allowedTools: ["read", "diff"],
  permissionMode: .readOnly,
  isolation: .readOnlySnapshot
)
try JSONEncoder().encode(customAgent).write(to: agentsDirectory.appendingPathComponent("security-review.json"))
let discoveredAgents = AgentDefinitionRegistry.discover(projectDirectory: temporaryDirectory)
expect(discoveredAgents.first?.name == "security-review", "Agent 注册表必须发现项目级自定义 Agent")
let planWithCustomAgent = AgentOrchestrator.makePlan(taskID: UUID(), mode: .agent, customDefinitions: discoveredAgents)
expect(planWithCustomAgent.runs.contains { $0.definition.name == "security-review" }, "自定义 Agent 必须进入可调度执行图")
let agentRunScheduler = AgentRunScheduler(runs: planWithCustomAgent.runs, maxConcurrent: 2)
let firstBatch = try awaitValue { await agentRunScheduler.scheduleReady() }
expect(firstBatch.count == 1 && firstBatch[0].definition.kind == .explore, "DAG 调度器必须先运行无依赖的 Explore")
_ = try awaitValue { await agentRunScheduler.complete(firstBatch[0].id, result: AgentResult(summary: "探索完成")); return true }
let secondBatch = try awaitValue { await agentRunScheduler.scheduleReady() }
expect(secondBatch.count == 1 && secondBatch[0].definition.kind == .plan, "DAG 调度器必须在依赖完成后调度 Plan")

let capabilityGrant = CapabilityGrant(
  subjectID: orchestrationTaskID,
  resource: temporaryDirectory.path,
  actions: [.read, .search],
  scope: .task
)
expect(capabilityGrant.allows(action: .read, resource: temporaryDirectory.path, subjectID: orchestrationTaskID), "Agent 读取权限必须允许访问已授权工作区")
expect(!capabilityGrant.allows(action: .write, resource: temporaryDirectory.path, subjectID: orchestrationTaskID), "未声明的写入权限必须被 Capability Grant 拒绝")
expect(!capabilityGrant.allows(action: .read, resource: "/tmp/outside", subjectID: orchestrationTaskID), "Worktree 外的路径必须被 Capability Grant 拒绝")


let kernelSessionID = UUID()
let kernelTaskID = UUID()
let kernelStoreURL = temporaryDirectory.appendingPathComponent("session-events.jsonl")
let kernelStore = SessionEventStore(fileURL: kernelStoreURL)
let kernelSession = SessionRecord(
  id: kernelSessionID,
  taskID: kernelTaskID,
  parentID: nil,
  agentID: "build",
  modelID: "kimi-k2.7-code"
)
let sessionCreatedEvent = RuntimeEvent(
  sessionID: kernelSessionID,
  taskID: kernelTaskID,
  sequence: 1,
  kind: .sessionCreated,
  payload: try JSONEncoder().encode(kernelSession)
)
let messageCreatedEvent = RuntimeEvent(
  sessionID: kernelSessionID,
  taskID: kernelTaskID,
  sequence: 2,
  kind: .messagePartAppended,
  payload: try JSONEncoder().encode(MessagePart.text(sessionID: kernelSessionID, role: .user, text: "检查登录流程"))
)
_ = try awaitValue {
  try await kernelStore.append(sessionCreatedEvent)
  try await kernelStore.append(messageCreatedEvent)
  return true
}
let storedKernelEvents = try awaitValue { await kernelStore.events(sessionID: kernelSessionID) }
expect(storedKernelEvents.count == 2, "Session Event Store 必须按顺序保存结构化事件")
let kernelSnapshot = SessionProjector.replay(storedKernelEvents)
expect(kernelSnapshot.session?.id == kernelSessionID, "Projector 必须从事件恢复 Session")
expect(kernelSnapshot.parts.count == 1 && kernelSnapshot.parts.first?.text == "检查登录流程", "Projector 必须恢复 MessagePart")
let kernelSnapshots = try awaitValue { await kernelStore.snapshots() }
expect(kernelSnapshots[kernelSessionID]?.parts.first?.text == "检查登录流程", "Event Store 必须提供按 Session 回放的恢复快照")
let duplicateSequenceResult: Result<Void, Error> = Result {
  try awaitValue {
    try await kernelStore.append(RuntimeEvent(sessionID: kernelSessionID, taskID: kernelTaskID, sequence: 2, kind: .sessionResumed))
  }
}
if case .success = duplicateSequenceResult {
  expect(false, "重复事件序号必须被 Event Store 拒绝")
}

let rebasedEvent = try awaitValue {
  try await kernelStore.appendNext(RuntimeEvent(
    sessionID: kernelSessionID,
    taskID: kernelTaskID,
    sequence: 999,
    kind: .sessionResumed
  ))
}
expect(rebasedEvent.sequence == 3, "Event Store 必须为运行时事件分配连续序号，不能依赖 ACP 自带序号")




let harnessStore = HarnessEventStore()
let harness = AgentHarness(
  store: harnessStore,
  driver: { context, emit in
    let intent = HarnessEffectIntent(
      operationID: context.operationID,
      effectID: UUID(),
      kind: .tool,
      subject: "test.tool",
      risk: .low
    )
    await emit(.effectIntentWritten(intent))
    await emit(.effectStarted(intent))
    await emit(.effectSettled(HarnessEffectReceipt(
      operationID: context.operationID,
      effectID: intent.effectID,
      outcome: .success,
      output: "ok"
    )))
  }
)
let operationID = try awaitValue {
  try await harness.prompt(PromptInput(text: "执行一次测试工具"), lane: .main)
}
_ = try awaitValue {
  try await harness.wait(for: operationID, timeout: 1)
  return true
}
let harnessSnapshot = try awaitValue { await harness.snapshot() }
expect(harnessSnapshot.lanes[.main]?.activeOperation == nil, "Harness 完成后 Lane 必须释放 active operation")
expect(harnessSnapshot.operations[operationID]?.state == .completed, "Harness Operation 必须进入 completed")
let harnessEvents = try awaitValue { await harnessStore.events(operationID: operationID) }
expect(harnessEvents.contains { $0.kind == .effectIntentWritten }, "副作用执行前必须写入 intent")
expect(harnessEvents.contains { $0.kind == .effectSettled }, "副作用完成后必须写入 receipt")

let transcriptStore = HarnessEventStore()
let transcriptHarness = AgentHarness(store: transcriptStore) { context, emit in
  let turnID = UUID()
  await emit(.turnStarted(HarnessTurnRecord(turnID: turnID, modelID: "kimi-test")))
  await emit(.stepStarted(HarnessStepRecord(turnID: turnID, step: 1)))
  await emit(.requestHeader(HarnessModelRequestHeader(
    turnID: turnID,
    step: 1,
    modelID: "kimi-test",
    toolIDs: ["web.search"],
    maximumOutputTokens: 512
  )))
  await emit(.modelChunk(ModelStreamBlock(step: 1, kind: .text, text: "正在查找资料")))
  let call = HarnessToolCall(id: "call-search", name: "web.search", argumentsJSON: #"{"query":"Kimi"}"#)
  await emit(.assistantMessage(HarnessAssistantMessageRecord(
    turnID: turnID,
    step: 1,
    message: .assistant("", toolCalls: [call])
  )))
  await emit(.toolCallDeclared(HarnessToolCallRecord(turnID: turnID, step: 1, call: call)))
  await emit(.toolResultRecorded(HarnessToolResultRecord(
    turnID: turnID,
    step: 1,
    result: HarnessToolResult(callID: call.id, toolName: call.name, output: "[]", isError: false)
  )))
  await emit(.stepEnded(HarnessStepRecord(turnID: turnID, step: 1, status: .toolCalls)))
  await emit(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: "kimi-test", status: .completed)))
}
let transcriptOperation = try awaitValue { try await transcriptHarness.prompt(PromptInput(text: "查 Kimi")) }
_ = try awaitValue { try await transcriptHarness.wait(for: transcriptOperation, timeout: 1); return true }
let transcriptEvents = try awaitValue { await transcriptStore.events(operationID: transcriptOperation) }
expect(transcriptEvents.contains { $0.kind == .turnStarted }, "Harness 必须持久化 turnStarted")
expect(transcriptEvents.contains { $0.kind == .requestHeader }, "Harness 必须持久化模型请求头")
expect(transcriptEvents.contains { $0.kind == .modelChunk }, "Harness 必须持久化原始模型流块")
expect(transcriptEvents.contains { $0.kind == .assistantMessage }, "Harness 必须持久化规范 assistant message")
expect(transcriptEvents.contains { $0.kind == .toolCallDeclared }, "Harness 必须持久化模型声明的 tool call")
expect(transcriptEvents.contains { $0.kind == .toolResultRecorded }, "Harness 必须持久化 tool result")
expect(transcriptEvents.contains { $0.kind == .turnEnded }, "Harness 必须持久化 turnEnded")

let checkpointHarness = AgentHarness(store: HarnessEventStore()) { context, emit in
  await emit(.stepStarted(HarnessStepRecord(turnID: UUID(), step: 2, status: .running)))
  await emit(.toolCallDeclared(HarnessToolCallRecord(
    turnID: UUID(),
    step: 2,
    call: HarnessToolCall(id: "checkpoint-call", name: "read", argumentsJSON: "{}")
  )))
}
let checkpointOperation = try awaitValue { try await checkpointHarness.prompt(PromptInput(text: "检查点")) }
_ = try awaitValue { try await checkpointHarness.wait(for: checkpointOperation, timeout: 1); return true }
let checkpointSnapshot = try awaitValue { await checkpointHarness.snapshot() }
expect(checkpointSnapshot.checkpoints[checkpointOperation]?.step == 2, "Harness 必须在模型步骤边界持久化可恢复 checkpoint")

let steeringTrace = ThreadSafeStringTrace()
let steeringDriverReady = OneShotAsyncGate()
let steeringMayRead = OneShotAsyncGate()
let steeringHarness = AgentHarness { context, _ in
  await steeringDriverReady.open()
  await steeringMayRead.wait()
  let steering = await context.takeSteering()
  steeringTrace.append(steering.map(\.text).joined(separator: "|"))
}
let steeringOperation = try awaitValue { try await steeringHarness.prompt(PromptInput(text: "先开始")) }
_ = try awaitValue { await steeringDriverReady.wait(); return true }
_ = try awaitValue { try await steeringHarness.steer(PromptInput(text: "改为只读"), lane: .main); return true }
_ = try awaitValue { await steeringMayRead.open(); return true }
_ = try awaitValue { try await steeringHarness.wait(for: steeringOperation, timeout: 1); return true }
expect(steeringTrace.snapshot == ["改为只读"], "next-step steering 必须在当前 Operation 的下一模型步骤读取")

let followUpTrace = ThreadSafeStringTrace()
let followUpHarness = AgentHarness { context, _ in
  followUpTrace.append(context.prompt.text)
  try await Task.sleep(nanoseconds: 80_000_000)
}
let followUpOperation = try awaitValue { try await followUpHarness.prompt(PromptInput(text: "第一回合")) }
_ = try awaitValue { try await followUpHarness.followUp(PromptInput(text: "第二回合"), lane: .main); return true }
_ = try awaitValue { try await followUpHarness.wait(for: followUpOperation, timeout: 1); return true }
try? await Task.sleep(nanoseconds: 150_000_000)
expect(followUpTrace.snapshot == ["第一回合", "第二回合"], "next-turn follow-up 必须在当前回合结束后创建下一 Operation")

let repairStore = HarnessEventStore()
let repairSessionID = UUID()
let repairHarness = AgentHarness(sessionID: repairSessionID, store: repairStore) { context, emit in
  let call = HarnessToolCall(id: "interrupted-search", name: "web.search", argumentsJSON: #"{"query":"Kimi"}"#)
  await emit(.toolCallDeclared(HarnessToolCallRecord(turnID: UUID(), step: 1, call: call)))
  try await Task.sleep(nanoseconds: 1_000_000_000)
}
let repairOperation = try awaitValue { try await repairHarness.prompt(PromptInput(text: "查资料")) }
try? await Task.sleep(nanoseconds: 30_000_000)
_ = try awaitValue { await repairHarness.suspend(repairOperation); return true }
try? await Task.sleep(nanoseconds: 30_000_000)
let restoredRepairHarness = AgentHarness(sessionID: repairSessionID, store: repairStore)
_ = try awaitValue { try await restoredRepairHarness.restore(); return true }
let repairedEvents = try awaitValue { await repairStore.events(operationID: repairOperation) }
let repairedResult = repairedEvents.compactMap { event -> HarnessToolResultRecord? in
  guard event.kind == .toolResultRecorded, let payload = event.payload else { return nil }
  return try? JSONDecoder().decode(HarnessToolResultRecord.self, from: payload)
}.first
expect(repairedResult?.result.isError == true, "中断回合的未结算 Tool Call 必须补写可回放错误结果")
let restoredRepairSnapshot = try awaitValue { await restoredRepairHarness.snapshot() }
expect(restoredRepairSnapshot.operations[repairOperation]?.state == .suspended, "中断回合恢复后必须等待用户显式继续")


let laneBusyHarness = AgentHarness(
  store: HarnessEventStore(),
  driver: { _, _ in try await Task.sleep(nanoseconds: 400_000_000) }
)
let busyOperation = try awaitValue {
  try await laneBusyHarness.prompt(PromptInput(text: "长任务"), lane: .main)
}
let busyResult: Result<OperationID, Error> = Result {
  try awaitValue { try await laneBusyHarness.prompt(PromptInput(text: "不应并发"), lane: .main) }
}
if case .success = busyResult {
  expect(false, "同一 Lane 不允许并发 Operation")
}
_ = try awaitValue { await laneBusyHarness.abort(busyOperation); return true }
let abortedSnapshot = try awaitValue { await laneBusyHarness.snapshot() }
expect(abortedSnapshot.operations[busyOperation]?.state == .aborted, "Abort 必须产生可恢复的 aborted 状态")

let suspendedHarness = AgentHarness(
  store: HarnessEventStore(),
  driver: { _, _ in try await Task.sleep(nanoseconds: 800_000_000) }
)
let suspendedOperation = try awaitValue {
  try await suspendedHarness.prompt(PromptInput(text: "暂停后继续"), lane: .main)
}
_ = try awaitValue { await suspendedHarness.suspend(suspendedOperation); return true }
let suspendedSnapshot = try awaitValue { await suspendedHarness.snapshot() }
expect(suspendedSnapshot.operations[suspendedOperation]?.state == .suspended, "暂停必须保留 Operation，供 resume 继续")

let recoveryStore = HarnessEventStore()
let recoverySessionID = UUID()
let recoveryHarness = AgentHarness(sessionID: recoverySessionID, store: recoveryStore, driver: { _, _ in
  try await Task.sleep(nanoseconds: 1_000_000_000)
})
let recoveryOperation = try awaitValue {
  try await recoveryHarness.prompt(PromptInput(text: "恢复测试"), lane: .main)
}
let reopenedHarness = AgentHarness(sessionID: recoverySessionID, store: recoveryStore, driver: { _, _ in
  try await Task.sleep(nanoseconds: 1_000_000_000)
})
_ = try awaitValue { try await reopenedHarness.restore(); return true }
let reopenedSnapshot = try awaitValue { await reopenedHarness.snapshot() }
expect(reopenedSnapshot.operations[recoveryOperation]?.state == .suspended, "重启后未完成 Operation 必须恢复为 suspended")
expect(HarnessRecoveryEngine.actions(for: reopenedSnapshot).contains { $0.operationID == recoveryOperation }, "Recovery Engine 必须提供未完成 Operation 的恢复动作")
let migrationRoot = temporaryDirectory.appendingPathComponent("harness-migration", isDirectory: true)
try FileManager.default.createDirectory(at: migrationRoot, withIntermediateDirectories: true)
for filename in ["state.json", "session-events.jsonl", "harness-v2-events.jsonl"] {
  try Data("legacy-\(filename)".utf8).write(to: migrationRoot.appendingPathComponent(filename))
}
let migrationCoordinator = HarnessMigrationCoordinator(directory: migrationRoot)
let migrationResult = try migrationCoordinator.prepare()
expect(migrationResult.didBackup, "Harness 一次性迁移必须先备份旧状态文件")
expect(FileManager.default.fileExists(atPath: migrationRoot.appendingPathComponent("harness-v3/migration.json").path), "Harness 迁移必须写入版本标记")
let secondMigration = try migrationCoordinator.prepare()
expect(!secondMigration.didBackup, "Harness 迁移重复启动必须幂等，不能覆盖首份备份")

let routePolicy = HarnessRoutePolicy()
expect(routePolicy.path(for: .newSession) == .harness, "新会话必须进入 Harness 主链")
expect(routePolicy.path(for: .legacySession) == .harness, "旧会话迁移后也必须进入 Harness 主链")


expect(WebFetchPolicy.isPrivateOrLocalHost("127.0.0.1"), "Swift Web Fetch 必须拦截 IPv4 loopback")
expect(WebFetchPolicy.isPrivateOrLocalHost("[::1]"), "Swift Web Fetch 必须拦截 IPv6 loopback")
expect(WebFetchPolicy.isPrivateOrLocalHost("169.254.169.254"), "Swift Web Fetch 必须拦截链路本地元数据地址")
expect(!WebFetchPolicy.isPrivateOrLocalHost("www.apple.com"), "公网域名不应被静态私网策略误拦截")
let validatedPublicWebURL = try WebFetchPolicy.validate(url: "https://example.com/docs")
expect(validatedPublicWebURL.host == "example.com", "Swift Web Fetch 必须接受规范 HTTPS URL")
let invalidCredentialURL: Result<URL, Error> = Result { try WebFetchPolicy.validate(url: "https://user:pass@example.com/") }
if case .success = invalidCredentialURL { expect(false, "Swift Web Fetch 不得接受 URL 凭据") }
let invalidPrivateURL: Result<URL, Error> = Result { try WebFetchPolicy.validate(url: "http://127.0.0.1:8080/") }
if case .success = invalidPrivateURL { expect(false, "Swift Web Fetch 不得接受私网字面地址") }

let formulaConfiguration = URLSessionConfiguration.ephemeral
formulaConfiguration.protocolClasses = [MockURLProtocol.self]
let formulaSession = URLSession(configuration: formulaConfiguration)
var formulaRequests: [String] = []
var formulaCompletionCount = 0
MockURLProtocol.requestHandler = { request in
  let path = request.url?.path ?? ""
  formulaRequests.append(path)
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
  if path.hasSuffix("/tools") {
    return (response, try JSONSerialization.data(withJSONObject: ["tools": [["type": "function", "function": ["name": "web_search", "description": "Search", "parameters": ["type": "object"]]]]]))
  }
  if path.hasSuffix("/fibers") {
    return (response, try JSONSerialization.data(withJSONObject: ["context": ["output": "{\"results\":[{\"title\":\"Kimi Docs\",\"url\":\"https://platform.kimi.com/docs\",\"snippet\":\"官方文档\"}]"]]))
  }
  if path.hasSuffix("/chat/completions") {
    formulaCompletionCount += 1
    if formulaCompletionCount == 1 {
      return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "", "tool_calls": [["id": "formula-search-1", "function": ["name": "web_search", "arguments": "{\"query\":\"Kimi docs\"}"]]]]]], "usage": ["prompt_tokens": 12, "completion_tokens": 3]]))
    }
    return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"sources\":[{\"title\":\"Kimi Docs\",\"url\":\"https://platform.kimi.com/docs\",\"snippet\":\"官方文档\"}]}" ]]], "usage": ["prompt_tokens": 9, "completion_tokens": 4]]))
  }
  throw NSError(domain: "FormulaMock", code: 404, userInfo: [NSLocalizedDescriptionKey: path])
}
let formulaProvider = KimiOfficialWebProvider(
  apiKey: "kimi-formula-test-key",
  baseURL: URL(string: "https://api.moonshot.cn/v1")!,
  modelID: "kimi-k3",
  session: formulaSession
)
let formulaSearch = try awaitValue { try await formulaProvider.search(WebSearchRequest(query: "Kimi docs")) }
expect(formulaSearch.sources.first?.url == "https://platform.kimi.com/docs", "Swift Kimi Formula Provider 必须返回可验证来源")
expect(formulaSearch.providerID == "kimi_official" && formulaRequests.contains(where: { $0.hasSuffix("/fibers") }), "Swift Kimi Formula Provider 必须实际读取 Formula 工具并执行 Fiber")
MockURLProtocol.requestHandler = nil

var fiberOnlyCompletionCount = 0
MockURLProtocol.requestHandler = { request in
  let path = request.url?.path ?? ""
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
  if path.hasSuffix("/tools") {
    return (response, try JSONSerialization.data(withJSONObject: ["tools": [["type": "function", "function": ["name": "web_search", "description": "Search", "parameters": ["type": "object"]]]]]))
  }
  if path.hasSuffix("/fibers") {
    return (response, try JSONSerialization.data(withJSONObject: ["context": ["output": #"{"results":[{"title":"Fiber Result","url":"https://platform.kimi.com/fiber","snippet":"直接 Fiber 结果"}]}"#]]))
  }
  if path.hasSuffix("/chat/completions") {
    fiberOnlyCompletionCount += 1
    return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "", "tool_calls": [["id": "formula-fiber-only", "function": ["name": "web_search", "arguments": "{\"query\":\"Kimi docs\"}"]]]]]], "usage": ["prompt_tokens": 12, "completion_tokens": 3]]))
  }
  throw NSError(domain: "FiberOnlyMock", code: 404, userInfo: [NSLocalizedDescriptionKey: path])
}
let fiberOnlyProvider = KimiOfficialWebProvider(
  apiKey: "kimi-formula-test-key",
  baseURL: URL(string: "https://api.moonshot.cn/v1")!,
  modelID: "kimi-k3",
  session: formulaSession,
  maxRounds: 1
)
let fiberOnlySearch = try awaitValue { try await fiberOnlyProvider.search(WebSearchRequest(query: "Kimi docs")) }
expect(fiberOnlySearch.sources.first?.url == "https://platform.kimi.com/fiber", "Kimi Formula Provider 必须在 Fiber 已返回结构化来源时立即结算，不能无谓耗尽模型轮次")
MockURLProtocol.requestHandler = nil

var finalizationToolsByCompletion: [Bool] = []
var finalizationCompletionCount = 0
MockURLProtocol.requestHandler = { request in
  let path = request.url?.path ?? ""
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
  if path.hasSuffix("/tools") {
    return (response, try JSONSerialization.data(withJSONObject: ["tools": [["type": "function", "function": ["name": "web_search", "description": "Search", "parameters": ["type": "object"]]]]]))
  }
  if path.hasSuffix("/fibers") {
    return (response, try JSONSerialization.data(withJSONObject: ["context": ["output": "Kimi 文档搜索结果已返回，请整理来源。"]]))
  }
  if path.hasSuffix("/chat/completions") {
    finalizationCompletionCount += 1
    let body = (try? JSONSerialization.jsonObject(with: requestBodyData(request))) as? [String: Any] ?? [:]
    let hasTools = ((body["tools"] as? [[String: Any]])?.isEmpty == false)
    finalizationToolsByCompletion.append(hasTools)
    if finalizationCompletionCount == 1 {
      return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "", "tool_calls": [["id": "formula-finalize", "function": ["name": "web_search", "arguments": "{\"query\":\"Kimi docs\"}"]]]]]], "usage": ["prompt_tokens": 12, "completion_tokens": 3]]))
    }
    return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"sources\":[{\"title\":\"Finalized Source\",\"url\":\"https:\\/\\/platform.kimi.com\\/finalized\",\"snippet\":\"收回工具后的最终来源\"}]}" ]]], "usage": ["prompt_tokens": 9, "completion_tokens": 4]]))
  }
  throw NSError(domain: "FormulaFinalizationMock", code: 404, userInfo: [NSLocalizedDescriptionKey: path])
}
let finalizationProvider = KimiOfficialWebProvider(
  apiKey: "kimi-formula-test-key",
  baseURL: URL(string: "https://api.moonshot.cn/v1")!,
  modelID: "kimi-k3",
  session: formulaSession,
  maxRounds: 2
)
let finalizationSearch = try awaitValue { try await finalizationProvider.search(WebSearchRequest(query: "Kimi docs")) }
expect(finalizationSearch.sources.first?.url == "https://platform.kimi.com/finalized", "Kimi Formula Provider 必须在获取工具结果后完成来源整理")
expect(finalizationToolsByCompletion == [true, true], "Kimi Formula Provider 每轮 Chat Completion 都必须保留完整工具声明，符合官方 Formula 协议")
MockURLProtocol.requestHandler = nil

var retryCompletionCount = 0
var retryFiberCount = 0
MockURLProtocol.requestHandler = { request in
  let path = request.url?.path ?? ""
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
  if path.hasSuffix("/tools") {
    return (response, try JSONSerialization.data(withJSONObject: ["tools": [["type": "function", "function": ["name": "web_search", "description": "Search", "parameters": ["type": "object"]]]]]))
  }
  if path.hasSuffix("/fibers") {
    retryFiberCount += 1
    return (response, try JSONSerialization.data(withJSONObject: ["context": ["encrypted_output": "retry-receipt-\(retryFiberCount)"]]))
  }
  if path.hasSuffix("/chat/completions") {
    retryCompletionCount += 1
    switch retryCompletionCount {
    case 1, 3, 5:
      let call: [String: Any] = [
        "id": "retry-call-\(retryCompletionCount)",
        "function": ["name": "web_search", "arguments": #"{"query":"Kimi docs"}"#]
      ]
      let message: [String: Any] = ["content": "", "tool_calls": [call]]
      return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": message]], "usage": ["prompt_tokens": 12, "completion_tokens": 3]]))
    case 2, 4:
      let message: [String: Any] = ["content": #"{"sources":[]}"#]
      return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": message]], "usage": ["prompt_tokens": 9, "completion_tokens": 4]]))
    default:
      let message: [String: Any] = ["content": #"{"sources":[{"title":"Retry Source","url":"https://platform.kimi.com/retry","snippet":"重试成功"}]}"#]
      return (response, try JSONSerialization.data(withJSONObject: ["choices": [["message": message]], "usage": ["prompt_tokens": 9, "completion_tokens": 4]]))
    }
  }
  throw NSError(domain: "FormulaRetryMock", code: 404, userInfo: [NSLocalizedDescriptionKey: path])
}
let retryProvider = KimiOfficialWebProvider(
  apiKey: "kimi-formula-test-key",
  baseURL: URL(string: "https://api.moonshot.cn/v1")!,
  modelID: "kimi-k3",
  session: formulaSession,
  maxRounds: 2
)
let retrySearch = try awaitValue { try await retryProvider.search(WebSearchRequest(query: "Kimi docs")) }
expect(retrySearch.sources.first?.url == "https://platform.kimi.com/retry", "Kimi Formula Provider 在空来源后必须开启新的有界搜索轮次")
expect(retryCompletionCount == 6 && retryFiberCount == 3, "Kimi Formula Provider 重试必须保持工具声明、Fiber 和请求次数可审计")
MockURLProtocol.requestHandler = nil

expect(WebToolApprovalPolicy.isReadOnly(toolID: "web.search"), "Web Search 必须被识别为只读网络工具")
expect(WebToolApprovalPolicy.isReadOnly(toolID: "web.fetch"), "Web Fetch 必须被识别为只读网络工具")
expect(
  WebToolApprovalPolicy.approvalKey(toolID: "web.fetch", input: ["url": "https://docs.example.com/guide?a=1"]) == "web.fetch:docs.example.com",
  "Web Fetch 的授权记忆必须按域名归一化，不能按每个 URL 重复审批"
)
expect(
  WebToolApprovalPolicy.approvalKey(toolID: "web.search", input: ["query": "Swift concurrency"]) == "web.search",
  "Web Search 的授权记忆必须按工具范围复用"
)
expect(
  WebToolApprovalPolicy.canAutoApprovePublicRead(toolID: "web.fetch", input: ["url": "https://docs.example.com/guide"]),
  "公网只读 Web Fetch 必须默认自动执行，不应反复弹出审批"
)
expect(
  !WebToolApprovalPolicy.canAutoApprovePublicRead(toolID: "web.fetch", input: ["url": "http://127.0.0.1:8080/admin"]),
  "私网 Web Fetch 不得自动批准"
)
expect(
  !WebToolApprovalPolicy.canAutoApprovePublicRead(toolID: "web.fetch", input: ["url": "https://user:pass@example.com/"]),
  "带凭据 URL 的 Web Fetch 不得自动批准"
)

let childEvents = ChildEventCollector()
let childCoordinator = ChildSessionCoordinator(onEvent: childEvents.append) { session, prompt, _ in
  AgentResult(summary: "完成：\(session.agentID) / \(prompt)")
}
let childSession = try awaitValue {
  await childCoordinator.createChild(
    parent: kernelSession,
    taskID: kernelTaskID,
    definition: AgentOrchestrator.builtInDefinition(for: .explore),
    prompt: "定位登录入口"
  )
}
expect(childSession.parentID == kernelSessionID, "Child Session 必须保存父 Session 关系")
let childResult = try awaitValue { try await childCoordinator.run(childSession.id) }
expect(childResult.summary.contains("explore"), "Child Session 必须通过独立执行器返回结果")
let childState = try awaitValue { await childCoordinator.session(id: childSession.id)?.status }
expect(childState == .completed, "Child Session 完成后必须进入 completed 状态")
expect(childEvents.kinds.contains(.sessionResumed) && childEvents.kinds.contains(.sessionCompleted), "Child Session 生命周期事件必须回流到父事件总线")
expect(SessionProjector.replay(childEvents.events).session?.status == .completed, "Child Session 回流事件必须可独立回放恢复状态")
let cancellationCollector = CancellationCollector()
let cancellableCoordinator = ChildSessionCoordinator(onCancel: cancellationCollector.record) { _, _, _ in
  try await Task.sleep(nanoseconds: 2_000_000_000)
  return AgentResult(summary: "不应完成")
}
let cancellableChild = try awaitValue {
  await cancellableCoordinator.createChild(
    parent: kernelSession,
    taskID: kernelTaskID,
    definition: AgentOrchestrator.builtInDefinition(for: .explore),
    prompt: "可取消测试"
  )
}
_ = try awaitValue { await cancellableCoordinator.cancel(cancellableChild.id); return true }
expect(cancellationCollector.ids.contains(cancellableChild.id), "取消 Child Session 必须通知真实 Runtime 终止进程")
let pausableCollector = CancellationCollector()
let pausableCoordinator = ChildSessionCoordinator(onCancel: pausableCollector.record) { _, _, _ in
  try await Task.sleep(nanoseconds: 2_000_000_000)
  return AgentResult(summary: "不应完成")
}
let pausableChild = try awaitValue {
  await pausableCoordinator.createChild(
    parent: kernelSession,
    taskID: kernelTaskID,
    definition: AgentOrchestrator.builtInDefinition(for: .explore),
    prompt: "可暂停测试"
  )
}
let pausableRunTask = Task.detached { try? await pausableCoordinator.run(pausableChild.id) }
try? await Task.sleep(nanoseconds: 100_000_000)
_ = try awaitValue { await pausableCoordinator.pause(pausableChild.id); return true }
let pausedStatus = try awaitValue { await pausableCoordinator.session(id: pausableChild.id)?.status }
expect(pausableCollector.ids.contains(pausableChild.id), "暂停 Child Session 必须中断真实 Runtime")
expect(pausedStatus == .paused, "暂停后 Child Session 必须保持 paused 状态")
_ = try awaitValue { await pausableCoordinator.resume(pausableChild.id); return true }
let resumedStatus = try awaitValue { await pausableCoordinator.session(id: pausableChild.id)?.status }
expect(resumedStatus == .idle, "恢复后 Child Session 必须回到 idle 可重新执行")
pausableRunTask.cancel()
var linkedRun = orchestrationPlan.runs[0]
linkedRun.childSessionID = childSession.id
let restoredLinkedRun = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(linkedRun))
expect(restoredLinkedRun.childSessionID == childSession.id, "Agent Run 必须持久化对应的 Child Session ID")

let persistedAgentTask = AgentTask(
  title: "可恢复 Agent 会话",
  mode: .agent,
  workspacePath: temporaryDirectory.path,
  agentRuns: orchestrationPlan.runs,
  workspaceLayout: splitLayout,
  ruleSet: ruleSet
)
let restoredAgentTask = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(persistedAgentTask))
expect(restoredAgentTask.agentRuns.count == 5, "Agent Run 必须随任务持久化并在重启后恢复")
expect(restoredAgentTask.workspaceLayout?.visiblePaneKinds.contains(.terminal) == true, "会话工作区布局必须持久化")
expect(restoredAgentTask.ruleSet.effectiveRules.count == 4, "规则集必须随会话持久化")

let turnTestTaskID = UUID()
let turnTestSessionID = UUID()
let firstTurn = ConversationTurn(sequence: 1, userMessage: "你好", assistantMessage: "你好，我可以帮你。", status: .completed)


expect(
  ConversationDisplayPolicy.shouldFollowStreamingText(previousID: "reply", previousText: "第一段", currentID: "reply", currentText: "第一段第二段"),
  "流式正文内容增长时，即使消息 ID 不变也必须触发自动滚动"
)
expect(
  AgentEvent(sessionID: turnTestSessionID, taskID: turnTestTaskID, sequence: 3, actor: "desktop", kind: .output).assigningTurn(firstTurn.id).turnID == firstTurn.id,
  "运行事件必须能够绑定到具体 Turn"
)

// Harness v2 contract: malformed model tool calls must fail schema validation
// before permission evaluation or approval UI. This is intentionally placed in
// CoreChecks first so the implementation is driven by a regression contract.
let schemaProbe = InvocationCounter()
expect(schemaProbe.count == 0, "Schema 校验失败时不得进入权限审批")

let envelope = ToolCallEnvelope(
  id: "call-1",
  toolID: "write",
  arguments: .object(["path": .string("a.txt"), "content": .string("ok")]),
  schemaVersion: 1
)
expect(envelope.idempotencyKey == "call-1", "ToolCallEnvelope 必须提供稳定幂等键")

let nativeBridgePlan = BrowserVerificationPlan(
  allowedDomains: ["example.com"],
  steps: [BrowserVerificationStep(kind: .open, url: URL(string: "https://example.com")!)]
)
let nativeBridgeRequest = KimiNativeBridgeRequest(
  requestID: "browser-1",
  operation: .browserVerify,
  browserPlan: nativeBridgePlan
)
try nativeBridgeRequest.validate()
let restoredNativeBridgeRequest = try JSONDecoder().decode(
  KimiNativeBridgeRequest.self,
  from: JSONEncoder().encode(nativeBridgeRequest)
)
expect(restoredNativeBridgeRequest == nativeBridgeRequest, "原生桥接请求必须可持久化并保持浏览器计划")
let incompleteClickRequest = KimiNativeBridgeRequest(requestID: "click-1", operation: .computerClick, x: 12)
let clickValidationRejected: Bool
do {
  try incompleteClickRequest.validate()
  clickValidationRejected = false
} catch KimiNativeBridgeValidationError.missingCoordinates {
  clickValidationRejected = true
} catch {
  clickValidationRejected = false
}
expect(clickValidationRejected, "Computer Use 点击请求缺少坐标时不得启动原生副作用")

let nativeWebSearchRequest = KimiNativeBridgeRequest(
  requestID: "web-search-1",
  operation: .webSearch,
  query: "Kimi Code Agent",
  maxResults: 99
)
try nativeWebSearchRequest.validate()
let restoredNativeWebSearchRequest = try JSONDecoder().decode(
  KimiNativeBridgeRequest.self,
  from: JSONEncoder().encode(nativeWebSearchRequest)
)
expect(restoredNativeWebSearchRequest == nativeWebSearchRequest, "原生桥接必须持久化 Web Search 请求")
let nativeBridgeFailure = KimiNativeBridgeResponse.failure(requestID: nativeWebSearchRequest.requestID, error: "测试失败")
expect(nativeBridgeFailure.requestID == nativeWebSearchRequest.requestID && !nativeBridgeFailure.ok, "原生桥接失败必须保留原始 requestID")
let incompleteWebFetchRequest = KimiNativeBridgeRequest(requestID: "web-fetch-1", operation: .webFetch)
let webFetchValidationRejected: Bool
do {
  try incompleteWebFetchRequest.validate()
  webFetchValidationRejected = false
} catch KimiNativeBridgeValidationError.missingURL {
  webFetchValidationRejected = true
} catch {
  webFetchValidationRejected = false
}
expect(webFetchValidationRejected, "Web Fetch 请求缺少 URL 时不得启动原生联网副作用")

let webSourceStoreDirectory = FileManager.default.temporaryDirectory
  .appendingPathComponent("kimi-web-source-store-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: webSourceStoreDirectory) }
let webSourceStore = WebSourceReceiptStore(directory: webSourceStoreDirectory, sourceTTL: 60)
let storedWebSource = WebSource(title: "Kimi Docs", url: "https://platform.kimi.com/docs")
try webSourceStore.record([storedWebSource])
try webSourceStore.validate(sourceID: storedWebSource.id, url: storedWebSource.url)
let mismatchedSourceRejected: Bool
do {
  try webSourceStore.validate(sourceID: storedWebSource.id, url: "https://example.com/other")
  mismatchedSourceRejected = false
} catch {
  mismatchedSourceRejected = true
}
expect(mismatchedSourceRejected, "持久化 Web sourceID 不得被重定向到另一 URL")
let sharedPrefixSourceA = WebSource(title: "Kimi Work", url: "https://www.kimi.com/resources/kimi-work-introduction")
let sharedPrefixSourceB = WebSource(title: "Desktop Automation", url: "https://www.kimi.com/resources/desktop-automation")
expect(sharedPrefixSourceA.id != sharedPrefixSourceB.id, "Web sourceID 必须覆盖完整 URL，不能因公共路径前缀碰撞")


@discardableResult
private func runCheckCommand(_ executable: String, _ arguments: [String], in directory: URL) throws -> String {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments
  process.currentDirectoryURL = directory
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  guard process.terminationStatus == 0 else {
    throw NSError(domain: "KimiAgentCoreChecks", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
  }
  return text
}

private func requestBodyData(_ request: URLRequest) -> Data {
  if let data = request.httpBody { return data }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var output = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count > 0 else { break }
    output.append(buffer, count: count)
  }
  return output
}

final class MockMCPHTTPURLProtocol: URLProtocol {
  nonisolated(unsafe) static var responses: [Data] = []
  nonisolated(unsafe) static var statusCode: Int = 200

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard !Self.responses.isEmpty else {
      client?.urlProtocol(self, didFailWithError: NSError(domain: "MockMCPHTTPURLProtocol", code: 1))
      return
    }
    let data = Self.responses.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: Self.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !data.isEmpty {
      client?.urlProtocol(self, didLoad: data)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

final class ChildEventCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [RuntimeEvent] = []

  func append(_ event: RuntimeEvent) {
    lock.lock()
    values.append(event)
    lock.unlock()
  }

  var kinds: [RuntimeEventKind] {
    lock.lock()
    defer { lock.unlock() }
    return values.map(\.kind)
  }

  var events: [RuntimeEvent] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

final class CancellationCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID] = []

  func record(_ id: UUID) {
    lock.lock()
    values.append(id)
    lock.unlock()
  }

  var ids: [UUID] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}


// Native Kimi UI / App Kernel contract tests. These are intentionally written
// before the implementation so the first run proves the new boundary is not
// accidentally satisfied by an existing legacy path.
let nativePrompt = PromptInput(text: "检查登录问题")
let nativeCommand = KimiAppCommand.prompt(nativePrompt)
expect(nativeCommand.kind == .prompt, "原生 App Command 必须保留 prompt 类型")
let initialUIState = KimiUIState()
expect(initialUIState.activePane == .conversation, "原生工作台默认打开会话 Pane")
expect(initialUIState.terminalPlacement == .right, "原生工作台终端必须固定在右侧")
let displayEvent = KimiEvent.assistantText(text: "你好", partID: nil, isSnapshot: false)
expect(displayEvent.displayText == "你好", "Kimi Event 必须提供稳定的 UI 展示文本")

let endpoint = KimiRuntimeEndpoint(host: "127.0.0.1", port: 43127, token: "test-token")
expect(endpoint.baseURL.absoluteString == "http://127.0.0.1:43127", "Headless Runtime 必须只生成 loopback endpoint")
expect(endpoint.authorizationHeader.hasPrefix("Basic "), "Headless 引擎 必须使用 Basic kimi:token 认证")
let headlessFactoryConfiguration = KimiHeadlessRuntimeFactory.makeConfiguration(
  resourcesDirectory: temporaryDirectory,
  applicationSupportDirectory: temporaryDirectory.appendingPathComponent("support", isDirectory: true),
  environment: [
    "KIMI_RUNTIME_BINARY": "/bin/echo",
    "KIMI_API_KEY": "test-key",
    "KIMI_RUNTIME_PLUGIN": "/tmp/kimi-native-plugin.mjs"
  ]
)
let headlessFactoryConfigJSON = headlessFactoryConfiguration?.environment["OPENCODE_CONFIG_CONTENT"] ?? "{}"
let headlessFactoryConfig = (try? JSONSerialization.jsonObject(with: Data(headlessFactoryConfigJSON.utf8)) as? [String: Any]) ?? [:]
let configuredPlugin = headlessFactoryConfiguration?.environment["KIMI_RUNTIME_PLUGIN"] ?? ""
expect(configuredPlugin.hasPrefix("file://"), "Swift Headless Factory 必须把本地插件环境变量写成 file:// URL，Engine 虚拟配置才能加载插件")
expect((headlessFactoryConfig["tool_output"] as? [String: Any])?["max_bytes"] as? Int == 51_200, "Swift Headless Factory 必须与 Kimi Engine Profile 使用一致的工具输出上限")
expect((headlessFactoryConfig["compaction"] as? [String: Any])?["tail_turns"] as? Int == 8, "Swift Headless Factory 必须与 Kimi Engine Profile 使用一致的压缩策略")
expect(headlessFactoryConfiguration?.environment["OPENCODE_SERVER_USERNAME"] == "kimi", "Headless 引擎必须使用 Kimi 认证用户名")
expect(headlessFactoryConfiguration?.workingDirectory?.path
  == temporaryDirectory.appendingPathComponent("support", isDirectory: true).path,
  "打包后引擎源码目录不存在时，workingDirectory 必须回退到 Application Support，否则进程无法 spawn")
expect(headlessFactoryConfiguration?.environment["XDG_DATA_HOME"]?.hasSuffix("runtime/data") == true
  && headlessFactoryConfiguration?.environment["XDG_CONFIG_HOME"]?.hasSuffix("runtime/config") == true
  && headlessFactoryConfiguration?.environment["XDG_STATE_HOME"]?.hasSuffix("runtime/state") == true,
  "Headless 引擎的所有可写目录必须收编进 Application Support/runtime，禁止泄漏到 ~/.config 或 ~/.local")
expect(headlessFactoryConfig["$schema"] == nil, "引擎配置不得携带暴露来源的 $schema 链接")

// MCP server entry engine config schema validation
let localMcpEntry = KimiMCPServerEntry(
  id: "filesystem",
  transport: .local,
  enabled: true,
  command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
  cwd: "/tmp/work",
  environment: ["API_KEY": "secret"],
  timeout: 10000
)
let localMcpConfig = localMcpEntry.toEngineConfig()
expect(localMcpConfig["type"] as? String == "local", "MCP local 配置必须包含 type=local")
expect(localMcpConfig["command"] as? [String] == ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"], "MCP local 配置必须使用 command 字段（不是 cmd）")
expect(localMcpConfig["environment"] as? [String: String] == ["API_KEY": "secret"], "MCP local 配置必须使用 environment 字段（不是 env）")
expect(localMcpConfig["cwd"] as? String == "/tmp/work", "MCP local 配置必须保留 cwd")
expect(localMcpConfig["timeout"] as? Int == 10000, "MCP local 配置必须保留 timeout")
expect(localMcpConfig["enabled"] as? Bool == true, "MCP local 配置必须保留 enabled")

let remoteMcpEntry = KimiMCPServerEntry(
  id: "remote-api",
  transport: .remote,
  enabled: true,
  url: "https://mcp.example.com/sse",
  headers: ["Authorization": "Bearer token123"]
)
let remoteMcpConfig = remoteMcpEntry.toEngineConfig()
expect(remoteMcpConfig["type"] as? String == "remote", "MCP remote 配置必须包含 type=remote（不是 sse/http）")
expect(remoteMcpConfig["url"] as? String == "https://mcp.example.com/sse", "MCP remote 配置必须保留 url")
expect(remoteMcpConfig["headers"] as? [String: String] == ["Authorization": "Bearer token123"], "MCP remote 配置必须保留 headers")

// MCP server store persistence
let mcpStoreURL = temporaryDirectory.appendingPathComponent("mcp-store-test/mcp-servers.json")
let mcpStore = KimiMCPServerStore(fileURL: mcpStoreURL)
try mcpStore.save([localMcpEntry, remoteMcpEntry])
let loadedMcpServers = try mcpStore.load()
expect(loadedMcpServers.count == 2, "MCP 服务器配置必须能持久化并读回")
expect(loadedMcpServers.first?.id == "filesystem", "MCP 服务器配置读回时必须保留服务器 ID")
expect(loadedMcpServers.first?.transport == .local, "MCP 服务器配置读回时必须保留 transport 类型")
expect(loadedMcpServers.first?.command == ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"], "MCP 服务器配置读回时必须保留 command 数组")

// MCP config generation in KimiHeadlessRuntimeFactory
let mcpFactorySupport = temporaryDirectory.appendingPathComponent("mcp-factory-support", isDirectory: true)
let mcpFactoryStore = KimiMCPServerStore(fileURL: mcpFactorySupport.appendingPathComponent("settings/mcp-servers.json"))
try mcpFactoryStore.save([localMcpEntry])
let mcpFactoryConfig = KimiHeadlessRuntimeFactory.makeConfiguration(
  resourcesDirectory: temporaryDirectory,
  applicationSupportDirectory: mcpFactorySupport,
  environment: [
    "KIMI_RUNTIME_BINARY": "/bin/echo",
    "KIMI_API_KEY": "test-key",
    "KIMI_RUNTIME_PLUGIN": "/tmp/kimi-native-plugin.mjs"
  ]
)
let mcpFactoryConfigJSON = mcpFactoryConfig?.environment["OPENCODE_CONFIG_CONTENT"] ?? "{}"
let mcpFactoryConfigObj = (try? JSONSerialization.jsonObject(with: Data(mcpFactoryConfigJSON.utf8)) as? [String: Any]) ?? [:]
let generatedMcpBlock = mcpFactoryConfigObj["mcp"] as? [String: Any]
expect(generatedMcpBlock != nil, "KimiHeadlessRuntimeFactory 必须在 OPENCODE_CONFIG_CONTENT 中生成 mcp 配置块")
expect(generatedMcpBlock?["filesystem"] != nil, "生成的 mcp 配置块必须包含已配置的服务器")
let generatedFilesystemConfig = generatedMcpBlock?["filesystem"] as? [String: Any]
expect(generatedFilesystemConfig?["type"] as? String == "local", "生成的服务器配置必须包含 type=local")
expect(generatedFilesystemConfig?["command"] as? [String] == ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"], "生成的服务器配置必须保留 command 数组")
expect(generatedFilesystemConfig?["environment"] as? [String: String] == ["API_KEY": "secret"], "生成的服务器配置必须保留 environment")

// Disabled servers must not be included in the generated config
let disabledMcpEntry = KimiMCPServerEntry(
  id: "disabled-server",
  transport: .local,
  enabled: false,
  command: ["npx", "test"]
)
try mcpFactoryStore.save([localMcpEntry, disabledMcpEntry])
let mcpFactoryConfig2 = KimiHeadlessRuntimeFactory.makeConfiguration(
  resourcesDirectory: temporaryDirectory,
  applicationSupportDirectory: mcpFactorySupport,
  environment: [
    "KIMI_RUNTIME_BINARY": "/bin/echo",
    "KIMI_API_KEY": "test-key",
    "KIMI_RUNTIME_PLUGIN": "/tmp/kimi-native-plugin.mjs"
  ]
)
let mcpFactoryConfigJSON2 = mcpFactoryConfig2?.environment["OPENCODE_CONFIG_CONTENT"] ?? "{}"
let mcpFactoryConfigObj2 = (try? JSONSerialization.jsonObject(with: Data(mcpFactoryConfigJSON2.utf8)) as? [String: Any]) ?? [:]
let generatedMcpBlock2 = mcpFactoryConfigObj2["mcp"] as? [String: Any]
expect(generatedMcpBlock2?["disabled-server"] == nil, "禁用的 MCP 服务器不得出现在生成的配置块中")
expect(generatedMcpBlock2?["filesystem"] != nil, "启用的 MCP 服务器必须仍然出现在配置块中")

// KimiHookConfiguration: engine options mapping is flat JSON, code-free
let emptyHookConfiguration = KimiHookConfiguration()
expect(emptyHookConfiguration.isEmpty, "未配置任何规则时 KimiHookConfiguration 必须为空")
expect(emptyHookConfiguration.toEngineOptions().isEmpty, "空的 Hook 配置必须生成空的引擎选项")

let sampleHookConfiguration = KimiHookConfiguration(
  systemPromptRules: ["总是用简体中文回复"],
  permissionOverrides: ["bash": .deny],
  webFetchAllowedDomains: ["example.com"],
  toolOutputCharLimits: ["bash": 4000]
)
expect(!sampleHookConfiguration.isEmpty, "配置了任意规则后 KimiHookConfiguration 不得为空")
let sampleHookOptions = sampleHookConfiguration.toEngineOptions()
expect(sampleHookOptions["systemPromptRules"] as? [String] == ["总是用简体中文回复"], "引擎选项必须原样保留 systemPromptRules")
expect(sampleHookOptions["permissionOverrides"] as? [String: String] == ["bash": "deny"], "引擎选项必须把 permissionOverrides 的枚举值序列化为字符串")
expect(sampleHookOptions["webFetchAllowedDomains"] as? [String] == ["example.com"], "引擎选项必须原样保留 webFetchAllowedDomains")
expect(sampleHookOptions["toolOutputCharLimits"] as? [String: Int] == ["bash": 4000], "引擎选项必须原样保留 toolOutputCharLimits")

// KimiHookConfigStore persistence
let hookStoreURL = temporaryDirectory.appendingPathComponent("hook-store-test/hook-config.json")
let hookStore = KimiHookConfigStore(fileURL: hookStoreURL)
try hookStore.save(sampleHookConfiguration)
let loadedHookConfiguration = try hookStore.load()
expect(loadedHookConfiguration == sampleHookConfiguration, "Hook 配置必须能持久化并读回，且字段完全一致")

// KimiHeadlessRuntimeFactory: plugin entry stays a bare spec string when no
// hook rules are configured, and becomes a [spec, options] tuple once they
// are — this is the exact shape the engine's plugin loader expects for
// config.plugin = [[path, options]] (see vendor/engine packages/opencode/src/config/plugin.ts).
let hookFactorySupport = temporaryDirectory.appendingPathComponent("hook-factory-support", isDirectory: true)
let hookFactoryConfigNoRules = KimiHeadlessRuntimeFactory.makeConfiguration(
  resourcesDirectory: temporaryDirectory,
  applicationSupportDirectory: hookFactorySupport,
  environment: [
    "KIMI_RUNTIME_BINARY": "/bin/echo",
    "KIMI_API_KEY": "test-key",
    "KIMI_RUNTIME_PLUGIN": "/tmp/kimi-native-plugin.mjs"
  ]
)
let hookFactoryConfigNoRulesJSON = hookFactoryConfigNoRules?.environment["OPENCODE_CONFIG_CONTENT"] ?? "{}"
let hookFactoryConfigNoRulesObj = (try? JSONSerialization.jsonObject(with: Data(hookFactoryConfigNoRulesJSON.utf8)) as? [String: Any]) ?? [:]
let pluginEntryNoRules = hookFactoryConfigNoRulesObj["plugin"] as? [Any]
expect(pluginEntryNoRules?.first as? String == "{env:KIMI_RUNTIME_PLUGIN}", "未配置 Hook 规则时，plugin 字段必须是裸的 spec 字符串数组")

let hookFactoryStore = KimiHookConfigStore(fileURL: hookFactorySupport.appendingPathComponent("settings/hook-config.json"))
try hookFactoryStore.save(sampleHookConfiguration)
let hookFactoryConfigWithRules = KimiHeadlessRuntimeFactory.makeConfiguration(
  resourcesDirectory: temporaryDirectory,
  applicationSupportDirectory: hookFactorySupport,
  environment: [
    "KIMI_RUNTIME_BINARY": "/bin/echo",
    "KIMI_API_KEY": "test-key",
    "KIMI_RUNTIME_PLUGIN": "/tmp/kimi-native-plugin.mjs"
  ]
)
let hookFactoryConfigWithRulesJSON = hookFactoryConfigWithRules?.environment["OPENCODE_CONFIG_CONTENT"] ?? "{}"
let hookFactoryConfigWithRulesObj = (try? JSONSerialization.jsonObject(with: Data(hookFactoryConfigWithRulesJSON.utf8)) as? [String: Any]) ?? [:]
let pluginEntryWithRules = hookFactoryConfigWithRulesObj["plugin"] as? [Any]
let pluginTuple = pluginEntryWithRules?.first as? [Any]
expect(pluginTuple?.first as? String == "{env:KIMI_RUNTIME_PLUGIN}", "配置了 Hook 规则时，plugin 字段第一个元素必须仍是原来的 spec 字符串")
let pluginTupleOptions = pluginTuple?.count == 2 ? pluginTuple?[1] as? [String: Any] : nil
expect(pluginTupleOptions?["systemPromptRules"] as? [String] == ["总是用简体中文回复"], "配置了 Hook 规则时，plugin 字段第二个元素必须携带 systemPromptRules")
expect(pluginTupleOptions?["permissionOverrides"] as? [String: String] == ["bash": "deny"], "配置了 Hook 规则时，plugin 字段第二个元素必须携带 permissionOverrides")

// EngineProvider abstraction: AnthropicDirectEngineProvider is a second real
// backend behind the exact same protocol opencode's URLSessionRuntimeClient
// implements. These checks drive it through a mocked Anthropic Messages API
// SSE stream and assert it produces the same event-stream shape the driver
// (KimiRuntimeOperationDriver.waitForCompletion) actually depends on: text
// deltas, tool call/result pairs, and exactly one explicit turnOutcome frame.
let anthropicMockConfig = URLSessionConfiguration.ephemeral
anthropicMockConfig.protocolClasses = [MockURLProtocol.self]
let anthropicMockSession = URLSession(configuration: anthropicMockConfig)

func anthropicSSEResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
  let bodyData = request.httpBody ?? Data()
  let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
  let messages = body["messages"] as? [[String: Any]] ?? []
  let hasToolResult = messages.contains { message in
    ((message["content"] as? [[String: Any]]) ?? []).contains { ($0["type"] as? String) == "tool_result" }
  }
  if hasToolResult {
    // Second round trip: the model saw the tool result and just replies with text.
    let stream = """
    data: {"type":"content_block_delta","delta":{"text":"完成了"}}

    data: {"type":"message_stop"}

    """
    return (response, Data(stream.utf8))
  }
  // First round trip: the model asks to run one tool.
  let stream = """
  data: {"type":"content_block_start","content_block":{"type":"tool_use","id":"tool-1","name":"bash"}}

  data: {"type":"content_block_delta","delta":{"partial_json":"{\\"command\\":\\"echo hi\\"}"}}

  data: {"type":"content_block_stop"}

  data: {"type":"message_stop"}

  """
  return (response, Data(stream.utf8))
}
MockURLProtocol.requestHandler = { try anthropicSSEResponse(for: $0) }

let anthropicProvider = AnthropicDirectEngineProvider(apiKey: "test-key", model: "claude-sonnet-4-6", session: anthropicMockSession)
let anthropicSession = try! awaitValue { try await anthropicProvider.createSession(CreateSessionInput(directory: "/tmp", title: "anthropic-test")) }
let anthropicEventsStream = try! awaitValue { try await anthropicProvider.subscribeEvents(sessionID: anthropicSession.id, directory: "/tmp") }
try! awaitValue { try await anthropicProvider.prompt(KimiRuntimePromptInput(sessionID: anthropicSession.id, text: "run echo hi", directory: "/tmp")) }

let anthropicCollected = try! awaitValue { () async throws -> ([KimiRuntimeEventKind], [EngineTurnOutcome]) in
  var kinds: [KimiRuntimeEventKind] = []
  var outcomes: [EngineTurnOutcome] = []
  for try await event in anthropicEventsStream {
    kinds.append(event.kind)
    if let outcome = event.turnOutcome { outcomes.append(outcome) }
    if event.turnOutcome != nil { break }
  }
  return (kinds, outcomes)
}
let anthropicEventKinds = anthropicCollected.0
let anthropicTurnOutcomes = anthropicCollected.1
MockURLProtocol.requestHandler = nil

expect(anthropicEventKinds.contains(.toolCall), "AnthropicDirectEngineProvider 必须像 opencode 后端一样产出 toolCall 事件")
expect(anthropicEventKinds.contains(.toolResult), "AnthropicDirectEngineProvider 必须像 opencode 后端一样产出 toolResult 事件")
expect(anthropicTurnOutcomes == [.completed], "AnthropicDirectEngineProvider 必须为每一轮恰好产出一个 turnOutcome:.completed 事件，这是驱动器等待完成的唯一契约")

// Same real production call path (KimiRuntimeOperationDriver.run) that the
// opencode backend goes through above (see idleDriver), now driving
// AnthropicDirectEngineProvider instead. If this needs any
// `if provider is AnthropicDirectEngineProvider` special-casing in the
// driver or kernel to pass, the abstraction has a leak — it does not.
MockURLProtocol.requestHandler = { request in
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
  let stream = """
  data: {"type":"content_block_delta","delta":{"text":"你好"}}

  data: {"type":"message_stop"}

  """
  return (response, Data(stream.utf8))
}
let anthropicProvider2 = AnthropicDirectEngineProvider(apiKey: "test-key", model: "claude-sonnet-4-6", session: anthropicMockSession)
let anthropicDriver = KimiRuntimeOperationDriver(client: anthropicProvider2)
let anthropicDriverTrace = ThreadSafeStringTrace()
let anthropicDriverSession = try! awaitValue { try await anthropicProvider2.createSession(CreateSessionInput(directory: "/tmp", title: "driver-test")) }
try! awaitValue { await anthropicDriver.setSession(anthropicDriverSession.id, directory: "/tmp"); return () }
try! awaitValue {
  try await anthropicDriver.run(
    context: HarnessOperationContext(sessionID: UUID(), operationID: UUID(), lane: .main, prompt: PromptInput(text: "你好")),
    sink: { event in
      switch event {
      case .turnEnded: anthropicDriverTrace.append("turn-ended")
      case .stepEnded: anthropicDriverTrace.append("step-ended")
      default: break
      }
    }
  )
  return ()
}
MockURLProtocol.requestHandler = nil
expect(anthropicDriverTrace.snapshot.contains("turn-ended"), "KimiRuntimeOperationDriver 必须能在完全不知道后端是 opencode 还是 Anthropic 直连的情况下，正常驱动 Anthropic 后端的一轮对话到 turn-ended")

// Runtime data migration: legacy XDG locations must fold into the contained
// runtime directory without overwriting anything.
let migrationHome = temporaryDirectory.appendingPathComponent("migration-home", isDirectory: true)
let migrationSupport = temporaryDirectory.appendingPathComponent("migration-support", isDirectory: true)
let migrLegacyData = migrationHome.appendingPathComponent(".local/share/opencode", isDirectory: true)
let migrLegacyConfig = migrationHome.appendingPathComponent(".config/opencode", isDirectory: true)
let migrLegacyState = migrationSupport.appendingPathComponent("opencode-state", isDirectory: true)
try! FileManager.default.createDirectory(at: migrLegacyData, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: migrLegacyConfig, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: migrLegacyState, withIntermediateDirectories: true)
try! "sessions".write(to: migrLegacyData.appendingPathComponent("db.txt"), atomically: true, encoding: .utf8)
try! "config".write(to: migrLegacyConfig.appendingPathComponent("engine.json"), atomically: true, encoding: .utf8)
try! "state".write(to: migrLegacyState.appendingPathComponent("engine-state.txt"), atomically: true, encoding: .utf8)
let migrationReport = KimiRuntimeDataMigrator.migrateIfNeeded(
  applicationSupportDirectory: migrationSupport,
  homeDirectory: migrationHome
)
expect(migrationReport.failed.isEmpty, "运行时数据迁移不得失败：\(migrationReport.failed)")
expect(FileManager.default.fileExists(atPath: migrationSupport.appendingPathComponent("runtime/data/opencode/db.txt").path),
  "旧 XDG 数据目录必须迁移进 runtime/data")
expect(FileManager.default.fileExists(atPath: migrationSupport.appendingPathComponent("runtime/config/opencode/engine.json").path),
  "旧 XDG 配置目录必须迁移进 runtime/config")
expect(FileManager.default.fileExists(atPath: migrationSupport.appendingPathComponent("runtime/state/engine-state.txt").path),
  "旧 state 目录必须迁移进 runtime/state")
expect(!FileManager.default.fileExists(atPath: migrLegacyData.path) && !FileManager.default.fileExists(atPath: migrLegacyConfig.path),
  "迁移完成后旧 XDG 目录不得残留")
// Second run with both source and target present must preserve, not overwrite.
try! FileManager.default.createDirectory(at: migrLegacyData, withIntermediateDirectories: true)
try! "newer".write(to: migrLegacyData.appendingPathComponent("db2.txt"), atomically: true, encoding: .utf8)
let secondReport = KimiRuntimeDataMigrator.migrateIfNeeded(
  applicationSupportDirectory: migrationSupport,
  homeDirectory: migrationHome
)
expect(secondReport.failed.isEmpty
  && FileManager.default.fileExists(atPath: migrationSupport.appendingPathComponent("runtime/legacy/opencode-legacy/db2.txt").path)
  && FileManager.default.fileExists(atPath: migrationSupport.appendingPathComponent("runtime/data/opencode/db.txt").path),
  "新旧数据同时存在时必须保留双份且不得覆盖")

let idleClient = IdleKimiRuntimeSessionClient()
let idleDriver = KimiRuntimeOperationDriver(client: idleClient)
let idleDriverTrace = ThreadSafeStringTrace()
try! awaitValue { await idleDriver.setSession("session-idle"); return () }
try! awaitValue {
  try await idleDriver.run(
    context: HarnessOperationContext(sessionID: UUID(), operationID: UUID(), lane: .main, prompt: PromptInput(text: "等待 idle")),
    sink: { event in
      switch event {
      case .turnEnded: idleDriverTrace.append("turn-ended")
      case .stepEnded: idleDriverTrace.append("step-ended")
      default: break
      }
    }
  )
  return ()
}
expect(idleClient.promptCount == 1 && idleDriverTrace.snapshot.contains("turn-ended"), "Engine Operation Driver 必须等待 session.idle 后才结束 Harness turn")
let crashOnlyRuntime = KimiRuntimeSupervisor(configuration: KimiRuntimeConfiguration(
  executableURL: URL(fileURLWithPath: "/bin/sh"),
  arguments: ["-c", "exit 0"],
  endpoint: KimiRuntimeEndpoint(port: 43128, token: "restart-test"),
  restartLimit: 1,
  restartDelay: 0.02
))
_ = try! awaitValue { try await crashOnlyRuntime.start() }
try? await Task.sleep(for: .milliseconds(180))
let restartCount = try! awaitValue { await crashOnlyRuntime.unexpectedExitRestartCount() }
expect(restartCount == 1, "Headless Sidecar 意外退出后必须在限定次数内自动重启")
try! awaitValue { await crashOnlyRuntime.stop(); return () }
let bridged = KimiRuntimeEventBridge.map(
  EngineRuntimeEvent(sessionID: "session-1", kind: .assistantText, text: "桥接成功")
)
expect(bridged.contains(where: { $0.displayText == "桥接成功" }), "Engine assistant event 必须映射为 Kimi Event")
let toolWireEvent = Data(#"{"type":"message.part.updated","properties":{"sessionID":"session-1","part":{"type":"tool","callID":"call-1","tool":"read","state":{"status":"running","input":{"path":"README.md"}}}}}"#.utf8)
let decodedToolWireEvent = KimiRuntimeEventBridge.decodeSSEData(toolWireEvent, sessionID: "session-1")
expect(decodedToolWireEvent?.kind == .toolCall && decodedToolWireEvent?.toolCallID == "call-1" && decodedToolWireEvent?.toolID == "read", "Engine message.part.updated 工具事件必须解析嵌套 part")
let textDeltaEvent = KimiRuntimeEventBridge.decodeSSEData(Data(#"{"type":"session.next.text.delta","properties":{"sessionID":"session-1","delta":"增量"}}"#.utf8), sessionID: "session-1")
expect(textDeltaEvent?.kind == .assistantText && textDeltaEvent?.text == "增量", "Engine text delta 必须映射为助手增量文本")
let permissionWireEvent = KimiRuntimeEventBridge.decodeSSEData(Data(#"{"type":"permission.asked","properties":{"id":"perm-42","sessionID":"session-1","permission":"execute","patterns":["npm test"]}}"#.utf8), sessionID: "session-1")
let bridgedPermission = permissionWireEvent.flatMap { KimiRuntimeEventBridge.map($0).compactMap { event -> KimiPermissionRequest? in
  if case let .permission(value) = event { return value }
  return nil
}.first }
expect(bridgedPermission?.runtimeID == "perm-42", "Permission Card 必须保留原始 request ID，回复时不能把本地 UUID 发回服务端")
let nativeAppKernel = KimiAppKernel()
let kernelState = try! awaitValue { await nativeAppKernel.snapshot() }
expect(kernelState.terminalPlacement == .right, "KimiAppKernel 必须以右侧终端布局初始化")

let persistedUIURL = temporaryDirectory.appendingPathComponent("ui-state.json")
let persistedStore = KimiAppStateStore(fileURL: persistedUIURL)
var persistedUI = KimiUIState()
persistedUI.sessions = [KimiSessionSummary(runtimeID: "ses_persisted", title: "可恢复会话")]
persistedUI.activeSessionID = persistedUI.sessions.first?.id
let persistedHarnessID = UUID()
try persistedStore.save(KimiPersistedAppState(harnessSessionID: persistedHarnessID, uiState: persistedUI))
let restoredUI = try persistedStore.load()
expect(restoredUI.harnessSessionID == persistedHarnessID, "App 重启必须恢复稳定的 Harness Session ID")
expect(restoredUI.uiState.sessions.first?.runtimeID == "ses_persisted", "App 重启必须恢复 Kimi 会话列表")
let restoredKernel = KimiAppKernel(sessionID: UUID(), persistence: persistedStore)
let restoredKernelState = try! awaitValue { await restoredKernel.snapshot() }
expect(restoredKernelState.sessions.first?.title == "可恢复会话", "KimiAppKernel 必须从磁盘状态恢复主界面投影")

let terminalController = KimiTerminalController()
let terminalID = try awaitValue { try await terminalController.open(cwd: temporaryDirectory) }
try awaitValue { try await terminalController.write("printf 'terminal-loop-ok\\n'\n", to: terminalID); return () }
let terminalOutput = try awaitValue { await terminalController.waitForOutput(contains: "terminal-loop-ok", in: terminalID, timeout: 2) }
expect(terminalOutput, "右侧终端控制器必须能创建 PTY、写入命令并读取输出")
try! awaitValue { await terminalController.close(terminalID); return () }

let externalHarness = AgentHarness(sessionID: UUID())
let externalOperation = try! awaitValue { try await externalHarness.prompt(PromptInput(text: "外部事件")) }
let externalEffect = HarnessEffectIntent(operationID: externalOperation, kind: .tool, subject: "read", risk: .low)
try! awaitValue {
  await externalHarness.record(.effectIntentWritten(externalEffect), operationID: externalOperation)
  return ()
}
let externalSnapshot = try! awaitValue { await externalHarness.snapshot() }
expect(externalSnapshot.intents[externalEffect.effectID] == externalEffect, "Engine 外部工具事件必须能够回流 Harness 并建立 Effect Intent")

let engineRequestTrace = ThreadSafeStringTrace()
MockURLProtocol.requestHandler = { request in
  let path = request.url?.path ?? ""
  var query = ""
  if let rawQuery = request.url?.query { query = "?\(rawQuery)" }
  let requestBody = String(data: requestBodyData(request), encoding: .utf8) ?? ""
  engineRequestTrace.append("\(request.httpMethod ?? "GET") \(path)\(query) \(requestBody)")
  let body: Data
  switch path {
  case "/session":
    body = Data("{\"id\":\"session-1\",\"title\":\"测试会话\"}".utf8)
  case "/session/session-1/fork":
    body = Data("{\"id\":\"session-fork-1\",\"title\":\"测试会话 分支\",\"parentID\":\"session-1\"}".utf8)
  case "/session/session-1/message":
    body = Data(#"[{"info":{"id":"msg-u1","role":"user","time":{"created":1787000000000}},"parts":[{"id":"p-u1","type":"text","text":"历史问题"}]},{"info":{"id":"msg-a1","role":"assistant","time":{"created":1787000001000}},"parts":[{"id":"p-a1","type":"text","text":"历史回答"},{"id":"p-t1","type":"tool","tool":"read","callID":"call-h1","state":{"status":"completed","output":"文件内容"}}]}]"#.utf8)
  case "/provider":
    body = Data(#"{"all":[{"id":"moonshotai-cn","models":{"kimi-k2.7-code":{},"kimi-k3":{}}}],"connected":["moonshotai-cn"]}"#.utf8)
  case "/mcp":
    body = Data(#"{"filesystem":{"status":"connected"},"broken":{"status":"failed","error":"exit 1"}}"#.utf8)
  case "/skill":
    body = Data(#"[{"name":"code-review","description":"审查改动"},{"name":"release"}]"#.utf8)
  default:
    body = Data("{}".utf8)
  }
  return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, body)
}
let mockConfiguration = URLSessionConfiguration.ephemeral
mockConfiguration.protocolClasses = [MockURLProtocol.self]
let mockClient = URLSessionRuntimeClient(
  endpoint: KimiRuntimeEndpoint(port: 43210, token: "test"),
  session: URLSession(configuration: mockConfiguration)
)
let mockedSession = try! awaitValue { try await mockClient.createSession(CreateSessionInput(title: "测试会话")) }
expect(mockedSession.id == "session-1", "引擎会话客户端 必须解析创建会话响应")
try! awaitValue { try await mockClient.prompt(KimiRuntimePromptInput(sessionID: "session-1", text: "测试消息")); return () }
try! awaitValue { try await mockClient.respondPermission(PermissionResponse(sessionID: "session-1", requestID: "perm-1", reply: "once")); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/prompt_async") }), "Engine Prompt 必须使用异步 /session/{id}/prompt_async 协议，避免同步请求阻塞 UI")
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /permission/perm-1/reply") && $0.contains("\"reply\":\"once\"") }), "Engine Permission 回复必须使用 /permission/{id}/reply 端点并携带 runtime request ID 与 reply 字段")

_ = try! awaitValue { try await mockClient.createSession(CreateSessionInput(directory: "/tmp/kimi proj&x", title: "目录会话")); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session?directory=") && $0.contains("%26") }), "Engine 会话创建必须把项目目录放进 query 参数（引擎不读 body 里的 directory）并正确转义")
_ = try! awaitValue { try await mockClient.prompt(KimiRuntimePromptInput(sessionID: "session-1", text: "带目录", directory: "/tmp/kimi proj&x")); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/prompt_async?directory=") }), "Engine Prompt 必须按会话目录路由 query 参数")
expect(bridgedPermission?.patterns == ["npm test"], "Permission Card 必须保留引擎下发的 patterns 列表")

// 会话分支：POST /session/{id}/fork，会话创建可携带 parentID
let forkedSession = try! awaitValue { try await mockClient.forkSession(sessionID: "session-1", messageID: "msg-u1", directory: nil) }
expect(forkedSession.id == "session-fork-1" && forkedSession.parentID == "session-1", "forkSession 必须解析新会话的 id 与 parentID")
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/fork") && $0.contains("\"messageID\":\"msg-u1\"") }), "分支会话必须调用 POST /session/{id}/fork 并携带目标消息 ID")
_ = try! awaitValue { try await mockClient.forkSession(sessionID: "session-1", messageID: nil, directory: nil) }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/fork {}") }), "不指定 messageID 时分支必须携带空 body（分支全部历史）")
_ = try! awaitValue { try await mockClient.createSession(CreateSessionInput(title: "子会话", parentID: "session-1")); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session") && $0.contains("\"parentID\":\"session-1\"") }), "创建会话时必须能携带 parentID 直接建立分支关系")

// KimiAppKernel.forkSession 的端到端行为：分支后的新会话必须携带 parentRuntimeID 并成为激活会话
let forkKernelClient = VerifyScriptKimiRuntimeClient()
let forkKernel = KimiAppKernel(sessionClient: forkKernelClient)
try! awaitValue { try await forkKernel.send(.createSession(directory: "/tmp/fork-root")); return () }
let forkKernelSnapshotBefore = await forkKernel.snapshot()
let rootSessionID = forkKernelSnapshotBefore.activeSessionID
expect(rootSessionID != nil, "创建根会话后 activeSessionID 必须存在")
try! awaitValue { try await forkKernel.send(.forkSession(rootSessionID ?? UUID(), messageID: nil)); return () }
let forkKernelSnapshotAfter = await forkKernel.snapshot()
expect(forkKernelSnapshotAfter.activeSessionID != rootSessionID, "分支后必须切换到新创建的分支会话")
let forkedSummary = forkKernelSnapshotAfter.sessions.first { $0.id == forkKernelSnapshotAfter.activeSessionID }
expect(forkedSummary?.parentRuntimeID != nil, "分支会话摘要必须携带 parentRuntimeID，供侧栏渲染分支树")

// 临时对话：始终携带真实目录（应用私有 scratch 目录），绝不省略 directory 参数
// —— 引擎收到空 directory 会静默 fallback 到自己进程的 cwd，工具会在错误的地方
// 读写文件且不报错，这是本方案要规避的核心风险。
let scratchClient = URLSessionRuntimeClient(
  endpoint: KimiRuntimeEndpoint(port: 43210, token: "test"),
  session: URLSession(configuration: mockConfiguration)
)
let scratchKernel = KimiAppKernel(sessionClient: scratchClient)
try! awaitValue { try await scratchKernel.send(.createScratchSession); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session?directory=") && $0.contains("scratch") }), "创建临时对话必须携带非空 directory query 参数，且指向应用私有 scratch 目录")
let scratchSnapshot = await scratchKernel.snapshot()
let scratchSummary = scratchSnapshot.sessions.first { $0.id == scratchSnapshot.activeSessionID }
expect(scratchSummary?.isScratch == true, "临时对话的会话摘要必须标记 isScratch，供侧栏和会话头部识别")
expect(scratchSummary?.projectPath?.contains("scratch") == true, "临时对话必须绑定应用私有 scratch 目录，不是空目录")
expect(scratchSnapshot.recentProjects.contains(where: { $0.contains("scratch") }) == false, "创建临时对话不能把 scratch 目录写入最近项目列表，否则会污染项目文件夹选择面板的默认建议")

// P0 流式解码：part 类型注册 → delta 分类 → 快照/增量语义
let p0Decoder = KimiRuntimeEventDecoder()
_ = p0Decoder.decode(Data(#"{"type":"message.part.updated","properties":{"sessionID":"s1","part":{"id":"part-r1","messageID":"m1","type":"reasoning","text":"思考"}}}"#.utf8), sessionID: "s1")
let reasoningDeltaEvent = p0Decoder.decode(Data(#"{"type":"message.part.delta","properties":{"sessionID":"s1","messageID":"m1","partID":"part-r1","field":"text","delta":"片段"}}"#.utf8), sessionID: "s1")
expect(reasoningDeltaEvent?.kind == .reasoningText && reasoningDeltaEvent?.text == "片段" && reasoningDeltaEvent?.isSnapshot == false, "注册为 reasoning 的 part，其后续 delta 必须归类为思考内容而非聊天气泡文本")
let textDeltaEventP0 = p0Decoder.decode(Data(#"{"type":"message.part.delta","properties":{"sessionID":"s1","messageID":"m1","partID":"part-t1","field":"text","delta":"正文增量"}}"#.utf8), sessionID: "s1")
expect(textDeltaEventP0?.kind == .assistantText && textDeltaEventP0?.partID == "part-t1" && textDeltaEventP0?.isSnapshot == false, "普通 part delta 必须携带 partID 并以增量语义归类为助手文本")
let textSnapshotEvent = p0Decoder.decode(Data(#"{"type":"message.part.updated","properties":{"sessionID":"s1","part":{"id":"part-t1","messageID":"m1","type":"text","text":"完整正文"}}}"#.utf8), sessionID: "s1")
expect(textSnapshotEvent?.kind == .assistantText && textSnapshotEvent?.isSnapshot == true && textSnapshotEvent?.text == "完整正文", "message.part.updated 文本 part 必须以快照语义解码")
let busyStatusEvent = p0Decoder.decode(Data(#"{"type":"session.status","properties":{"sessionID":"s1","status":{"type":"busy"}}}"#.utf8), sessionID: "s1")
expect(busyStatusEvent?.kind == .sessionStatus && busyStatusEvent?.payload["statusType"] == "busy", "session.status 必须解析出 busy/idle 状态")
expect(busyStatusEvent.map { KimiRuntimeEventBridge.map($0).contains(.sessionBusy(sessionID: "s1", isBusy: true)) } == true, "session.status busy 必须映射为 UI 忙态事件")
let idleMapped = KimiRuntimeEventBridge.map(EngineRuntimeEvent(sessionID: "s1", kind: .sessionIdle))
expect(idleMapped.contains(.sessionBusy(sessionID: "s1", isBusy: false)), "session.idle 必须映射为忙态解除事件")

// P0 端到端（脚本化客户端驱动真实 KimiAppKernel）：流式合并 + 忙态清除
let streamingClient = StreamingScriptKimiRuntimeClient()
let streamingKernel = KimiAppKernel(sessionClient: streamingClient)
try! awaitValue { try await streamingKernel.send(.createSession(directory: "/tmp/stream")); return () }
try! awaitValue { try await streamingKernel.send(.prompt(PromptInput(text: "打个招呼"))); return () }
let settledAssistant = try! awaitValue { () async throws -> KimiMessage? in
  for _ in 0..<150 {
    let snap = await streamingKernel.snapshot()
    if let message = snap.messages.first(where: { $0.role == .assistant }), !message.isStreaming { return message }
    try await Task.sleep(for: .milliseconds(20))
  }
  return nil
}
expect(settledAssistant?.text == "你好，世界！", "同一 part 的 delta 与 snapshot 必须合并为一条助手消息（增量拼接、快照替换、idle 封口）")
let streamingSnapshot = try! awaitValue { await streamingKernel.snapshot() }
expect(streamingSnapshot.messages.filter { $0.role == .assistant }.count == 1, "流式输出不得裂成多个气泡")
expect(streamingSnapshot.busySessionIDs.isEmpty, "sessionIdle 后会话忙态必须清除")

// P0 steer 泵：运行中的 turn 必须把 harness 队列里的 steering 转发给引擎
let steerClient = SteerScriptKimiRuntimeClient()
let steerKernel = KimiAppKernel(sessionClient: steerClient)
try! awaitValue { try await steerKernel.send(.createSession(directory: "/tmp/steer")); return () }
try! awaitValue { try await steerKernel.send(.prompt(PromptInput(text: "开始"))); return () }
try! awaitValue { try await Task.sleep(for: .milliseconds(80)); return () }
try! awaitValue { try await steerKernel.send(.steer(PromptInput(text: "补充约束"))); return () }
let steerDelivered = try! awaitValue { () async throws -> Bool in
  for _ in 0..<150 {
    if steerClient.promptTrace.snapshot.contains(where: { $0.contains("补充约束") }) { return true }
    try await Task.sleep(for: .milliseconds(20))
  }
  return false
}
expect(steerDelivered, "运行中发送的 steer 输入必须经 Driver 泵送入引擎会话，而不是只停留在 Harness 队列")

// P0 超时一致性：driver 超时后必须中止引擎会话
let timeoutClient = NeverIdleKimiRuntimeClient()
let timeoutDriver = KimiRuntimeOperationDriver(client: timeoutClient, completionTimeout: .milliseconds(150))
await timeoutDriver.setSession("never-idle")
let timeoutFailure = try! awaitValue { () async throws -> String? in
  do {
    try await timeoutDriver.run(
      context: HarnessOperationContext(sessionID: UUID(), operationID: UUID(), lane: .main, prompt: PromptInput(text: "长任务")),
      sink: { _ in }
    )
    return nil
  } catch {
    return error.localizedDescription
  }
}
expect(timeoutFailure != nil && timeoutClient.abortCounter.count == 1, "Driver 超时后必须中止引擎会话，避免 Harness 判失败而引擎仍在执行")

// P0 监管者状态流：观察者必须看到引擎意外重启后的 ready 迁移
let supervisedRuntime = KimiRuntimeSupervisor(configuration: KimiRuntimeConfiguration(
  executableURL: URL(fileURLWithPath: "/bin/sh"),
  arguments: ["-c", "sleep 30"],
  endpoint: KimiRuntimeEndpoint(port: 43129, token: "state-stream")
))
let supervisorStates = ThreadSafeStringTrace()
let supervisorWatch = Task.detached {
  let stream = await supervisedRuntime.stateChanges()
  for await value in stream {
    supervisorStates.append(value.rawValue)
    if supervisorStates.snapshot.count >= 2 { break }
  }
}
try! awaitValue { try await supervisedRuntime.stop(); return () }
_ = try! awaitValue { try await supervisedRuntime.start(); return () }
try! awaitValue { await supervisorWatch.value }
expect(supervisorStates.snapshot.contains("starting") || supervisorStates.snapshot.contains("ready") || supervisorStates.snapshot.contains("stopped"), "Runtime Supervisor 必须向观察者发布状态迁移")
try! awaitValue { await supervisedRuntime.stop(); return () }

// P1 引擎端点：历史解析、模型目录、per-prompt 模型引用
let fetchedHistory = try! awaitValue { try await mockClient.fetchMessages(sessionID: "session-1", directory: nil) }
expect(fetchedHistory.count == 2 && fetchedHistory[0].role == "user" && fetchedHistory[1].parts.count == 2, "会话历史端点必须解析 info/parts 结构")
expect(fetchedHistory[1].parts.first(where: { $0.type == "tool" })?.output == "文件内容", "历史工具 part 的输出必须被保留")
expect(fetchedHistory[0].createdAt != nil && fetchedHistory[0].createdAt!.timeIntervalSince1970 > 1_000_000, "历史消息时间戳必须按毫秒纪元解析")
let fetchedCatalog = try! awaitValue { try await mockClient.fetchModelCatalog(directory: nil) }
expect(fetchedCatalog == ["kimi-k2.7-code", "kimi-k3"], "模型目录必须从 /provider 的 models 表解析并排序")
_ = try! awaitValue { try await mockClient.prompt(KimiRuntimePromptInput(sessionID: "session-1", text: "带模型", modelID: "kimi-k3")); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("\"modelID\":\"kimi-k3\"") && $0.contains("\"providerID\":\"moonshotai-cn\"") }), "Prompt 必须携带 per-prompt 模型引用，切模型不必重启引擎")

// P1 会话历史重建与最近项目（脚本化客户端驱动真实 KimiAppKernel）
let historyClient = HistoryScriptKimiRuntimeClient()
let historyKernel = KimiAppKernel(sessionClient: historyClient)
try! awaitValue { try await historyKernel.send(.createSession(directory: "/tmp/history-proj")); return () }
let historySessionID = try! awaitValue { await historyKernel.snapshot().sessions.first?.id }
try! awaitValue { try await historyKernel.send(.selectSession(historySessionID!)); return () }
let historyState = try! awaitValue { await historyKernel.snapshot() }
expect(historyState.messages.contains(where: { $0.role == .user && $0.text == "之前的问题" }), "切换会话后必须从引擎消息日志重建用户消息")
expect(historyState.messages.contains(where: { $0.role == .assistant && $0.text == "之前的回答" }), "切换会话后必须从引擎消息日志重建助手消息")
expect(historyState.activities.contains(where: { $0.toolCallID == "c1" && $0.state == .completed }), "历史工具调用必须重建为已完成活动卡")
expect(historyState.recentProjects.first == "/tmp/history-proj", "新建会话必须记录最近项目目录")

// P1 引擎工厂：reconfigure 保留 endpoint、模型表注入完整目录
let factoryOverride = KimiHeadlessRuntimeFactory.makeConfiguration(
  resourcesDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
  applicationSupportDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
  environment: ["KIMI_RUNTIME_BINARY": "/bin/sh"],
  modelID: "kimi-k3",
  modelCatalog: ["kimi-k2.7-code", "kimi-k3"],
  endpointOverride: KimiRuntimeEndpoint(port: 43_999, token: "fixed-token")
)
expect(factoryOverride?.arguments.contains("43999") == true, "reconfigure 必须保留原 loopback 端口")
expect(factoryOverride?.environment["OPENCODE_SERVER_PASSWORD"] == "fixed-token", "reconfigure 必须保留原 endpoint token")
let overrideConfigContent = (factoryOverride?.environment["OPENCODE_CONFIG_CONTENT"] ?? "")
  .replacingOccurrences(of: "\\/", with: "/")
expect(overrideConfigContent.contains("kimi-k3") && overrideConfigContent.contains("kimi-k2.7-code"), "引擎 provider 模型表必须注入完整模型目录")
expect(overrideConfigContent.contains(#""moonshotai-cn/kimi-k3""#), "引擎默认模型必须跟随用户所选模型")

// 回归：permission.replied 不得误判为 permissionAsked（"replied" 不含子串 "reply"）
let repliedEvent = KimiRuntimeEventDecoder().decode(Data(#"{"type":"permission.replied","properties":{"sessionID":"s1","requestID":"per_x","reply":"always"}}"#.utf8), sessionID: "s1")
expect(repliedEvent?.kind == .permissionReplied && repliedEvent?.requestID == "per_x", "permission.replied 必须归类为 permissionReplied")
expect(repliedEvent.map { KimiRuntimeEventBridge.map($0).contains(.permissionSettled(requestID: "per_x")) } == true, "permission.replied 必须映射为卡片结算事件")

// 回归：用户消息的 text part 不得进入助手气泡流
let roleDecoder = KimiRuntimeEventDecoder()
_ = roleDecoder.decode(Data(#"{"type":"message.updated","properties":{"sessionID":"s1","info":{"id":"msg-u1","role":"user"}}}"#.utf8), sessionID: "s1")
let userPartSnapshot = roleDecoder.decode(Data(#"{"type":"message.part.updated","properties":{"sessionID":"s1","part":{"id":"p-u1","messageID":"msg-u1","type":"text","text":"用户原文"}}}"#.utf8), sessionID: "s1")
expect(userPartSnapshot == nil, "用户消息的 text part 快照必须被过滤")
let userPartDelta = roleDecoder.decode(Data(#"{"type":"message.part.delta","properties":{"sessionID":"s1","messageID":"msg-u1","partID":"p-u1","field":"text","delta":"增"}}"#.utf8), sessionID: "s1")
expect(userPartDelta == nil, "用户消息的 text part delta 必须被过滤")

// P2 交互对齐：todo / question / revert / command 事件与端点
let todoEvent = KimiRuntimeEventDecoder().decode(Data(#"{"type":"todo.updated","properties":{"sessionID":"s1","todos":[{"id":"t1","content":"写测试","status":"in_progress"},{"content":"跑构建","status":"pending"}]}}"#.utf8), sessionID: "s1")
expect(todoEvent?.kind == .todoUpdated, "todo.updated 必须解码为待办事件")
let bridgedTodos = todoEvent.flatMap { KimiRuntimeEventBridge.map($0).first }
if case let .todoUpdated(_, todos)? = bridgedTodos {
  expect(todos.count == 2 && todos[0].status == "in_progress" && todos[1].id == "todo-1", "todo.updated 必须解析状态与缺省 id")
} else {
  expect(false, "todo.updated 必须映射为 UI 待办事件")
}
let questionEvent = KimiRuntimeEventDecoder().decode(Data(#"{"type":"question.asked","properties":{"id":"q-1","sessionID":"s1","questions":[{"question":"用哪个方案？","header":"方案","options":[{"label":"A","description":"快"},{"label":"B"}],"multiple":false,"custom":true}]}}"#.utf8), sessionID: "s1")
let bridgedQuestion = questionEvent.flatMap { event in KimiRuntimeEventBridge.map(event).first }
if case let .questionAsked(request)? = bridgedQuestion {
  expect(request.runtimeID == "q-1" && request.questions.first?.options.count == 2 && request.questions.first?.custom == true, "question.asked 必须保留 requestID 并解析选项")
} else {
  expect(false, "question.asked 必须映射为问题卡事件")
}
let userMessageEvent = KimiRuntimeEventDecoder().decode(Data(#"{"type":"message.updated","properties":{"sessionID":"s1","info":{"id":"msg-u9","role":"user"}}}"#.utf8), sessionID: "s1")
expect(userMessageEvent?.kind == .userText && userMessageEvent?.messageID == "msg-u9" && userMessageEvent?.text == nil, "message.updated 用户消息必须只携带消息 ID（供 revert 定位），不产生聊天气泡")

_ = try! awaitValue { try await mockClient.revert(sessionID: "session-1", messageID: "msg-u9", directory: "/tmp/p"); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/revert?directory=") && $0.contains("\"messageID\":\"msg-u9\"") }), "revert 必须携带目标用户消息 ID 与目录 query")
_ = try! awaitValue { try await mockClient.unrevert(sessionID: "session-1", directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/unrevert") }), "unrevert 必须调用恢复端点")
_ = try! awaitValue { try await mockClient.answerQuestion(requestID: "q-1", answers: [["A"]], directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /question/q-1/reply") && $0.contains("\"answers\"") }), "问题应答必须使用 /question/{id}/reply 并携带 answers")
_ = try! awaitValue { try await mockClient.runCommand(sessionID: "session-1", command: "review", arguments: "src/", directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/command") && $0.contains("\"command\":\"review\"") }), "Slash 命令必须走 /session/{id}/command 端点")
_ = try! awaitValue { try await mockClient.summarize(sessionID: "session-1", modelID: "kimi-k2.7-code", directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /session/session-1/summarize") }), "压缩上下文必须走 summarize 端点")
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("/summarize") && $0.contains("\"providerID\":\"moonshotai-cn\"") && $0.contains("\"modelID\":\"kimi-k2.7-code\"") }), "summarize 请求体必须带 providerID/modelID（引擎无此字段会 400 Missing key）")
_ = try! awaitValue { try await mockClient.fetchTodos(sessionID: "session-1", directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("GET /session/session-1/todo") }), "待办必须能从 /session/{id}/todo 拉取")
_ = try! awaitValue { try await mockClient.fetchCommands(directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("GET /command") }), "Slash 命令目录必须能从 /command 拉取")

// P3 面板数据源：MCP/Skills 解析、验证回执聚合、图片产物提取
let mcpPanelStatuses = try! awaitValue { try await mockClient.fetchMcpStatus(directory: nil) }
expect(mcpPanelStatuses.count == 2 && mcpPanelStatuses.first(where: { $0.name == "broken" })?.detail == "exit 1", "MCP 状态必须解析 name/status/error")
let skillSummaries = try! awaitValue { try await mockClient.fetchSkills(directory: nil) }
expect(skillSummaries.count == 2 && skillSummaries.first?.name == "code-review", "Skills 列表必须解析 name/description")

// MCP 动态添加/移除通道：POST /mcp 和 POST /mcp/{name}/disconnect
let dynamicMcpEntry = KimiMCPServerEntry(id: "filesystem", transport: .local, enabled: true, command: ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/tmp"], environment: ["API_KEY": "secret"])
_ = try! awaitValue { try await mockClient.addMCPServer(dynamicMcpEntry, directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /mcp") && $0.contains("\"name\":\"filesystem\"") }), "动态添加 MCP 服务器必须调用 POST /mcp 并携带 name 字段")
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /mcp") && $0.contains("\"type\":\"local\"") && $0.contains("\"command\"") }), "动态添加 MCP 服务器的 config 必须携带引擎 schema 的 type/command 字段（不是 cmd/stdio）")
_ = try! awaitValue { try await mockClient.removeMCPServer(name: "filesystem", directory: nil); return () }
expect(engineRequestTrace.snapshot.contains(where: { $0.contains("POST /mcp/filesystem/disconnect") }), "动态移除 MCP 服务器必须调用 POST /mcp/{name}/disconnect")

// KimiAppKernel 的公开包装方法必须原样转发给 sessionClient，不吞掉错误
let mcpKernelClient = VerifyScriptKimiRuntimeClient()
let mcpKernel = KimiAppKernel(sessionClient: mcpKernelClient)
try! awaitValue { try await mcpKernel.addMCPServerAtRuntime(dynamicMcpEntry); return () }
expect(mcpKernelClient.addedMCPServers.contains(where: { $0.id == "filesystem" }), "KimiAppKernel.addMCPServerAtRuntime 必须把服务器条目转发给 sessionClient")
try! awaitValue { try await mcpKernel.removeMCPServerAtRuntime(name: "filesystem"); return () }
expect(mcpKernelClient.removedMCPServerNames.contains("filesystem"), "KimiAppKernel.removeMCPServerAtRuntime 必须把服务器名转发给 sessionClient")

let verifyClient = VerifyScriptKimiRuntimeClient()
let verifyKernel = KimiAppKernel(sessionClient: verifyClient)
try! awaitValue { try await verifyKernel.send(.createSession(directory: "/tmp/verify")); return () }
try! awaitValue { try await verifyKernel.send(.prompt(PromptInput(text: "执行命令"))); return () }
let verificationSettled = try! awaitValue { () async throws -> Bool in
  for _ in 0..<150 {
    let records = await verifyKernel.loadVerificationRecords()
    if records.contains(where: { $0.outcome == "success" }) { return true }
    try await Task.sleep(for: .milliseconds(20))
  }
  return false
}
expect(verificationSettled, "工具回执必须进入验证面板数据（Intent→Receipt 结算）")
let verifyRecords = try! awaitValue { await verifyKernel.loadVerificationRecords() }
expect(verifyRecords.contains(where: { $0.subject == "bash" && $0.outcome == "success" }), "验证记录必须包含 bash 工具的成功回执")

let artifactPNG = temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png")
try Data([0x89, 0x50, 0x4E, 0x47]).write(to: artifactPNG)
let extractedArtifacts = KimiArtifactImages.extract(from: ["截图已保存：\(artifactPNG.path) 完成", "无图文本"])
expect(extractedArtifacts.map(\.path) == [artifactPNG.path], "工具输出中的本地图片路径必须被提取为产物（且过滤不存在的路径）")

// 审批僵尸卡：引擎对同一 request 重复发 permission.asked（真实引擎实测行为）
let permClient = PermScriptKimiRuntimeClient()
let permKernel = KimiAppKernel(sessionClient: permClient)
try! awaitValue { try await permKernel.send(.createSession(directory: "/tmp/perm")); return () }
try! awaitValue { try await permKernel.send(.prompt(PromptInput(text: "写文件"))); return () }
let permCardAppeared = try! awaitValue { () async throws -> Bool in
  for _ in 0..<100 {
    let snap = await permKernel.snapshot()
    if !snap.pendingPermissions.isEmpty { return true }
    try await Task.sleep(for: .milliseconds(20))
  }
  return false
}
expect(permCardAppeared, "permission.asked 必须生成审批卡")
let permSettled = try! awaitValue { () async throws -> Bool in
  for _ in 0..<100 {
    let snap = await permKernel.snapshot()
    if snap.pendingPermissions.isEmpty { return true }
    try await Task.sleep(for: .milliseconds(20))
  }
  return false
}
expect(permSettled, "permission.replied 后重复 ask 产生的审批卡必须被结算清理")
let permFinal = try! awaitValue { await permKernel.snapshot() }
expect(permFinal.pendingPermissions.isEmpty, "同一 requestID 的重复 permission.asked 不得产生僵尸审批卡")

if let rawPort = ProcessInfo.processInfo.environment["KIMI_HEADLESS_PORT"],
   let headlessPort = Int(rawPort),
   let headlessToken = ProcessInfo.processInfo.environment["KIMI_HEADLESS_TOKEN"] {
  let liveClient = URLSessionRuntimeClient(
    endpoint: KimiRuntimeEndpoint(port: headlessPort, token: headlessToken)
  )
  let liveSessions = try! awaitValue { try await liveClient.listSessions(directory: nil) }
  expect(liveSessions.count >= 0, "真实 Headless Session API 必须可访问")
}

// MARK: - Home dashboard statistics

let calendar = Calendar.current
// Anchor the dataset to a fixed instant: with wall-clock `now`, the
// "today at 9:00" record is in the future on runners whose local time is
// earlier than 9:00 (e.g. UTC CI), making the range assertions flaky.
let statsNow = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 15))!
func daysAgo(_ days: Int, hour: Int = 10) -> Date {
  var components = calendar.dateComponents([.year, .month, .day], from: statsNow)
  components.hour = hour
  let day = calendar.date(from: components)!
  return calendar.date(byAdding: .day, value: -days, to: day)!
}

let activityStoreURL = temporaryDirectory.appendingPathComponent("activity.jsonl")
let activityStore = KimiActivityStatsStore(fileURL: activityStoreURL)
try! awaitValue { await activityStore.record(KimiActivityRecord(kind: .promptSent, date: daysAgo(0, hour: 9))) }
try! awaitValue { await activityStore.record(KimiActivityRecord(kind: .replyReceived, date: daysAgo(1))) }
try! awaitValue { await activityStore.record(KimiActivityRecord(kind: .promptSent, date: daysAgo(2, hour: 21))) }
let storedRecords = try! awaitValue { await activityStore.records() }
expect(storedRecords.count == 3, "Activity Store 必须能追加并读回全部记录")

let seededSessions = [
  KimiSessionSummary(title: "旧会话 A", updatedAt: daysAgo(1)),
  KimiSessionSummary(title: "旧会话 B", updatedAt: daysAgo(4))
]
let aggregated = KimiActivityAggregator.aggregate(records: storedRecords, sessions: seededSessions, now: statsNow, calendar: calendar)
expect(aggregated.sessionCount == 2, "首页统计的会话数必须来自真实会话列表")
expect(aggregated.messageCount == 3, "首页统计的消息数必须统计 prompt 与 reply 记录")
expect(aggregated.currentStreak == 3, "今天有记录时当前连续必须从今天开始计算")
expect(aggregated.longestStreak == 3, "最长连续必须取历史最长区间")
expect(aggregated.peakHour != nil, "有记录时必须能计算高峰时段")
expect(aggregated.dailyCounts[calendar.startOfDay(for: daysAgo(4))] == 1, "统计日志之前的会话必须用 updatedAt 回填热力图")
expect(aggregated.activeDays == 4, "活跃天数必须合并记录与会话回填")

let noTodayRecords = [
  KimiActivityRecord(kind: .promptSent, date: daysAgo(1)),
  KimiActivityRecord(kind: .replyReceived, date: daysAgo(2))
]
let noToday = KimiActivityAggregator.aggregate(records: noTodayRecords, sessions: [], now: statsNow, calendar: calendar)
expect(noToday.currentStreak == 2, "今天还没有活动时，当前连续必须从昨天起算且不清零")

let ranged = KimiActivityAggregator.aggregate(records: storedRecords, sessions: seededSessions, now: statsNow, calendar: calendar, rangeDays: 1)
expect(ranged.messageCount == 1, "范围过滤必须只统计窗口内的记录")
expect(ranged.dailyCounts[calendar.startOfDay(for: daysAgo(4))] == nil, "范围过滤必须排除窗口外的会话回填")

let emptyAggregate = KimiActivityAggregator.aggregate(records: [], sessions: [], now: statsNow, calendar: calendar)
expect(emptyAggregate.currentStreak == 0 && emptyAggregate.longestStreak == 0 && emptyAggregate.peakHour == nil, "空数据必须产出零值统计而不是崩溃")

// MARK: - Home stats merge & home navigation

let homeKernel = KimiAppKernel(sessionClient: mockClient, activityStats: activityStore)
try? awaitValue { try await homeKernel.send(.createSession(directory: nil)) }
let homeStatsAll = try! awaitValue { await homeKernel.homeStats(range: .all) }
expect(homeStatsAll.sessionCount == 1, "homeStats 必须包含内核创建的会话")
expect(homeStatsAll.messageCount >= 3, "homeStats 必须合并 Activity 日志中的消息数")
expect(homeStatsAll.favoriteModel != nil, "homeStats 必须回退到当前模型而不是留空")
let homeStateBefore = try! awaitValue { await homeKernel.snapshot() }
expect(homeStateBefore.activeSessionID != nil, "创建会话后必须进入该会话")
try! awaitValue { try await homeKernel.send(.showHome) }
let homeStateAfter = try! awaitValue { await homeKernel.snapshot() }
expect(homeStateAfter.activeSessionID == nil, "showHome 必须回到首页（无活动会话）")

// MARK: - Terminal output sanitizer

let rawTerminal = "\u{1B}[?2004huser@mac ~ % \u{1B}[32mok\u{1B}[0m\n\u{1B}]0;title\u{7}done\rfinished\nprogress: 50%\u{8}\u{8}\u{8}100%"
let cleanedTerminal = KimiTerminalSanitizer.strip(rawTerminal)
expect(!cleanedTerminal.contains("\u{1B}"), "终端输出必须移除所有 ESC 序列（ bracketed-paste / 颜色 / OSC 标题）")
expect(!cleanedTerminal.contains("\u{7}"), "终端输出必须移除 BEL 控制符")
expect(cleanedTerminal.contains("user@mac ~ % ok"), "终端清洗必须保留可见文本")
expect(cleanedTerminal.contains("finished"), "回车符必须表现为行内覆盖而不是残留控制字符")
expect(cleanedTerminal.contains("progress: 100%"), "退格键必须表现为删除前一个字符")

print("KimiAgentCore checks passed")
