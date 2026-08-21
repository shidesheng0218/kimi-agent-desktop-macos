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

actor FlakyHarnessProvider: HarnessModelProvider {
  private var attempts = 0

  func stream(
    context: HarnessProviderContext,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessModelEvent, Error> {
    attempts += 1
    let attempt = attempts
    if attempt == 1 {
      throw NSError(domain: "FlakyHarnessProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "transient provider failure"])
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(.text("retry succeeded"))
      continuation.finish()
    }
  }
}

actor FlakyConversationProvider: HarnessConversationProvider {
  private var attempts = 0

  func stream(
    request: HarnessConversationRequest,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessConversationEvent, Error> {
    attempts += 1
    if attempts == 1 {
      throw NSError(domain: "FlakyConversationProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "transient conversation failure"])
    }
    return AsyncThrowingStream { continuation in
      continuation.yield(.text("conversation retry succeeded"))
      continuation.finish()
    }
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

final class IdleKimiRuntimeSessionClient: KimiRuntimeSessionClient, @unchecked Sendable {
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

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        try? await Task.sleep(for: .milliseconds(20))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionIdle))
        continuation.finish()
      }
    }
  }
}

/// Streams one scripted assistant turn (busy → deltas → snapshot → idle) so
/// checks can drive a real `KimiAppKernel` through the production ingest path.
final class StreamingScriptKimiRuntimeClient: KimiRuntimeSessionClient, @unchecked Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "stream-session", title: "流式", directory: "/tmp/stream")
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .assistantText, text: "你好，", messageID: "m1", partID: "p1"))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .assistantText, text: "世界", messageID: "m1", partID: "p1"))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .assistantText, text: "你好，世界！", messageID: "m1", partID: "p1", isSnapshot: true))
        try? await Task.sleep(for: .milliseconds(30))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionIdle))
        continuation.finish()
      }
    }
  }
}

/// Holds the turn open long enough for a steer message to be pumped in.
final class SteerScriptKimiRuntimeClient: KimiRuntimeSessionClient, @unchecked Sendable {
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

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        try? await Task.sleep(for: .milliseconds(900))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionIdle))
        continuation.finish()
      }
    }
  }
}

/// Never emits completion; used to prove the driver aborts the engine session
/// when its own timeout fires.
final class NeverIdleKimiRuntimeClient: KimiRuntimeSessionClient, @unchecked Sendable {
  let abortCounter = InvocationCounter()

  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "never-idle")
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws { abortCounter.increment() }
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        try? await Task.sleep(for: .seconds(30))
        continuation.finish()
      }
    }
  }
}

/// Serves a canned two-message conversation for history-restore checks.
final class HistoryScriptKimiRuntimeClient: KimiRuntimeSessionClient, @unchecked Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "history-session", title: "历史会话", directory: input.directory)
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
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
final class VerifyScriptKimiRuntimeClient: KimiRuntimeSessionClient, @unchecked Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "verify-session", title: "验证", directory: input.directory)
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .toolCall, toolCallID: "vtc1", toolID: "bash", payload: ["arguments": #"{"command":"swift build"}"#]))
        try? await Task.sleep(for: .milliseconds(20))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .toolResult, text: "Build complete", toolCallID: "vtc1", toolID: "bash", payload: ["status": "completed"]))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionIdle))
        continuation.finish()
      }
    }
  }
}

/// Emits the observed engine quirk: two permission.asked frames sharing one
/// requestID, then permission.replied, then idle.
final class PermScriptKimiRuntimeClient: KimiRuntimeSessionClient, @unchecked Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    KimiRuntimeSession(id: "perm-session", title: "审批", directory: input.directory)
  }

  func prompt(_ input: KimiRuntimePromptInput) async throws {}
  func steer(_ input: KimiRuntimeSteerInput) async throws {}
  func abort(sessionID: String, directory: String?) async throws {}
  func respondPermission(_ input: PermissionResponse) async throws {}
  func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { [] }

  func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionStatus, payload: ["statusType": "busy"]))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .permissionAsked, toolID: "edit", requestID: "per_zombie"))
        try? await Task.sleep(for: .milliseconds(30))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .permissionAsked, toolID: "edit", requestID: "per_zombie"))
        try? await Task.sleep(for: .milliseconds(30))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .permissionReplied, requestID: "per_zombie"))
        continuation.yield(KimiRuntimeEvent(sessionID: sessionID, kind: .sessionIdle))
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
let catalog = MCPToolCatalog()
catalog.register(serverID: "docs", status: .healthy, tools: [MCPTool(name: "search", description: "Search docs", inputSchemaJSON: "{}")])
expect(catalog.search(query: "search").count == 1, "MCP Tool Search 必须返回已发现工具")
expect(catalog.status(serverID: "docs") == .healthy, "MCP Server 状态必须可查询")
let mcpWorkerSupervisor = MCPWorkerSupervisor(maxRestarts: 1)
await mcpWorkerSupervisor.markHealthy(serverID: "docs")
let initiallyHealthyWorker = await mcpWorkerSupervisor.health(serverID: "docs")
expect(initiallyHealthyWorker?.status == .healthy, "MCP Worker 成功后必须记录 healthy 状态")
let firstMCPFailureCanReconnect = await mcpWorkerSupervisor.markFailure(serverID: "docs", message: "worker exited")
expect(firstMCPFailureCanReconnect, "MCP Worker 首次崩溃必须进入 reconnecting")
let reconnectingWorker = await mcpWorkerSupervisor.health(serverID: "docs")
expect(reconnectingWorker?.status == .reconnecting, "MCP Worker 崩溃期间必须显示 reconnecting，而不是伪造成功")
await mcpWorkerSupervisor.markHealthy(serverID: "docs")
let reconnectedWorker = await mcpWorkerSupervisor.health(serverID: "docs")
expect(reconnectedWorker?.status == .healthy, "MCP Worker 重连成功后必须恢复 healthy")
let repeatedMCPFailureCanReconnect = await mcpWorkerSupervisor.markFailure(serverID: "docs", message: "worker exited again")
expect(!repeatedMCPFailureCanReconnect, "MCP Worker 恢复后也必须保留生命周期重启预算，达到上限后不可无限重连")
let unavailableWorker = await mcpWorkerSupervisor.health(serverID: "docs")
expect(unavailableWorker?.status == .unavailable, "MCP Worker 达到上限后不得继续伪造可用")
let mcpStateURL = temporaryDirectory.appendingPathComponent("mcp-worker-status.json")
let durableMCPSupervisor = MCPWorkerSupervisor(maxRestarts: 3, stateFileURL: mcpStateURL)
await durableMCPSupervisor.markStarting(serverID: "durable-docs")
_ = await durableMCPSupervisor.markFailure(serverID: "durable-docs", message: "connection lost")
let restoredMCPSupervisor = MCPWorkerSupervisor(maxRestarts: 3, stateFileURL: mcpStateURL)
let restoredMCPHealth = await restoredMCPSupervisor.health(serverID: "durable-docs")
expect(restoredMCPHealth?.status == .reconnecting && restoredMCPHealth?.restartCount == 1, "MCP Worker 状态必须在重启后恢复，不能丢失重连预算")
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
let skillFile = temporaryDirectory.appendingPathComponent("SKILL.md")
try "---\nname: explain\ndescription: 解释项目\n---\n请用中文解释。".write(to: skillFile, atomically: true, encoding: .utf8)
let skill = SkillDescriptor(name: "explain", description: "解释项目", fileURL: skillFile)
let invocation = SkillInvocationParser.parse("/explain 当前文件", skills: [skill])
expect(invocation?.skill.name == "explain" && invocation?.arguments == "当前文件", "Skill 斜杠命令必须解析名称和参数")
expect(invocation?.prompt.contains("请用中文解释") == true, "Skill 调用必须延迟加载 SKILL.md 正文")
let reviewSkill = SkillDescriptor(name: "review", description: "审阅代码变更和回归风险", fileURL: skillFile)
let automaticSkill = SkillAutoMatcher.match(prompt: "请审阅这次代码变更并检查回归", skills: [skill, reviewSkill])
expect(automaticSkill?.name == "review", "Skill 自动匹配必须优先选择与用户任务相关的技能")
let automaticInvocation = SkillInvocationParser.automaticInvocation(
  prompt: "请审阅这次代码变更并检查回归",
  skills: [reviewSkill]
)
expect(
  automaticInvocation?.prompt.contains("自动匹配 Skill：/review") == true && automaticInvocation?.prompt.contains("请审阅这次代码变更") == true,
  "自动匹配的 Skill 必须保留原始用户请求并延迟加载指令"
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
let hookEngine = HarnessHookEngine(hooks: [
  HarnessHookDefinition(event: .beforeTool, priority: 10) { _ in .modify(arguments: ["path": "Sources/Safe.swift"]) },
  HarnessHookDefinition(event: .beforeTool, priority: 5) { _ in .injectContext(["只允许 Worktree 内写入"]) }
])
let hookResolution = try awaitValue { await hookEngine.evaluate(HarnessHookRequest(event: .beforeTool, toolID: "workspace_write", arguments: ["path": "../escape"])) }
expect(hookResolution.isAllowed && hookResolution.arguments["path"] == "Sources/Safe.swift", "Hook 修改参数后必须把受控参数返回给 Harness")
expect(hookResolution.context == ["只允许 Worktree 内写入"], "Hook 注入的上下文必须保留审计顺序")
let hookAskUser = HarnessHookEngine(hooks: [
  HarnessHookDefinition(event: .beforeTool) { _ in .askUser(reason: "需要确认") }
])
let askUserResolution = try awaitValue { await hookAskUser.evaluate(HarnessHookRequest(event: .beforeTool, toolID: "shell")) }
expect(askUserResolution.action == .askUser && !askUserResolution.isAllowed, "Hook askUser 必须转成内联审批状态")
let hookSkip = HarnessHookEngine(hooks: [
  HarnessHookDefinition(event: .beforeTool) { _ in .skip(reason: "无需执行") }
])
let skipResolution = try awaitValue { await hookSkip.evaluate(HarnessHookRequest(event: .beforeTool, toolID: "read")) }
expect(skipResolution.action == .skip && skipResolution.isAllowed, "Hook skip 必须可安全跳过当前工具")
let nestedHookRegistry = ToolRegistry(definitions: [
  ToolDefinition(
    id: "nested",
    title: "Nested",
    description: "保留嵌套参数",
    permissionScopes: [],
    inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"options":{"type":"object"}},"required":["path","options"],"additionalProperties":false}"#
  )
])
await nestedHookRegistry.register(
  ToolDefinition(
    id: "nested",
    title: "Nested",
    description: "保留嵌套参数",
    permissionScopes: [],
    inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"options":{"type":"object"}},"required":["path","options"],"additionalProperties":false}"#
  ),
  executor: ClosureToolExecutor { request in
    ToolExecutionResult(output: request.inputJSON.objectValue?["options"]?.objectValue?["mode"]?.stringValue ?? "missing")
  }
)
let nestedHookCoordinator = ToolExecutionCoordinator(
  registry: nestedHookRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  hookResolver: { _ in
    HarnessHookResolution(isAllowed: true, arguments: ["path": "rewritten.txt"], context: [], auditHookIDs: [])
  }
)
let nestedHookResult = try awaitValue {
  try await nestedHookCoordinator.execute(ToolExecutionRequest(
    taskID: UUID(),
    sessionID: UUID(),
    agentID: "test",
    toolID: "nested",
    inputJSON: .object([
      "path": .string("original.txt"),
      "options": .object(["mode": .string("preserved")])
    ])
  ))
}
expect(nestedHookResult.output == "preserved", "Hook 修改顶层参数时不得丢失嵌套 JSON 参数")
let hookRegistry = ToolRegistry(definitions: [ToolDefinition(id: "hooked", title: "Hooked", description: "hook test", permissionScopes: [])])
await hookRegistry.register(
  ToolDefinition(id: "hooked", title: "Hooked", description: "hook test", permissionScopes: []),
  executor: ClosureToolExecutor { request in
    ToolExecutionResult(output: request.input["path"] ?? "missing")
  }
)
let hookedCoordinator = ToolExecutionCoordinator(
  registry: hookRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  hookResolver: { request in
    HarnessHookResolution(isAllowed: true, arguments: ["path": "safe.txt"], context: [], auditHookIDs: [])
  }
)
let hookedResult = try await hookedCoordinator.execute(ToolExecutionRequest(taskID: UUID(), sessionID: UUID(), agentID: "test", toolID: "hooked", input: ["path": "../escape"]))
expect(hookedResult.output == "safe.txt", "Hook 修改参数后必须在真实 Tool 执行链生效")
let skipExecutionCounter = InvocationCounter()
let skipCoordinator = ToolExecutionCoordinator(
  registry: hookRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  hookResolver: { _ in
    HarnessHookResolution(action: .skip, isAllowed: true, denialReason: "hook skip", arguments: [:], context: [], auditHookIDs: [])
  }
)
await hookRegistry.register(
  ToolDefinition(id: "skipped", title: "Skipped", description: "skip test", permissionScopes: []),
  executor: ClosureToolExecutor { _ in
    skipExecutionCounter.increment()
    return ToolExecutionResult(output: "must not execute")
  }
)
let skippedResult = try awaitValue {
  try await skipCoordinator.execute(ToolExecutionRequest(taskID: UUID(), sessionID: UUID(), agentID: "test", toolID: "skipped"))
}
expect(skipExecutionCounter.count == 0 && skippedResult.metadata["hookAction"] == "skip", "Hook skip 必须在统一 Runtime 中短路执行且返回结构化结果")
let askApprovalCounter = InvocationCounter()
let askCoordinator = ToolExecutionCoordinator(
  registry: hookRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  approvalHandler: { _, _ in
    askApprovalCounter.increment()
    return .allow
  },
  hookResolver: { _ in
    HarnessHookResolution(action: .askUser, isAllowed: false, denialReason: "hook asks", arguments: [:], context: [], auditHookIDs: [])
  }
)
await hookRegistry.register(
  ToolDefinition(id: "asked", title: "Asked", description: "ask test", permissionScopes: []),
  executor: ClosureToolExecutor { _ in
    ToolExecutionResult(output: "approved")
  }
)
let askedResult = try awaitValue {
  try await askCoordinator.execute(ToolExecutionRequest(taskID: UUID(), sessionID: UUID(), agentID: "test", toolID: "asked"))
}
expect(askApprovalCounter.count == 1 && askedResult.output == "approved", "Hook askUser 必须复用统一审批入口后继续执行")
let retryHookCounter = InvocationCounter()
let retryCoordinator = ToolExecutionCoordinator(
  registry: hookRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  hookResolver: { _ in
    retryHookCounter.increment()
    if retryHookCounter.count == 1 {
      return HarnessHookResolution(action: .retry, isAllowed: true, denialReason: "transient hook", arguments: [:], context: [], auditHookIDs: [])
    }
    return HarnessHookResolution(isAllowed: true, arguments: [:], context: [], auditHookIDs: [])
  }
)
await hookRegistry.register(
  ToolDefinition(id: "retried", title: "Retried", description: "retry test", permissionScopes: []),
  executor: ClosureToolExecutor { _ in ToolExecutionResult(output: "retry approved") }
)
let retriedResult = try awaitValue {
  try await retryCoordinator.execute(ToolExecutionRequest(taskID: UUID(), sessionID: UUID(), agentID: "test", toolID: "retried"))
}
expect(retryHookCounter.count == 2 && retriedResult.output == "retry approved", "Hook retry 必须重新评估当前工具后再进入副作用链")

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

let exploreDefinition = AgentOrchestrator.builtInDefinition(for: .explore)
let childReadResolver = ChildAgentToolPermissionResolver(definition: exploreDefinition)
let childSearchDecision = await childReadResolver.resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "explore", toolID: "search", input: ["query": "Browser"]),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "search" })!
)
expect(childSearchDecision == .allow, "只读 Explore 的 search 不应重复弹出审批")
let browserContract = TaskContract.make(prompt: "请使用 Browser 打开 https://example.com 并截图", decision: TaskIntentRouter.decide(for: "请使用 Browser 打开 https://example.com 并截图"), mode: .plan)
let browserGraph = TaskGraphCompiler.compile(taskID: UUID(), sessionID: UUID(), contract: browserContract)
expect(browserGraph.nodes.map(\.stage) == [.browserVerification], "Browser 验证必须直达 Browser 阶段且不应被无关 Review 污染")
let computerContract = TaskContract.make(prompt: "请使用 Computer Use 检查当前窗口", decision: TaskIntentRouter.decide(for: "请使用 Computer Use 检查当前窗口"), mode: .plan)
let computerGraph = TaskGraphCompiler.compile(taskID: UUID(), sessionID: UUID(), contract: computerContract)
expect(computerGraph.nodes.map(\.stage) == [.computerUse], "Computer Use 必须直达专用阶段且不应显示为 Browser")
let conversationGraph = TaskGraphCompiler.compile(
  taskID: UUID(), sessionID: UUID(),
  contract: TaskContract.make(prompt: "你好", decision: TaskIntentRouter.decide(for: "你好"), mode: .plan)
)
expect(conversationGraph.nodes.isEmpty, "普通问候不得创建 Explore/Plan/Review 阶段")
let webResearchDecision = TaskIntentRouter.decide(for: "搜索 Kimi Agent 的最新文档")
expect(webResearchDecision.intent == .webResearch, "联网研究必须识别为 Web Research 意图")
expect(!webResearchDecision.requiresPlanning, "联网研究必须走低延迟主 Harness，不应创建通用 Plan/Explore 阶段")
expect(webResearchDecision.recommendedAgents == [.webResearch], "联网研究不得先启动无关 Explore")
let timelyMarketDecision = TaskIntentRouter.decide(for: "今天股市行情怎么样？")
expect(timelyMarketDecision.intent == .webResearch, "时效性行情问题必须自动进入联网研究，不能让模型在无网络情况下直接猜测")
let tomorrowWeatherDecision = TaskIntentRouter.decide(for: "明天大连的天气怎么样")
expect(tomorrowWeatherDecision.intent == .webResearch, "明天/未来天气必须自动进入联网研究，不能误走 Explore")
expect(!tomorrowWeatherDecision.requiresPlanning, "天气查询不应创建 Plan/Explore 阶段")
let webResearchGraph = TaskGraphCompiler.compile(
  taskID: UUID(), sessionID: UUID(),
  contract: TaskContract.make(prompt: "搜索 Kimi Agent 的最新文档", decision: webResearchDecision, mode: .plan)
)
expect(webResearchGraph.nodes.map(\.stage) == [.webResearch], "联网研究必须直接进入专用 Web Research 阶段")
let reviewNoise = AgentRun(
  parentSessionID: UUID(), taskID: UUID(),
  definition: AgentOrchestrator.builtInDefinition(for: .review),
  state: .completed,
  result: AgentResult(summary: "我当前环境中没有 Browser 工具，请提供 diff/patch 文件。")
)
let browserResult = AgentRun(
  parentSessionID: UUID(), taskID: UUID(),
  definition: AgentOrchestrator.builtInDefinition(for: .browserVerification),
  state: .completed,
  result: AgentResult(
    summary: "已打开 https://example.com/，检查 h1 并完成截图。",
    evidence: [AgentEvidence(label: "Browser Adapter", value: "已打开 https://example.com/", source: "harness receipt")],
    verification: ["Browser Adapter receipt 已成功结算。"]
  )
)
let mergedBrowser = AgentResultMerger.merge(
  runs: [reviewNoise, browserResult],
  contract: browserContract,
  requestedLanguage: .chinese
)
expect(mergedBrowser.outcome == .completed, "Browser 成功 Receipt 对应的阶段结果必须保持 completed")
expect(mergedBrowser.finalAnswer.contains("已打开 https://example.com"), "最终答案必须保留 Browser 的真实结果")
expect(!mergedBrowser.finalAnswer.contains("请提供 diff"), "最终答案不得混入 Review Agent 的无关自述")
let directReceiptBrowser = AgentRun(
  parentSessionID: UUID(), taskID: UUID(),
  definition: AgentOrchestrator.builtInDefinition(for: .browserVerification),
  state: .completed,
  result: AgentResult(summary: "已完成截图。", receiptIDs: [UUID()])
)
expect(
  AgentResultMerger.merge(runs: [directReceiptBrowser], contract: browserContract, requestedLanguage: .chinese).outcome == .completed,
  "结构化 Receipt ID 必须可以直接证明专用阶段完成"
)
let browserWithoutReceipt = AgentRun(
  parentSessionID: UUID(), taskID: UUID(),
  definition: AgentOrchestrator.builtInDefinition(for: .browserVerification),
  state: .completed,
  result: AgentResult(summary: "我已经验证了页面。")
)
let mergedWithoutReceipt = AgentResultMerger.merge(
  runs: [browserWithoutReceipt],
  contract: browserContract,
  requestedLanguage: .chinese
)
expect(mergedWithoutReceipt.outcome == .partial, "没有 Browser receipt 时不得标记任务完成")
expect(mergedWithoutReceipt.unresolved.contains(where: { $0.contains("receipt") }), "缺少 receipt 时最终答案必须明确指出未结算阶段")
let webResearchWithReceipt = AgentRun(
  parentSessionID: UUID(), taskID: UUID(),
  definition: AgentOrchestrator.builtInDefinition(for: .webResearch),
  state: .completed,
  result: AgentResult(
    summary: "已搜索并抓取 2 个来源。",
    evidence: [AgentEvidence(label: "Web Research", value: "2 个来源", source: "harness receipt")],
    verification: ["Web Research receipt 已成功结算。"]
  )
)
let mergedWebResearch = AgentResultMerger.merge(
  runs: [webResearchWithReceipt],
  contract: TaskContract.make(prompt: "搜索文档", decision: webResearchDecision, mode: .plan),
  requestedLanguage: .chinese
)
expect(mergedWebResearch.outcome == .completed, "Web Research receipt 成功后才允许标记任务完成")
let mcpCatalog = MCPToolCatalog()
mcpCatalog.register(serverID: "server", status: .healthy, tools: [
  MCPTool(name: "search_docs", description: "搜索项目文档", inputSchemaJSON: "{}"),
  MCPTool(name: "send_message", description: "发送消息给外部服务", inputSchemaJSON: "{}"),
  MCPTool(name: "list_files", description: "列出工作区文件", inputSchemaJSON: "{}")
])
let relevantMCP = mcpCatalog.relevant(query: "搜索文档", limit: 2)
expect(relevantMCP.first?.tool.name == "search_docs", "MCP Tool Search 必须优先选择与当前任务相关的工具")
expect(relevantMCP.count <= 2, "MCP Tool Search 必须限制注入模型的工具数量")
let childWriteDecision = await childReadResolver.resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "explore", toolID: "write"),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "write" })!
)
expect(childWriteDecision == .ask, "只读 Explore 的写入操作必须保留审批边界")
let browserReadDefinition = AgentDefinition(name: "browser", description: "只读浏览器验证", kind: .browser, allowedTools: ["browser"], permissionMode: .readOnly)
let browserInspectDecision = await ChildAgentToolPermissionResolver(definition: browserReadDefinition).resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "browser", toolID: "browser", input: ["action": "screenshot"]),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "browser" })!
)
expect(browserInspectDecision == .allow, "只读 Browser inspect/screenshot 不应被前置审批阻断")
let browserClickDecision = await ChildAgentToolPermissionResolver(definition: browserReadDefinition).resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "browser", toolID: "browser", input: ["action": "click"]),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "browser" })!
)
expect(browserClickDecision == .ask, "Browser 点击仍必须逐次审批")
let researchDefinition = AgentOrchestrator.builtInDefinition(for: .webResearch)
let researchResolver = ChildAgentToolPermissionResolver(definition: researchDefinition)
let researchSearchDecision = await researchResolver.resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "web-research", toolID: "web.search", input: ["query": "Kimi docs"]),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "web.search" })!
)
expect(researchSearchDecision == .allow, "用户明确请求 Web Research 时搜索不应重复审批")
let researchFetchDecision = await researchResolver.resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "web-research", toolID: "web.fetch", input: ["url": "https://docs.example.com/page"]),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "web.fetch" })!
)
expect(researchFetchDecision == .allow, "Web Research 对 HTTPS Fetch 应按只读域名复用授权")
let researchPrivateFetchDecision = await researchResolver.resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "web-research", toolID: "web.fetch", input: ["url": "http://127.0.0.1:8080/admin"]),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "web.fetch" })!
)
expect(researchPrivateFetchDecision == .ask, "Web Research 抓取本机/私有地址必须回到审批")
let browserLocalhostOpenDecision = await ChildAgentToolPermissionResolver(definition: browserReadDefinition).resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "browser", toolID: "browser", input: ["action": "open", "url": "http://localhost:8080"]),
  definition: ToolCatalog.defaultDefinitions.first(where: { $0.id == "browser" })!
)
expect(browserLocalhostOpenDecision == .ask, "Browser 打开本机地址必须回到审批")
let computerInspectDefinition = ToolCatalog.defaultDefinitions.first(where: { $0.id == "computer_use.inspect" })!
let computerInspectDecision = await ChildAgentToolPermissionResolver(definition: AgentOrchestrator.builtInDefinition(for: .browser)).resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "browser", toolID: "computer_use.inspect"),
  definition: computerInspectDefinition
)
expect(computerInspectDecision == .allow, "Computer Use inspect 必须允许只读闭环直接执行")
let computerClickDefinition = ToolCatalog.defaultDefinitions.first(where: { $0.id == "computer_use.click" })!
let computerClickDecision = await ChildAgentToolPermissionResolver(definition: AgentOrchestrator.builtInDefinition(for: .browser)).resolve(
  request: ToolExecutionRequest(taskID: approvalTaskID, sessionID: UUID(), agentID: "browser", toolID: "computer_use.click", input: ["x": "1", "y": "1"]),
  definition: computerClickDefinition
)
expect(computerClickDecision == .ask, "Computer Use 点击必须保留审批")

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

var capturedMaximumOutputTokens: Int?
let boundedRequestBody = try KimiHTTPModelProvider.requestBody(
  request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("你好")]),
  tools: [],
  maximumOutputTokens: 321
)
let boundedRequestObject = try JSONSerialization.jsonObject(with: boundedRequestBody) as? [String: Any]
capturedMaximumOutputTokens = boundedRequestObject?["max_tokens"] as? Int
MockURLProtocol.requestHandler = { request in
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
  let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"收到\"}}]}\n\ndata: [DONE]\n\n"
  return (response, Data(stream.utf8))
}
let boundedProvider = KimiHTTPModelProvider(
  baseURL: URL(string: "https://api.moonshot.cn/v1")!,
  apiKey: "sk-test-budget",
  modelID: "kimi-k2.7-code",
  maximumOutputTokens: 321,
  session: mockModelsSession
)
let boundedReply = try awaitValue { () async throws -> String in
  let stream = try await boundedProvider.stream(request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("你好")]), tools: [], signal: nil)
  var reply = ""
  for try await event in stream {
    if case let .text(text) = event { reply += text }
  }
  return reply
}
expect(capturedMaximumOutputTokens == 321 && boundedReply == "收到", "模型 Provider 必须把路由的输出预算写入真实 API 请求")
MockURLProtocol.requestHandler = nil
let structuredToolArguments = KimiHTTPModelProvider.normalizedToolArguments(["url": "https://example.com"])
let structuredToolObject = try JSONSerialization.jsonObject(with: Data(structuredToolArguments.utf8)) as? [String: String]
expect(structuredToolObject?["url"] == "https://example.com", "Provider 必须保留结构化 JSON Tool 参数，不能把对象当成空参数")
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
let fragmentedToolProvider = KimiHTTPModelProvider(
  baseURL: URL(string: "https://api.moonshot.cn/v1")!,
  apiKey: "sk-test-fragmented-tools",
  modelID: "kimi-k2.7-code",
  session: mockModelsSession
)
let fragmentedToolCalls = try awaitValue { () async throws -> [HarnessToolCall] in
  let stream = try await fragmentedToolProvider.stream(
    request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("抓取 Apple 首页")]),
    tools: ToolCatalog.defaultDefinitions,
    signal: nil
  )
  var order: [String] = []
  var names: [String: String] = [:]
  var arguments: [String: String] = [:]
  for try await event in stream {
    guard case let .toolCallDelta(id, name, argumentsDelta) = event else { continue }
    if !order.contains(id) { order.append(id) }
    if let name { names[id] = name }
    arguments[id, default: ""] += argumentsDelta
  }
  return order.compactMap { id in
    guard let name = names[id] else { return nil }
    return HarnessToolCall(id: id, name: name, argumentsJSON: arguments[id] ?? "{}")
  }
}
expect(fragmentedToolCalls.count == 1, "流式 Tool Call 的后续参数分片必须按 index 合并到同一调用")
expect(fragmentedToolCalls.first?.name == "web.fetch", "流式 Tool Call 必须保留映射后的 Runtime 工具名")
expect(fragmentedToolCalls.first?.argumentsJSON == #"{"url":"https://www.apple.com/"}"#, "流式 Tool Call 必须保留完整 url 参数")

MockURLProtocol.requestHandler = { request in
  let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
  let stream = """
  data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"sparse-1","function":{"name":"shell"}}]}}]}

  data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"ls"}}]}}]}

  data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{}}]}}]}

  data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":" -la\\"}"}}]}}]}

  data: [DONE]

  """
  return (response, Data(stream.utf8))
}
let sparseToolProvider = KimiHTTPModelProvider(
  baseURL: URL(string: "https://api.moonshot.cn/v1")!,
  apiKey: "sk-test-sparse-tool-delta",
  modelID: "kimi-k2.7-code",
  session: mockModelsSession
)
let sparseToolCalls = try awaitValue { () async throws -> [HarnessToolCall] in
  let stream = try await sparseToolProvider.stream(
    request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("列出文件")]),
    tools: ToolCatalog.defaultDefinitions,
    signal: nil
  )
  var assembler = HarnessModelStreamAssembler()
  for try await event in stream { assembler.push(event) }
  return assembler.toolCalls
}
expect(sparseToolCalls.first?.argumentsJSON == #"{"command":"ls -la"}"#, "没有 arguments 的流式占位帧不得污染后续 Tool JSON")
MockURLProtocol.requestHandler = nil

let wiredWebSearchName = HarnessToolNameCodec.wireName(for: "web.search")
let wiredGitHubName = HarnessToolNameCodec.wireName(for: "github.pull_request.create")
let wiredMCPName = HarnessToolNameCodec.wireName(for: "mcp.123e4567-e89b-12d3-a456-426614174000.search_docs")
expect(wiredWebSearchName == "web_search", "Kimi API 工具名必须将 web.search 编码为 web_search")
expect(wiredGitHubName == "github_pull_request_create", "Kimi API 工具名必须将点号编码为下划线")
expect(wiredMCPName.hasPrefix("mcp_"), "MCP 工具名必须编码为合法的函数名")

let repeatedObjectArguments = HarnessConversationLoop.appendToolArguments(
  existing: #"{"url":"https://www.apple.com/"}"#,
  delta: #"{"url":"https://www.apple.com/"}"#
)
let repeatedObjectObject = try JSONSerialization.jsonObject(with: Data(repeatedObjectArguments.utf8)) as? [String: String]
expect(repeatedObjectObject?["url"] == "https://www.apple.com/", "重复发送完整 Tool 参数对象时不得拼接成非法 JSON")

var streamAssembler = HarnessModelStreamAssembler()
streamAssembler.push(.reasoning("内部计划"))
streamAssembler.push(.text("先检查"))
streamAssembler.push(.toolCallDelta(id: "stream-tool", name: "web.search", argumentsDelta: #"{"query":"Kimi"#))
streamAssembler.push(.toolCallDelta(id: "stream-tool", name: nil, argumentsDelta: #" docs"}"#))
streamAssembler.push(.usage(HarnessModelUsage(inputTokens: 13, outputTokens: 5, reasoningTokens: 2)))
streamAssembler.push(.finish(.toolCalls))
expect(streamAssembler.text == "先检查", "流式块组装器必须保留可见文本")
expect(streamAssembler.reasoning == "内部计划", "流式块组装器必须保存仅回放的推理文本")
expect(streamAssembler.toolCalls.first?.argumentsJSON == #"{"query":"Kimi docs"}"#, "流式块组装器必须按 call ID 组装参数分片")
expect(streamAssembler.usage?.reasoningTokens == 2 && streamAssembler.finish == .toolCalls, "流式块组装器必须保留 Usage 与 finish reason")

let invalidFetchCall = HarnessConversationLoop.recoverToolCall(
  HarnessToolCall(id: "missing-url", name: "web.fetch", argumentsJSON: "{}"),
  request: HarnessConversationRequest(
    modelID: "kimi-k2.7-code",
    messages: [.user("请抓取 https://www.apple.com/ 并总结")]
  )
)
expect(invalidFetchCall.name == "web.fetch" && invalidFetchCall.argumentsJSON == "{}", "Harness 不能从用户文本猜测缺失的 Web Fetch URL")
let invalidEmptyFetchCall = HarnessConversationLoop.recoverToolCall(
  HarnessToolCall(id: "empty-url", name: "web.fetch", argumentsJSON: #"{"url":""}"#),
  request: HarnessConversationRequest(
    modelID: "kimi-k2.7-code",
    messages: [.user("请抓取 https://www.apple.com/ 并总结")]
  )
)
let invalidEmptyFetchObject = try JSONSerialization.jsonObject(with: Data(invalidEmptyFetchCall.argumentsJSON.utf8)) as? [String: String]
expect(invalidEmptyFetchCall.name == "web.fetch" && invalidEmptyFetchObject?["url"] == "", "Harness 不能从用户文本补全空 Web Fetch URL")
let canonicalAliasFetchCall = HarnessConversationLoop.recoverToolCall(
  HarnessToolCall(id: "alias-fetch", name: "web_fetch", argumentsJSON: "{}"),
  request: HarnessConversationRequest(
    modelID: "kimi-k3",
    messages: [.user("请读取 https://www.apple.com/ 的首页内容")]
  )
)
expect(canonicalAliasFetchCall.name == "web.fetch" && canonicalAliasFetchCall.argumentsJSON == "{}", "旧 Web 工具别名只能规范化名称，不能推断参数")
let invalidLegacyFetchCall = HarnessConversationLoop.recoverToolCall(
  HarnessToolCall(id: "weather-fetch", name: "FetchURL", argumentsJSON: "{}"),
  request: HarnessConversationRequest(
    modelID: "kimi-k3",
    messages: [.user("明天天气怎么样？")]
  )
)
expect(invalidLegacyFetchCall.name == "web.fetch" && invalidLegacyFetchCall.argumentsJSON == "{}", "FetchURL 缺失 URL 时必须交给模型修正，不能变成搜索")
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

var streamParser = KimiStreamEventParser(sessionID: event.sessionID, taskID: persistedTask.id)
let streamEvents = streamParser.parse(line: "{\"role\":\"assistant\",\"content\":\"分析完成\",\"tool_calls\":[{\"id\":\"call-1\",\"function\":{\"name\":\"shell\",\"arguments\":\"{\\\"command\\\":\\\"pwd\\\"}\"}}]}")
expect(streamEvents.map(\.kind) == [.output, .toolRequested], "CLI stream-json 必须映射文本和工具调用事件")
let thinkingEvents = streamParser.parse(line: "{\"role\":\"assistant\",\"content\":\"我先分析一下\",\"contentType\":\"thinking\"}")
expect(
  thinkingEvents.first?.payload["contentType"] == "thinking",
  "thinking 内容必须保留为内部流，但不能被当成正式回复"
)
let toolResultEvents = streamParser.parse(line: "{\"role\":\"tool\",\"tool_call_id\":\"call-1\",\"content\":\"/tmp/project\"}")
expect(toolResultEvents.first?.kind == .toolFinished, "CLI stream-json 必须映射工具结果事件")

let skillsDirectory = nodeProject.appendingPathComponent(".kimi/skills/review", isDirectory: true)
try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
try "---\nname: review\ndescription: 审阅代码变更\n---\n# Review\n".write(
  to: skillsDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
)
let discoveredSkills = SkillRegistry.discover(projectDirectory: nodeProject)
expect(discoveredSkills.first?.name == "review", "Skill 注册表必须发现项目 SKILL.md")
expect(discoveredSkills.first?.description == "审阅代码变更", "Skill 注册表必须读取 front matter 描述")

let runnableSkillDirectory = nodeProject.appendingPathComponent(".kimi/skills/runnable", isDirectory: true)
try FileManager.default.createDirectory(at: runnableSkillDirectory, withIntermediateDirectories: true)
let runnableSkillLogURL = runnableSkillDirectory.appendingPathComponent("skill.log")
try """
#!/bin/sh
echo "skill-ran:$KIMI_AGENT_TASK_ID" >> "\(runnableSkillLogURL.path)"
printf "skill-output"
""".write(to: runnableSkillDirectory.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
try runCheckCommand("chmod", ["+x", runnableSkillDirectory.appendingPathComponent("run.sh").path], in: runnableSkillDirectory)
try "---\nname: runnable\ndescription: 可执行技能\nentry: run.sh\npermissions: shell\n---\n# Runnable skill\n".write(
  to: runnableSkillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
)
let runnableSkill = SkillRegistry.discover(projectDirectory: nodeProject).first { $0.name == "runnable" }
expect(runnableSkill != nil, "Skill 注册表必须发现可执行技能")
expect(runnableSkill?.entryPath == "run.sh", "Skill 注册表必须读取 entry 配置")
expect(runnableSkill?.permissions == ["shell"], "Skill 注册表必须读取权限声明")
let runnableSkillTask = AgentTask(title: "运行技能", mode: .agent, workspacePath: nodeProject.path)
let runnableSkillResult = try SkillRunner.execute(
  skill: runnableSkill!,
  projectDirectory: nodeProject,
  task: runnableSkillTask
)
expect(runnableSkillResult.exitCode == 0, "Skill 执行必须成功")
expect(runnableSkillResult.standardOutput.contains("skill-output"), "Skill 执行必须回传标准输出")
let runnableSkillLog = try String(contentsOf: runnableSkillLogURL, encoding: .utf8)
expect(runnableSkillLog.contains("skill-ran"), "Skill 执行必须产生副作用")

let escapeSkillDirectory = nodeProject.appendingPathComponent(".kimi/skills/escape", isDirectory: true)
try FileManager.default.createDirectory(at: escapeSkillDirectory, withIntermediateDirectories: true)
let escapeSkillOutsideURL = nodeProject.deletingLastPathComponent().appendingPathComponent("kimi-skill-escape-\(UUID().uuidString)")
try """
#!/bin/sh
set -e
touch "\(escapeSkillOutsideURL.path)"
""".write(to: escapeSkillDirectory.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
try runCheckCommand("chmod", ["+x", escapeSkillDirectory.appendingPathComponent("run.sh").path], in: escapeSkillDirectory)
try "---\nname: escape\ndescription: 越界写入技能\nentry: run.sh\npermissions: shell\n---\n".write(
  to: escapeSkillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
)
let escapeSkill = SkillRegistry.discover(projectDirectory: nodeProject).first { $0.name == "escape" }
expect(escapeSkill != nil, "越界 Skill 必须可被发现用于安全回归")
let escapeSkillResult = try SkillRunner.execute(skill: escapeSkill!, projectDirectory: nodeProject, task: runnableSkillTask)
expect(
  escapeSkillResult.exitCode != 0 && !FileManager.default.fileExists(atPath: escapeSkillOutsideURL.path),
  "Skill 执行必须由 OS 沙箱阻止 Worktree 外写入"
)

let extensionWorkspace = temporaryDirectory.appendingPathComponent("extension-workspace", isDirectory: true)
let extensionDotDir = extensionWorkspace.appendingPathComponent(".kimi-agent", isDirectory: true)
try FileManager.default.createDirectory(at: extensionDotDir, withIntermediateDirectories: true)
let hookLogURL = extensionWorkspace.appendingPathComponent("hook.log")
let hookCommand = "/bin/sh -lc 'printf started >> \"\(hookLogURL.path)\"'"
let blockedHookCommand = "/bin/sh -lc 'printf blocked >> \"\(hookLogURL.path)\"'"
let mcpServerScriptURL = extensionWorkspace.appendingPathComponent("fake-mcp.mjs")
try """
import readline from 'node:readline';
const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
function respond(message) {
  process.stdout.write(JSON.stringify(message) + '\\n');
}
rl.on('line', line => {
  if (!line.trim()) return;
  const request = JSON.parse(line);
  if (request.method === 'initialize') {
    respond({ jsonrpc: '2.0', id: request.id, result: { protocolVersion: '2024-11-05', serverInfo: { name: 'fake-mcp', version: '1.0.0' }, capabilities: { tools: {}, resources: {}, prompts: {}, elicitation: {} } } });
  } else if (request.method === 'tools/list') {
    respond({ jsonrpc: '2.0', id: request.id, result: { tools: [{ name: 'echo', description: 'echo text', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } }] } });
  } else if (request.method === 'resources/list') {
    respond({ jsonrpc: '2.0', id: request.id, result: { resources: [{ uri: 'file:///workspace/README.md', name: 'README', description: 'Project README', mimeType: 'text/markdown' }] } });
  } else if (request.method === 'prompts/list') {
    respond({ jsonrpc: '2.0', id: request.id, result: { prompts: [{ name: 'explain', description: 'Explain project', arguments: [{ name: 'path', required: true }] }] } });
  } else if (request.method === 'resources/read') {
    respond({ jsonrpc: '2.0', id: request.id, result: { contents: [{ uri: request.params.uri, mimeType: 'text/markdown', text: '# README' }] } });
  } else if (request.method === 'prompts/get') {
    respond({ jsonrpc: '2.0', id: request.id, result: { description: 'Explain project', messages: [{ role: 'user', content: { type: 'text', text: `Explain:${request.params.arguments.path}` } }] } });
  } else if (request.method === 'tools/call') {
    respond({ jsonrpc: '2.0', id: request.id, result: { content: [{ type: 'text', text: `echo:${request.params.arguments.text}` }] } });
  }
});
""".write(to: mcpServerScriptURL, atomically: true, encoding: .utf8)
let extensionConfig = ProjectAgentConfiguration(
  modelID: "kimi-test",
  maxConcurrentWorkers: 4,
  skillsDirectories: [runnableSkillDirectory.deletingLastPathComponent().path],
  hooks: [
    HookDefinition(event: .taskStarted, command: hookCommand, timeoutSeconds: 5, behavior: .allow),
    HookDefinition(event: .taskStarted, command: blockedHookCommand, timeoutSeconds: 5, behavior: .block)
  ],
  mcpServers: [
    MCPServerConfiguration(
      name: "sleep-server",
      transport: .stdio,
      command: "/usr/bin/env",
      endpoint: nil,
      arguments: ["node", mcpServerScriptURL.path],
      isEnabled: true
    )
  ],
  allowedDomains: ["localhost"]
)
try extensionConfig.write(projectDirectory: extensionWorkspace)
let loadedExtensionConfig = try ProjectAgentConfiguration.load(projectDirectory: extensionWorkspace)
expect(loadedExtensionConfig.modelID == "kimi-test", "扩展配置必须能加载模型设置")
expect(loadedExtensionConfig.hooks.count == 2, "扩展配置必须加载 hooks")
expect(loadedExtensionConfig.mcpServers.count == 1, "扩展配置必须加载 MCP 配置")

let extensionRuntime = ProjectExtensionRuntime(projectDirectory: extensionWorkspace)
let hookTask = AgentTask(title: "扩展运行任务", mode: .agent, workspacePath: extensionWorkspace.path)
let runtimeSkills = try extensionRuntime.discoverSkills()
expect(runtimeSkills.contains { $0.name == "runnable" }, "扩展运行时必须能发现配置的技能目录")
let runtimeSkillResult = try extensionRuntime.executeSkill(named: "runnable", task: hookTask)
expect(runtimeSkillResult.standardOutput.contains("skill-output"), "扩展运行时必须能执行已发现的技能")
let hookResults = try extensionRuntime.runHooks(event: .taskStarted, task: hookTask)
expect(hookResults.count == 2, "任务启动必须触发全部匹配 hooks")
expect(hookResults.first?.decision == .allow, "允许 hook 应该执行")
expect(hookResults.last?.decision == .block, "阻断 hook 应该被标记为阻断")
let hookLog = try String(contentsOf: hookLogURL, encoding: .utf8)
expect(hookLog.contains("started"), "允许 hook 必须产生副作用")
expect(!hookLog.contains("blocked"), "被阻断的 hook 不应执行命令")

let escapeHookOutsideURL = extensionWorkspace.deletingLastPathComponent().appendingPathComponent("kimi-hook-escape-\(UUID().uuidString)")
var escapeHookConfiguration = extensionConfig
escapeHookConfiguration.hooks = [
  HookDefinition(event: .taskStarted, command: "touch '\(escapeHookOutsideURL.path)'", timeoutSeconds: 5, behavior: .allow)
]
try escapeHookConfiguration.write(projectDirectory: extensionWorkspace)
let escapeHookRuntime = ProjectExtensionRuntime(projectDirectory: extensionWorkspace)
let escapeHookResults = try escapeHookRuntime.runHooks(event: .taskStarted, task: hookTask)
expect(
  escapeHookResults.first?.exitCode != 0 && !FileManager.default.fileExists(atPath: escapeHookOutsideURL.path),
  "Hook 执行必须由 OS 沙箱阻止 Worktree 外写入"
)

let mcpStatuses = try extensionRuntime.refreshMCPStatuses()
expect(mcpStatuses.count == 1, "MCP 状态运行时必须返回服务器状态")
expect(mcpStatuses.first?.state == .running, "stdio MCP 服务器启动后应报告 running")
let runtimeMCPServerID = loadedExtensionConfig.mcpServers[0].id
let runtimeMCPTools = try extensionRuntime.listMCPTools(serverID: runtimeMCPServerID)
expect(runtimeMCPTools.first?.name == "echo", "扩展运行时必须能通过 MCP 读取工具列表")
let runtimeMCPResources = try extensionRuntime.listMCPResources(serverID: runtimeMCPServerID)
expect(runtimeMCPResources.first?.name == "README", "扩展运行时必须暴露 MCP Resources")
let runtimeMCPPrompts = try extensionRuntime.listMCPPrompts(serverID: runtimeMCPServerID)
expect(runtimeMCPPrompts.first?.name == "explain", "扩展运行时必须暴露 MCP Prompts")
let runtimeMCPCall = try extensionRuntime.callMCPTool(serverID: runtimeMCPServerID, name: "echo", arguments: ["text": "Runtime"])
expect(runtimeMCPCall.standardOutput.contains("echo:Runtime"), "扩展运行时必须能通过 MCP 调用工具")
let mcpEscapeScriptURL = extensionWorkspace.appendingPathComponent("escape-mcp.mjs")
let mcpEscapeOutsideURL = extensionWorkspace.deletingLastPathComponent().appendingPathComponent("kimi-mcp-escape-\(UUID().uuidString)")
try """
import fs from 'node:fs';
try {
  fs.writeFileSync(\(String(data: try JSONSerialization.data(withJSONObject: [mcpEscapeOutsideURL.path]), encoding: .utf8)!)[0], 'escape');
  process.exit(0);
} catch (_) {
  process.exit(7);
}
""".write(to: mcpEscapeScriptURL, atomically: true, encoding: .utf8)
let mcpEscapeClient = try MCPStdioClient(
  command: "/usr/bin/env",
  arguments: ["node", mcpEscapeScriptURL.path],
  workingDirectory: extensionWorkspace,
  sandbox: TerminalSandboxConfiguration.strict(
    workspaceURL: extensionWorkspace,
    scratchURL: temporaryDirectory.appendingPathComponent("mcp-escape-scratch", isDirectory: true)
  )
)
let mcpEscapeInitialization: Result<MCPInitializeResult, Error> = Result {
  try mcpEscapeClient.initialize()
}
mcpEscapeClient.close()
if case .success = mcpEscapeInitialization {
  expect(false, "恶意 MCP Worker 不得在沙箱中成功初始化")
}
expect(!FileManager.default.fileExists(atPath: mcpEscapeOutsideURL.path), "MCP stdio Worker 必须由 OS 沙箱阻止 Worktree 外写入")
let harnessMCPExecutor = MCPHarnessToolExecutor(runtime: extensionRuntime)
let harnessMCPDefinitions = try harnessMCPExecutor.discoverDefinitions()
let harnessMCPDefinition = harnessMCPDefinitions.first { definition in
  MCPHarnessToolIdentifier.parse(definition.id)?.serverID == runtimeMCPServerID
}
expect(harnessMCPDefinition != nil, "Harness 必须将已连接 MCP 工具注册为独立 ToolDefinition")
if let harnessMCPDefinition {
  let harnessMCPResult = try awaitValue {
    try await harnessMCPExecutor.execute(ToolExecutionRequest(
      taskID: kernelTaskID,
      sessionID: kernelSessionID,
      operationID: kernelTaskID,
      agentID: "main",
      toolID: harnessMCPDefinition.id,
      input: ["text": "Harness"]
    ))
  }
  expect(harnessMCPResult.output.contains("echo:Harness"), "Harness MCP Adapter 必须通过 MCP Worker 返回真实 Tool Result")
}
let harnessMCPResourceID = "mcp.\(runtimeMCPServerID.uuidString.lowercased()).resources.read"
let harnessMCPPromptID = "mcp.\(runtimeMCPServerID.uuidString.lowercased()).prompts.get"
expect(
  harnessMCPDefinitions.contains(where: { $0.id == harnessMCPResourceID }),
  "Harness 必须将 MCP Resources 注册为可审计的读取工具"
)
expect(
  harnessMCPDefinitions.contains(where: { $0.id == harnessMCPPromptID }),
  "Harness 必须将 MCP Prompts 注册为可审计的提示工具"
)
let harnessMCPResourceResult = try awaitValue {
  try await harnessMCPExecutor.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: kernelTaskID,
    agentID: "main",
    toolID: harnessMCPResourceID,
    input: ["uri": "file:///workspace/README.md"]
  ))
}
expect(harnessMCPResourceResult.output.contains("# README"), "Harness MCP Resource 工具必须返回真实正文")
let harnessMCPPromptResult = try awaitValue {
  try await harnessMCPExecutor.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: kernelTaskID,
    agentID: "main",
    toolID: harnessMCPPromptID,
    input: ["name": "explain", "path": "README.md"]
  ))
}
expect(harnessMCPPromptResult.output.contains("Explain:README.md"), "Harness MCP Prompt 工具必须返回真实 Prompt 消息")

let toolsOnlyMCPWorkspace = temporaryDirectory.appendingPathComponent("mcp-tools-only-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: toolsOnlyMCPWorkspace, withIntermediateDirectories: true)
let toolsOnlyMCPServerScriptURL = toolsOnlyMCPWorkspace.appendingPathComponent("tools-only.mjs")
try #"""
import readline from 'node:readline';
const rl = readline.createInterface({ input: process.stdin });
const respond = (message) => process.stdout.write(JSON.stringify(message) + '\n');
rl.on('line', line => {
  if (!line.trim()) return;
  const request = JSON.parse(line);
  if (request.method === 'initialize') {
    respond({ jsonrpc: '2.0', id: request.id, result: { protocolVersion: '2024-11-05', serverInfo: { name: 'tools-only', version: '1.0.0' }, capabilities: { tools: {} } } });
  } else if (request.method === 'tools/list') {
    respond({ jsonrpc: '2.0', id: request.id, result: { tools: [{ name: 'echo', description: 'echo', inputSchema: { type: 'object' } }] } });
  } else if (request.id !== undefined) {
    respond({ jsonrpc: '2.0', id: request.id, error: { code: -32601, message: 'Method not found' } });
  }
});
"""#.write(to: toolsOnlyMCPServerScriptURL, atomically: true, encoding: .utf8)
let toolsOnlyConfiguration = ProjectAgentConfiguration(
  mcpServers: [
    MCPServerConfiguration(
      name: "tools-only",
      transport: .stdio,
      command: "/usr/bin/env",
      endpoint: nil,
      arguments: ["node", toolsOnlyMCPServerScriptURL.path],
      isEnabled: true
    )
  ]
)
try toolsOnlyConfiguration.write(projectDirectory: toolsOnlyMCPWorkspace)
let toolsOnlyRuntime = ProjectExtensionRuntime(projectDirectory: toolsOnlyMCPWorkspace)
let toolsOnlyServerID = toolsOnlyConfiguration.mcpServers[0].id
let toolsOnlyResources = try toolsOnlyRuntime.listMCPResources(serverID: toolsOnlyServerID)
expect(
  toolsOnlyResources.isEmpty,
  "未声明 Resources 能力的 MCP Server 必须在 Harness 中安全跳过 Resources"
)
let toolsOnlyPrompts = try toolsOnlyRuntime.listMCPPrompts(serverID: toolsOnlyServerID)
expect(
  toolsOnlyPrompts.isEmpty,
  "未声明 Prompts 能力的 MCP Server 必须在 Harness 中安全跳过 Prompts"
)
let toolsOnlyDefinitions = try MCPHarnessToolExecutor(runtime: toolsOnlyRuntime).discoverDefinitions()
expect(
  toolsOnlyDefinitions.contains(where: { $0.id.hasSuffix(".echo") }) &&
    !toolsOnlyDefinitions.contains(where: { $0.id == MCPHarnessToolIdentifier.resourceReader(serverID: toolsOnlyServerID) }) &&
    !toolsOnlyDefinitions.contains(where: { $0.id == MCPHarnessToolIdentifier.promptGetter(serverID: toolsOnlyServerID) }),
  "可选 MCP 能力缺失不得阻断普通 MCP Tool 发现"
)

let extensionManagement = ExtensionManagementPresentation(
  configuration: loadedExtensionConfig,
  discoveredSkills: runtimeSkills,
  hookResults: hookResults,
  mcpStatuses: mcpStatuses,
  plugins: []
)
expect(extensionManagement.sections.count == 4, "扩展管理面板必须分成 Plugins / Skills / Hooks / MCP 四块")
expect(extensionManagement.sections.first?.title == "Plugins", "扩展管理面板必须先展示 Plugins")
expect(extensionManagement.sections[1].title == "Skills", "扩展管理面板必须在 Plugins 后展示 Skills")
expect(extensionManagement.sections[1].rows.contains(where: { $0.title == "runnable" }) == true, "Skills 面板必须列出可执行技能")
expect(extensionManagement.sections[1].rows.first?.details.isEmpty == false, "Skills 面板必须包含可展开详情")
expect(extensionManagement.sections[2].rows.count == 2, "Hooks 面板必须列出所有 hooks")
expect(extensionManagement.sections[2].rows.first?.details.count ?? 0 >= 4, "Hooks 面板必须包含 hook 详情")
expect(extensionManagement.sections[3].rows.first?.statusText.contains("running") == true, "MCP 面板必须展示运行状态")
expect(extensionManagement.sections[3].rows.first?.details.count ?? 0 >= 3, "MCP 面板必须包含 server 详情")

let mcpClient = try MCPStdioClient(
  command: "/usr/bin/env",
  arguments: ["node", mcpServerScriptURL.path],
  workingDirectory: extensionWorkspace
)
let mcpInitializeResult = try mcpClient.initialize()
expect(mcpInitializeResult.serverInfo.name == "fake-mcp", "MCP 客户端必须完成初始化握手")
expect(mcpInitializeResult.capabilities.resources && mcpInitializeResult.capabilities.prompts, "MCP 握手必须保留 Resources 和 Prompts 能力声明")
let mcpTools = try mcpClient.listTools()
expect(mcpTools.count == 1 && mcpTools.first?.name == "echo", "MCP 客户端必须读取工具列表")
let mcpResources = try mcpClient.listResources()
expect(mcpResources.first?.uri == "file:///workspace/README.md", "MCP 客户端必须读取 Resources")
let mcpPrompts = try mcpClient.listPrompts()
expect(mcpPrompts.first?.name == "explain" && mcpPrompts.first?.arguments.first?.required == true, "MCP 客户端必须读取 Prompts 参数声明")
let mcpResourceContents = try mcpClient.readResource(uri: "file:///workspace/README.md")
expect(mcpResourceContents.first?.text == "# README", "MCP 客户端必须读取 Resource 正文")
let mcpPromptResult = try mcpClient.getPrompt(name: "explain", arguments: ["path": "README.md"])
expect(mcpPromptResult.messages.first?.text == "Explain:README.md", "MCP 客户端必须获取 Prompt 消息")
let mcpCall = try mcpClient.callTool(name: "echo", arguments: ["text": "Kimi"])
expect(mcpCall.standardOutput.contains("echo:Kimi"), "MCP 客户端必须调用工具并回传结果")
mcpClient.close()

MockMCPHTTPURLProtocol.responses = [
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 1,
    "result": [
      "protocolVersion": "2024-11-05",
      "serverInfo": ["name": "http-mcp", "version": "1.0.0"],
      "capabilities": ["tools": [:]]
    ]
  ]),
  Data(),
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 3,
    "result": [
      "tools": [
        [
          "name": "echo",
          "description": "echo text",
          "inputSchema": ["type": "object"]
        ]
      ]
    ]
  ]),
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 4,
    "result": [
      "resources": [
        ["uri": "https://mcp.example/docs", "name": "Docs", "description": "HTTP docs", "mimeType": "text/html"]
      ]
    ]
  ]),
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 5,
    "result": [
      "prompts": [
        ["name": "summarize", "description": "Summarize docs", "arguments": [["name": "uri", "required": true]]]
      ]
    ]
  ]),
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 6,
    "result": [
      "contents": [
        ["uri": "https://mcp.example/docs", "mimeType": "text/html", "text": "<h1>Docs</h1>"]
      ]
    ]
  ]),
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 7,
    "result": [
      "description": "Summarize docs",
      "messages": [
        ["role": "user", "content": ["type": "text", "text": "Summarize:https://mcp.example/docs"]]
      ]
    ]
  ]),
  try JSONSerialization.data(withJSONObject: [
    "jsonrpc": "2.0",
    "id": 8,
    "result": [
      "content": [
        ["type": "text", "text": "echo:HTTP"]
      ]
    ]
  ])
]
let httpMCPConfiguration = URLSessionConfiguration.ephemeral
httpMCPConfiguration.protocolClasses = [MockMCPHTTPURLProtocol.self]
let httpMCPClient = try MCPHttpClient(
  endpoint: URL(string: "https://mcp.example/jsonrpc")!,
  allowedDomains: ["mcp.example"],
  session: URLSession(configuration: httpMCPConfiguration)
)
let httpMCPInitializeResult = try httpMCPClient.initialize()
expect(httpMCPInitializeResult.serverInfo.name == "http-mcp", "HTTP MCP 客户端必须完成 initialize 握手")
let httpMCPTools = try httpMCPClient.listTools()
expect(httpMCPTools.first?.name == "echo", "HTTP MCP 客户端必须读取工具列表")
let httpMCPResources = try httpMCPClient.listResources()
expect(httpMCPResources.first?.mimeType == "text/html", "HTTP MCP 客户端必须读取 Resources")
let httpMCPPrompts = try httpMCPClient.listPrompts()
expect(httpMCPPrompts.first?.arguments.first?.name == "uri", "HTTP MCP 客户端必须读取 Prompts 参数")
let httpMCPResourceContents = try httpMCPClient.readResource(uri: "https://mcp.example/docs")
expect(httpMCPResourceContents.first?.text == "<h1>Docs</h1>", "HTTP MCP 客户端必须读取 Resource 正文")
let httpMCPPromptResult = try httpMCPClient.getPrompt(name: "summarize", arguments: ["uri": "https://mcp.example/docs"])
expect(httpMCPPromptResult.messages.first?.text == "Summarize:https://mcp.example/docs", "HTTP MCP 客户端必须获取 Prompt 消息")
let httpMCPCall = try httpMCPClient.callTool(name: "echo", arguments: ["text": "HTTP"])
expect(httpMCPCall.standardOutput.contains("echo:HTTP"), "HTTP MCP 客户端必须调用工具并回传结果")
httpMCPClient.close()

extensionRuntime.stop()

expect(ComputerUsePolicy.decision(for: .click) == .allow, "普通 Computer Use 点击可在会话授权后执行")
expect(ComputerUsePolicy.decision(for: .externalSend) == .ask, "外发数据必须逐次请求用户确认")
expect(ComputerUsePolicy.decision(for: .systemSettings) == .ask, "修改系统设置必须逐次请求用户确认")

let hostEnvelopeData = Data("""
{"type":"event","event":{"id":"00000000-0000-0000-0000-000000000003","sessionID":"00000000-0000-0000-0000-000000000001","taskID":"00000000-0000-0000-0000-000000000002","workItemID":null,"sequence":1,"timestamp":0,"actor":"kimi-agent-host","kind":"permissionRequested","payload":{"id":"approval-1","action":"Bash"},"requiresApproval":true}}
""".utf8)
let hostEnvelope = try AgentHostBridgeProtocol.decodeEnvelope(hostEnvelopeData)
expect(hostEnvelope.event?.kind == .permissionRequested, "Native Agent Host 必须解码结构化审批事件")
expect(hostEnvelope.event?.requiresApproval == true, "Native Agent Host 审批事件必须保留审批标记")

let acpReadyEnvelope = try AgentHostBridgeProtocol.decodeEnvelope(Data("""
{"type":"ready","sessionID":"00000000-0000-0000-0000-000000000001","runtimeSessionID":"session_acp_123"}
""".utf8))
expect(acpReadyEnvelope.runtimeSessionID == "session_acp_123", "ACP ready 信封必须携带可恢复的运行时会话 ID")

let hostScriptURL = temporaryDirectory.appendingPathComponent("host-check.mjs")
try """
process.stdin.setEncoding('utf8');
process.stdin.once('data', input => {
  const request = JSON.parse(input.trim());
  process.stdout.write(JSON.stringify({ type: 'event', event: { id: '00000000-0000-0000-0000-000000000004', sessionID: request.sessionID, taskID: request.taskID, workItemID: null, sequence: 1, timestamp: 0, actor: 'host-check', kind: 'output', payload: { text: 'host-ready' }, requiresApproval: false } }) + '\\n');
  process.exit(0);
});
""".write(to: hostScriptURL, atomically: true, encoding: .utf8)
let nodeExecutable = try runCheckCommand("which", ["node"], in: temporaryDirectory).trimmingCharacters(in: .whitespacesAndNewlines)
let hostCollector = AgentHostCollector()
let hostHandle = try KimiAgentHostRunner.start(
  configuration: KimiAgentHostConfiguration(
    nodePath: nodeExecutable,
    hostScriptURL: hostScriptURL,
    runtimePath: "/tmp/kimi.mjs",
    workspacePath: temporaryDirectory.path,
    sessionID: "00000000-0000-0000-0000-000000000001",
    taskID: "00000000-0000-0000-0000-000000000002",
    prompt: "host check",
    modelID: nil,
    skillsDirectories: []
  ),
  onEnvelope: hostCollector.append
)
let hostResult = hostHandle.wait()
expect(hostResult.exitCode == 0, "Native Agent Host 桥接进程必须正常退出")
expect(hostCollector.receivedOutput, "Native Agent Host 必须向 Swift 推送结构化事件")

let failingHostScriptURL = temporaryDirectory.appendingPathComponent("host-failure-check.mjs")
try """
process.stdin.setEncoding('utf8');
process.stdin.once('data', () => {
  process.stdout.write(JSON.stringify({ type: 'error', message: "CLI exited with code 1: error: unknown option '--work-dir'" }) + '\\n');
  process.exit(0);
});
""".write(to: failingHostScriptURL, atomically: true, encoding: .utf8)
let failingHostHandle = try KimiAgentHostRunner.start(
  configuration: KimiAgentHostConfiguration(
    nodePath: nodeExecutable,
    hostScriptURL: failingHostScriptURL,
    runtimePath: "/tmp/kimi.mjs",
    workspacePath: temporaryDirectory.path,
    sessionID: "00000000-0000-0000-0000-000000000001",
    taskID: "00000000-0000-0000-0000-000000000002",
    prompt: "host failure check",
    modelID: nil,
    skillsDirectories: []
  ),
  onEnvelope: { _ in }
)
let failingHostResult = failingHostHandle.wait()
expect(failingHostResult.exitCode != 0, "Agent Host 报错后不能把任务伪装为成功")
expect(failingHostResult.standardError.contains("unknown option '--work-dir'"), "Agent Host 错误必须传递给 CLI 回退逻辑")

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
let pendingReplyTurn = ConversationTurn(sequence: 1, userMessage: "帮我检查一下")
let pendingReplyTask = AgentTask(
  title: "等待回复",
  mode: .plan,
  workspacePath: "/tmp/demo",
  structuredEvents: [
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: pendingReplyTurn.id,
      sequence: 1,
      actor: "desktop",
      kind: .toolProgress,
      payload: ["text": "正在准备回复…"]
    )
  ],
  turns: [pendingReplyTurn],
  activeTurnID: pendingReplyTurn.id
)
let pendingReplyEntries = AgentConversationPresentation.entries(for: pendingReplyTask)
expect(
  pendingReplyEntries.contains(where: { $0.role == AgentConversationRole.status && $0.text.contains("正在准备回复") }),
  "首轮回复前必须显示准备中的状态，而不是空白页"
)
let mixedLanguageTurn = ConversationTurn(sequence: 1, userMessage: "你好")
let mixedLanguageTask = AgentTask(
  title: "自然回复",
  mode: .plan,
  workspacePath: "/tmp/demo",
  structuredEvents: [
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: mixedLanguageTurn.id,
      sequence: 1,
      actor: "kimi-runtime",
      kind: .output,
      payload: [
        "text": "The user is asking me to respond in one sentence in Chinese. 收到，请问有什么可以帮你的？",
        "contentType": "text"
      ]
    )
  ],
  turns: [mixedLanguageTurn],
  activeTurnID: mixedLanguageTurn.id
)
let mixedLanguageEntries = AgentConversationPresentation.entries(for: mixedLanguageTask)
expect(
  mixedLanguageEntries.contains(where: { $0.role == AgentConversationRole.assistant && $0.text == "收到，请问有什么可以帮你的？" }),
  "对话里不应展示英文前缀推理，只应保留自然中文回复"
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
let leakedReasoningTurn = ConversationTurn(sequence: 1, userMessage: "你好")
let leakedReasoningTask = AgentTask(
  title: "你好",
  mode: .plan,
  workspacePath: "/tmp/demo",
  structuredEvents: [
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: leakedReasoningTurn.id,
      sequence: 1,
      actor: "kimi-runtime",
      kind: .output,
      payload: ["text": leakedReasoningReply, "contentType": "text"]
    )
  ],
  turns: [leakedReasoningTurn],
  activeTurnID: leakedReasoningTurn.id
)
let leakedReasoningEntries = AgentConversationPresentation.entries(for: leakedReasoningTask)
expect(
  leakedReasoningEntries.contains(where: { $0.role == .assistant && $0.text == "你好，收到。" }),
  "会话主视图必须只显示最终助手回复，不能把英文内部分析放进聊天气泡"
)
expect(
  !leakedReasoningEntries.contains(where: { $0.text.contains("Maybe the correct interpretation") || $0.text.contains("The instruction says") }),
  "会话主视图不能展示内部解释和规则复述"
)
let streamedLeakTurn = ConversationTurn(sequence: 1, userMessage: "请联网搜索并只回复结果")
let streamedLeakTask = AgentTask(
  title: "请联网搜索并只回复结果",
  mode: .plan,
  workspacePath: "/tmp/demo",
  structuredEvents: [
    AgentEvent(sessionID: UUID(), taskID: UUID(), turnID: streamedLeakTurn.id, sequence: 1, actor: "desktop", kind: .toolProgress, payload: ["text": "Web Search 已启用"]),
    AgentEvent(sessionID: UUID(), taskID: UUID(), turnID: streamedLeakTurn.id, sequence: 2, actor: "kimi-runtime", kind: .output, payload: ["text": "The user wants a concise answer. I should reply exactly as requested.", "contentType": "text"]),
    AgentEvent(sessionID: UUID(), taskID: UUID(), turnID: streamedLeakTurn.id, sequence: 3, actor: "kimi-runtime", kind: .output, payload: ["text": "真实API连接成功。", "contentType": "text"])
  ],
  turns: [streamedLeakTurn],
  activeTurnID: streamedLeakTurn.id
)
let streamedLeakEntries = AgentConversationPresentation.entries(for: streamedLeakTask)
expect(
  streamedLeakEntries.filter { $0.role == .assistant }.map(\.text) == ["真实API连接成功。"],
  "包含工具活动时，流式内部分析也必须折叠，主对话只能保留最终答案"
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
let chineseReasoningTurn = ConversationTurn(sequence: 1, userMessage: "你在这个桌面版里都能做什么")
let chineseReasoningTask = AgentTask(
  title: "你在这个桌面版里都能做什么",
  mode: .plan,
  workspacePath: "/tmp/demo",
  structuredEvents: [
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: chineseReasoningTurn.id,
      sequence: 0,
      actor: "desktop",
      kind: .toolProgress,
      payload: ["text": "正在准备回复…"]
    ),
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: chineseReasoningTurn.id,
      sequence: 1,
      actor: "kimi-runtime",
      kind: .output,
      payload: ["text": chineseReasoningReply, "contentType": "text"]
    )
  ],
  turns: [chineseReasoningTurn],
  activeTurnID: chineseReasoningTurn.id
)
let chineseReasoningEntries = AgentConversationPresentation.entries(for: chineseReasoningTask)
expect(
  chineseReasoningEntries.contains(where: { $0.role == .assistant && $0.text == expectedChineseAnswer }),
  "会话主视图必须只显示答案清单"
)
expect(
  !chineseReasoningEntries.contains(where: { $0.text.contains("用户的问题是") || $0.text.contains("我需要") }),
  "会话主视图不能展示中文自我分析"
)
let chunkedReplyTurn = ConversationTurn(sequence: 2, userMessage: "你能操作我的电脑吗")
let chunkedReplyTask = AgentTask(
  title: "分段回复",
  mode: .plan,
  workspacePath: "/tmp/demo",
  structuredEvents: [
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: chunkedReplyTurn.id,
      sequence: 1,
      actor: "kimi-runtime",
      kind: .output,
      payload: [
        "text": "The user is asking if I can operate their computer. I should answer honestly and concisely.",
        "contentType": "text"
      ]
    ),
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: chunkedReplyTurn.id,
      sequence: 2,
      actor: "kimi-runtime",
      kind: .output,
      payload: [
        "text": "I have desktop operation tools like inspect, click, type, and press_key.",
        "contentType": "text"
      ]
    ),
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: chunkedReplyTurn.id,
      sequence: 3,
      actor: "kimi-runtime",
      kind: .output,
      payload: [
        "text": "能，但会受权限和当前边界约束。",
        "contentType": "text"
      ]
    )
  ],
  turns: [chunkedReplyTurn],
  activeTurnID: chunkedReplyTurn.id
)
let chunkedReplyEntries = AgentConversationPresentation.entries(for: chunkedReplyTask)
expect(
  chunkedReplyEntries.contains(where: { $0.role == .assistant && $0.text == "能，但会受权限和当前边界约束。" }),
  "分段输出的对话必须只展示最终自然回复"
)
expect(
  !chunkedReplyEntries.contains(where: { $0.role == .assistant && $0.text.contains("The user is asking") }),
  "分段输出的对话不应展示英文分析段落"
)
let webFetchTurn = ConversationTurn(sequence: 1, userMessage: "请抓取网页")
let webFetchTaskID = UUID()
let webFetchSessionID = UUID()
let webFetchChunks = [
  "网页标题：", "Apple", "\n\n", "首页第一句", "可见文本：", "Meet", " the", " latest", " iPhone", " lineup", ".", "\n\n", "来源：[Apple](https://www.apple.com/)"
]
let webFetchTextEvents = webFetchChunks.enumerated().map { index, chunk in
  AgentEvent(
    sessionID: webFetchSessionID,
    taskID: webFetchTaskID,
    turnID: webFetchTurn.id,
    sequence: Int64(index + 2),
    actor: "kimi-acp-host",
    kind: .output,
    payload: ["contentType": "text", "text": chunk]
  )
}
let webFetchEvents = [
  AgentEvent(
    sessionID: webFetchSessionID,
    taskID: webFetchTaskID,
    turnID: webFetchTurn.id,
    sequence: 1,
    actor: "kimi-acp-host",
    kind: .output,
    payload: ["contentType": "thinking", "text": "The model is preparing the fetch response."]
  )
] + webFetchTextEvents
let webFetchTask = AgentTask(
  id: webFetchTaskID,
  title: webFetchTurn.userMessage,
  mode: .plan,
  workspacePath: temporaryDirectory.path,
  sessionID: webFetchSessionID.uuidString,
  structuredEvents: webFetchEvents,
  turns: [webFetchTurn],
  activeTurnID: webFetchTurn.id
)
let webFetchEntries = AgentConversationPresentation.entries(for: webFetchTask)
expect(
  webFetchEntries.contains(where: { $0.role == .assistant && $0.text.contains("网页标题：Apple") && $0.text.contains("首页第一句可见文本") && $0.text.contains("https://www.apple.com/") }),
  "FetchURL 的流式中文回答必须保留完整标题和正文摘要，不能被清洗成‘文本’"
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

let allocatorImplement = AgentRun(parentSessionID: schedulerSession, taskID: schedulerTask, definition: AgentOrchestrator.builtInDefinition(for: .implement))
let allocatorTest = AgentRun(
  parentSessionID: schedulerSession,
  taskID: schedulerTask,
  definition: AgentOrchestrator.builtInDefinition(for: .test),
  dependencies: [allocatorImplement.id]
)
let allocatorDebug = AgentRun(
  parentSessionID: schedulerSession,
  taskID: schedulerTask,
  definition: AgentOrchestrator.builtInDefinition(for: .debug),
  dependencies: [allocatorTest.id]
)
let allocatorParallelImplement = AgentRun(
  parentSessionID: schedulerSession,
  taskID: schedulerTask,
  definition: AgentOrchestrator.builtInDefinition(for: .implement)
)
let allocatorRuns = [allocatorImplement, allocatorTest, allocatorDebug, allocatorParallelImplement]
let allocatedRuns = AgentWorktreeAllocator.assign(
  runs: allocatorRuns,
  rootDirectory: temporaryDirectory.appendingPathComponent("graph-worktrees", isDirectory: true)
)
let implementationPath = allocatedRuns.first(where: { $0.id == allocatorImplement.id })?.worktreePath
let parallelImplementationPath = allocatedRuns.first(where: { $0.id == allocatorParallelImplement.id })?.worktreePath
expect(implementationPath != nil && implementationPath != parallelImplementationPath, "并行独立实现 Worker 必须分配不同 Worktree")
expect(allocatedRuns.first(where: { $0.id == allocatorTest.id })?.worktreePath == implementationPath, "Test 必须在 Implement 的 Worktree 上验证真实改动")
expect(allocatedRuns.first(where: { $0.id == allocatorDebug.id })?.worktreePath == implementationPath, "Debug 必须回到失败实现的 Worktree 修复")
expect(allocatedRuns.first(where: { $0.definition.kind == .explore })?.worktreePath == nil, "只读 Worker 不应占用写入 Worktree")

let supervisedTaskID = UUID()
let supervisedParent = SessionRecord(taskID: supervisedTaskID, agentID: "supervisor", modelID: "kimi-k2.7-code")
let supervisedExplore = AgentRun(
  parentSessionID: supervisedParent.id,
  taskID: supervisedTaskID,
  definition: AgentOrchestrator.builtInDefinition(for: .explore)
)
let supervisedPlan = AgentRun(
  parentSessionID: supervisedParent.id,
  taskID: supervisedTaskID,
  definition: AgentOrchestrator.builtInDefinition(for: .plan),
  dependencies: [supervisedExplore.id]
)
let supervisorRunTrace = ThreadSafeStringTrace()
let supervisorSnapshots = InvocationCounter()
let graphSupervisor = AgentGraphSupervisor(
  parent: supervisedParent,
  runs: [supervisedExplore, supervisedPlan],
  maxConcurrent: 2,
  prompt: { run in "执行 \(run.definition.kind.title) 阶段" },
  onEvent: { event in
    if case .schedulerSnapshot = event { supervisorSnapshots.increment() }
  },
  executor: { run, session, prompt, tools in
    supervisorRunTrace.append("\(run.definition.kind.rawValue):\(session.parentID == supervisedParent.id):\(prompt):\(tools.isEmpty)")
    return AgentResult(summary: "\(run.definition.kind.title) 完成")
  }
)
let supervisedRuns = try awaitValue { try await graphSupervisor.run() }
expect(supervisedRuns.allSatisfy { $0.state == .completed }, "Graph Supervisor 必须驱动所有可依赖 Child Session 到完成")
expect(supervisedRuns.allSatisfy { $0.childSessionID != nil }, "Graph Supervisor 必须将真实 Child Session ID 回写到 Scheduler")
expect(supervisorRunTrace.snapshot.map { $0.split(separator: ":").first.map(String.init) ?? "" } == ["explore", "plan"], "Graph Supervisor 必须按 DAG 依赖顺序执行 Child Session")
expect(supervisorRunTrace.snapshot.allSatisfy { $0.contains(":true:") && $0.hasSuffix(":false") }, "Child Session 必须继承父 Session、阶段 Prompt 与过滤后的工具集")
expect(supervisorRunTrace.snapshot.last?.contains("上游阶段回流") == true, "下游 Child Session 必须获得上游阶段的结构化 Handoff")
expect(supervisorSnapshots.count >= 3, "Graph Supervisor 必须在调度和结算时发布可投影快照，UI 不得轮询 Scheduler")

var interruptedGraphRun = AgentRun(
  parentSessionID: supervisedParent.id,
  taskID: supervisedTaskID,
  definition: AgentOrchestrator.builtInDefinition(for: .explore)
)
interruptedGraphRun.state = .running
let restoredGraphSupervisor = AgentGraphSupervisor(
  parent: supervisedParent,
  snapshot: AgentRunSchedulerSnapshot(runs: [interruptedGraphRun], maxConcurrent: 1),
  prompt: { _ in "重启后继续" },
  executor: { run, _, _, _ in AgentResult(summary: "\(run.definition.kind.title) 已恢复") }
)
let restoredGraphSnapshot = await restoredGraphSupervisor.snapshot()
expect(restoredGraphSnapshot.runs.first?.state == .interrupted, "重启恢复必须将未结算 Child Session 标为 interrupted，禁止静默重放")
await restoredGraphSupervisor.continueRun(interruptedGraphRun.id)
let resumedGraphSnapshot = await restoredGraphSupervisor.snapshot()
expect(resumedGraphSnapshot.runs.first?.state == .queued, "重启恢复必须将 interrupted Child Session 显式转回 queued，禁止静默重放")
let restoredGraphRuns = try await restoredGraphSupervisor.run()
expect(restoredGraphRuns.first?.state == .completed, "用户明确继续后 Graph Supervisor 必须从 durable snapshot 恢复执行")

let unifiedKernelSessionID = UUID()
let unifiedKernelTaskID = UUID()
let kernelRuntimeCalls = InvocationCounter()
let kernel = AgentKernel(
  sessionID: unifiedKernelSessionID,
  store: HarnessEventStore(),
  runtime: AgentKernelRuntime(
    operationDriver: { context, emit in
      kernelRuntimeCalls.increment()
      await emit(.assistantText("主会话完成：\(context.prompt.text)"))
    },
    childExecutor: { run, _, _, _ in
      kernelRuntimeCalls.increment()
      return AgentResult(summary: "Child \(run.definition.kind.title) 完成")
    }
  )
)
let kernelOperationID = try awaitValue {
  try await kernel.prompt(PromptInput(text: "统一内核主会话"))
}
_ = try awaitValue {
  try await kernel.wait(kernelOperationID, timeout: 2)
  return true
}
let kernelRun = AgentRun(
  parentSessionID: unifiedKernelSessionID,
  taskID: unifiedKernelTaskID,
  definition: AgentOrchestrator.builtInDefinition(for: .explore)
)
let kernelPlanRun = AgentRun(
  parentSessionID: unifiedKernelSessionID,
  taskID: unifiedKernelTaskID,
  definition: AgentOrchestrator.builtInDefinition(for: .plan),
  dependencies: [kernelRun.id]
)
let kernelGraphOperationID = try awaitValue {
  try await kernel.startGraph(
    taskID: unifiedKernelTaskID,
    parent: SessionRecord(id: unifiedKernelSessionID, taskID: unifiedKernelTaskID, agentID: "supervisor"),
    runs: [kernelRun, kernelPlanRun],
    prompt: { _ in "统一内核 Child" }
  )
}
_ = try awaitValue {
  try await kernel.wait(kernelGraphOperationID, timeout: 2)
  return true
}
let unifiedKernelSnapshot = try awaitValue { await kernel.snapshot() }
expect(unifiedKernelSnapshot.operations[kernelOperationID]?.state == .completed, "AgentKernel 必须统一驱动主会话 Operation")
expect(unifiedKernelSnapshot.operations[kernelGraphOperationID]?.state == .completed, "AgentKernel 必须统一驱动 Child Graph Operation")
expect(unifiedKernelSnapshot.handoffs[kernelGraphOperationID]?[kernelPlanRun.id]?.first?.sourceRunID == kernelRun.id, "AgentKernel Snapshot 必须保留并暴露上游阶段 Handoff")
expect(kernelRuntimeCalls.count == 3, "主会话与 Child Graph 必须从同一个 Kernel Runtime 进入执行")
let kernelGraphAnswer = try awaitValue {
  try await kernel.finalAnswer(for: kernelGraphOperationID, contract: graphContract)
}
expect(kernelGraphAnswer.outcome == .completed && kernelGraphAnswer.finalAnswer.contains("已完成"), "Graph 最终答案必须由 Kernel 基于持久化快照统一生成")

let durableGraphStore = HarnessEventStore()
let durableGraphGate = OneShotAsyncGate()
let durableGraphSessionID = UUID()
let durableGraphTaskID = UUID()
let durableGraphParent = SessionRecord(id: durableGraphSessionID, taskID: durableGraphTaskID, agentID: "supervisor")
let durableGraphKernel = AgentKernel(
  sessionID: durableGraphSessionID,
  store: durableGraphStore,
  runtime: AgentKernelRuntime(
    operationDriver: { _, _ in },
    childExecutor: { _, _, _, _ in
      await durableGraphGate.wait()
      return AgentResult(summary: "durable graph complete")
    }
  )
)
let durableGraphRun = AgentRun(
  parentSessionID: durableGraphSessionID,
  taskID: durableGraphTaskID,
  definition: AgentOrchestrator.builtInDefinition(for: .explore)
)
let durableGraphOperationID = try awaitValue {
  try await durableGraphKernel.startGraph(
    taskID: durableGraphTaskID,
    parent: durableGraphParent,
    runs: [durableGraphRun],
    prompt: { _ in "可恢复 Graph" }
  )
}
try? await Task.sleep(nanoseconds: 50_000_000)
let reopenedGraphKernel = AgentKernel(
  sessionID: durableGraphSessionID,
  store: durableGraphStore,
  runtime: AgentKernelRuntime(
    operationDriver: { _, _ in },
    childExecutor: { _, _, _, _ in AgentResult(summary: "reopened graph complete") }
  )
)
_ = try awaitValue { try await reopenedGraphKernel.restore(); return true }
let reopenedGraphKernelSnapshot = try awaitValue { await reopenedGraphKernel.snapshot() }
expect(reopenedGraphKernelSnapshot.graphSnapshots[durableGraphOperationID] != nil, "Kernel 必须从事件存储恢复 Graph Scheduler 快照")
expect(reopenedGraphKernelSnapshot.operations[durableGraphOperationID]?.state == .suspended, "重启恢复的 Graph Operation 必须等待用户显式继续")
await durableGraphGate.open()
_ = try? awaitValue { try await durableGraphKernel.wait(durableGraphOperationID, timeout: 2); return true }

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
let legacyRecoveryRuns = AgentOrchestrator.makePlan(taskID: UUID(), mode: .agent).runs
expect(
  !AgentGraphRecoveryPolicy.shouldRestoreGraph(decision: greetingStrategy, runs: legacyRecoveryRuns),
  "历史普通对话即使带有迁移 AgentRun 记录，也不得在重启后恢复为规划图"
)
expect(
  AgentGraphRecoveryPolicy.shouldRestoreGraph(decision: implementationStrategy, runs: legacyRecoveryRuns),
  "真正的编程任务在存在未结算节点时必须恢复 Supervisor"
)
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
expect(
  SkillRegistry.discover(projectDirectory: temporaryDirectory).contains { $0.name == "plugin-review" },
  "插件内的 Skills 必须进入统一发现与执行链"
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

let unifiedPermissionGate = DefaultHarnessPermissionGate()
let unifiedPermissionContext = HarnessPermissionContext(
  taskID: orchestrationTaskID,
  sessionID: UUID(),
  worktreePath: temporaryDirectory.path,
  grants: [capabilityGrant]
)
let unifiedReadDecision = try awaitValue {
  await unifiedPermissionGate.evaluate(
    request: ToolExecutionRequest(
      taskID: orchestrationTaskID,
      sessionID: unifiedPermissionContext.sessionID,
      agentID: "explore",
      toolID: "read",
      resource: temporaryDirectory.appendingPathComponent("README.md").path
    ),
    tool: ToolDefinition(id: "read", title: "读取", description: "读取文件", permissionScopes: [.readWorkspace]),
    context: unifiedPermissionContext
  )
}
expect(unifiedReadDecision == .allow, "统一 Permission Gate 必须接受 Worktree 内已授权读取")
let unifiedOutsideWriteDecision = try awaitValue {
  await unifiedPermissionGate.evaluate(
    request: ToolExecutionRequest(
      taskID: orchestrationTaskID,
      sessionID: unifiedPermissionContext.sessionID,
      agentID: "implement",
      toolID: "write",
      resource: "/tmp/outside"
    ),
    tool: ToolDefinition(id: "write", title: "写入", description: "写入文件", permissionScopes: [.writeWorkspace]),
    context: unifiedPermissionContext
  )
}
expect(unifiedOutsideWriteDecision == .deny, "统一 Permission Gate 必须拒绝 Worktree 外写入")

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

let toolRegistry = ToolRegistry(definitions: ToolCatalog.defaultDefinitions)
let exploreTools = try awaitValue {
  await toolRegistry.availableTools(for: AgentOrchestrator.builtInDefinition(for: .explore))
}
expect(exploreTools.contains(where: { $0.id == "read" }), "Explore Agent 必须获得 read Tool")
expect(!exploreTools.contains(where: { $0.id == "write" }), "Explore Agent 不得获得 write Tool")
let implementTools = try awaitValue {
  await toolRegistry.availableTools(for: AgentOrchestrator.builtInDefinition(for: .implement))
}
expect(implementTools.contains(where: { $0.id == "write" }), "Implement Agent 必须获得 write Tool")
expect(implementTools.contains(where: { $0.id == "shell" }), "Implement Agent 必须获得 shell Tool")

let executor = ClosureToolExecutor { request in
  ToolExecutionResult(output: "执行 " + request.toolID, metadata: ["resource": request.resource ?? ""])
}
_ = try awaitValue {
  await toolRegistry.register(
    ToolDefinition(id: "test.tool", title: "测试工具", description: "测试统一执行链", permissionScopes: [.readWorkspace]),
    executor: executor
  )
  return true
}
let permissionResolver = StaticToolPermissionResolver(decision: .allow)
let coordinator = ToolExecutionCoordinator(registry: toolRegistry, permissionResolver: permissionResolver)
let executionResult = try awaitValue {
  try await coordinator.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    agentID: "explore",
    toolID: "test.tool",
    input: ["query": "登录"],
    resource: temporaryDirectory.path
  ))
}
expect(executionResult.output == "执行 test.tool", "Tool Registry 必须调用注册的真实执行器")
let toolJournalStore = HarnessEventStore()
let toolJournal = ToolEffectJournal(store: toolJournalStore, sessionID: kernelSessionID, lane: .main)
let journalCoordinator = ToolExecutionCoordinator(
  registry: toolRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  journal: toolJournal
)
_ = try awaitValue {
  try await journalCoordinator.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: kernelTaskID,
    agentID: "explore",
    toolID: "test.tool",
    resource: temporaryDirectory.path
  ))
}
let toolJournalEvents = try awaitValue { await toolJournalStore.events(operationID: kernelTaskID) }
expect(toolJournalEvents.contains { $0.kind == .effectIntentWritten }, "Tool Coordinator 必须在执行前写入 effect intent")
expect(toolJournalEvents.contains { $0.kind == .permissionSettled }, "Tool Coordinator 必须持久化权限决定")
expect(toolJournalEvents.contains { $0.kind == .effectSettled }, "Tool Coordinator 必须在执行后写入 effect receipt")
let idempotentDefinition = ToolDefinition(id: "idempotent.tool", title: "幂等工具", description: "验证重复 Effect 不重放", permissionScopes: [.readWorkspace])
let idempotentRegistry = ToolRegistry(definitions: [idempotentDefinition])
let idempotentCounter = InvocationCounter()
_ = try awaitValue {
  await idempotentRegistry.register(idempotentDefinition, executor: ClosureToolExecutor { _ in
    idempotentCounter.increment()
    return ToolExecutionResult(output: "只执行一次")
  })
  return true
}
let idempotentJournalStore = HarnessEventStore()
let idempotentCoordinator = ToolExecutionCoordinator(
  registry: idempotentRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  journal: ToolEffectJournal(store: idempotentJournalStore, sessionID: kernelSessionID, lane: .main)
)
let duplicateRequest = ToolExecutionRequest(
  id: UUID(),
  taskID: kernelTaskID,
  sessionID: kernelSessionID,
  operationID: kernelTaskID,
  agentID: "main",
  toolID: "idempotent.tool"
)
_ = try awaitValue { try await idempotentCoordinator.execute(duplicateRequest) }
_ = try awaitValue { try await idempotentCoordinator.execute(duplicateRequest) }
expect(idempotentCounter.count == 1, "已有成功 Receipt 的同一 Effect 不得重复执行")
let faultDefinition = ToolDefinition(id: "fault.tool", title: "故障注入工具", description: "验证 effect 边界恢复", permissionScopes: [.readWorkspace])
let faultRegistry = ToolRegistry(definitions: [faultDefinition])
_ = try awaitValue {
  await faultRegistry.register(faultDefinition, executor: ClosureToolExecutor { _ in
    ToolExecutionResult(output: "不应在 intent 后故障点执行")
  })
  return true
}
let faultStore = HarnessEventStore()
let faultInjector = HarnessFaultInjector(failures: [.afterIntent: 1])
let faultCoordinator = ToolExecutionCoordinator(
  registry: faultRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  journal: ToolEffectJournal(store: faultStore, sessionID: kernelSessionID, lane: .main),
  faultInjector: faultInjector
)
let faultExecution: Result<ToolExecutionResult, Error> = Result {
  try awaitValue {
    try await faultCoordinator.execute(ToolExecutionRequest(
      taskID: kernelTaskID,
      sessionID: kernelSessionID,
      operationID: kernelTaskID,
      agentID: "main",
      toolID: "fault.tool"
    ))
  }
}
if case .success = faultExecution {
  expect(false, "故障注入必须在指定 Effect 边界中断执行")
}
let faultEvents = try awaitValue { await faultStore.events(operationID: kernelTaskID) }
let faultIntent = faultEvents.compactMap { event -> HarnessEffectIntent? in
  guard event.kind == .effectIntentWritten, let payload = event.payload else { return nil }
  return try? JSONDecoder().decode(HarnessEffectIntent.self, from: payload)
}.first
expect(faultIntent != nil && !faultEvents.contains { $0.kind == .effectSettled }, "intent 后崩溃不得伪造 receipt")
if let faultIntent {
  let faultRecovery = HarnessRecoveryEngine.actions(for: HarnessSnapshot(
    sessionID: kernelSessionID,
    intents: [faultIntent.effectID: faultIntent]
  ))
  expect(
    faultRecovery.contains { $0.kind == .retrySafeEffect && $0.effectID == faultIntent.effectID },
    "低风险 intent 无 receipt 时恢复引擎必须仅标记为可安全重试"
  )
}
let batchRequests = [
  ToolExecutionRequest(taskID: kernelTaskID, sessionID: kernelSessionID, agentID: "explore", toolID: "test.tool", input: ["value": "1"]),
  ToolExecutionRequest(taskID: kernelTaskID, sessionID: kernelSessionID, agentID: "explore", toolID: "test.tool", input: ["value": "2"])
]
let batchResults = try awaitValue { await coordinator.executeBatch(batchRequests) }
expect(batchResults.count == 2, "Tool Batch 必须返回每个 Tool Call 的结果")
expect(batchResults.allSatisfy { if case .success = $0 { return true }; return false }, "Tool Batch 的成功结果不能被并发调度吞掉")
let capabilityResolver = CapabilityToolPermissionResolver(grants: [capabilityGrant], defaultDecision: .deny)
let capabilityDecision = try awaitValue {
  await capabilityResolver.resolve(
    request: ToolExecutionRequest(
      taskID: orchestrationTaskID,
      sessionID: kernelSessionID,
      agentID: "explore",
      toolID: "test.tool",
      resource: temporaryDirectory.path
    ),
    definition: ToolCatalog.defaultDefinitions[0]
  )
}
expect(capabilityDecision == .allow, "Capability Grant 必须成为 Tool 执行的统一权限门禁")
let deniedCoordinator = ToolExecutionCoordinator(
  registry: toolRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .deny)
)
let deniedResult: Result<ToolExecutionResult, Error> = Result {
  try awaitValue {
    try await deniedCoordinator.execute(ToolExecutionRequest(
      taskID: kernelTaskID,
      sessionID: kernelSessionID,
      agentID: "explore",
      toolID: "test.tool",
      resource: temporaryDirectory.path
    ))
  }
}
if case .success = deniedResult {
  expect(false, "统一权限解析器拒绝后不得执行 Tool")
}
let pendingPermissionStore = HarnessEventStore()
let pendingPermissionCoordinator = ToolExecutionCoordinator(
  registry: toolRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .ask),
  journal: ToolEffectJournal(store: pendingPermissionStore, sessionID: kernelSessionID, lane: .main)
)
let pendingPermissionResult: Result<ToolExecutionResult, Error> = Result {
  try awaitValue {
    try await pendingPermissionCoordinator.execute(ToolExecutionRequest(
      taskID: kernelTaskID,
      sessionID: kernelSessionID,
      operationID: kernelTaskID,
      agentID: "main",
      toolID: "test.tool"
    ))
  }
}
if case .success = pendingPermissionResult {
  expect(false, "没有审批处理器的 Tool 不得直接执行")
}
let pendingPermissionEvents = try awaitValue { await pendingPermissionStore.events(operationID: kernelTaskID) }
expect(pendingPermissionEvents.contains { event in
  guard event.kind == .permissionSettled,
        let payload = event.payload,
        let receipt = try? JSONDecoder().decode(HarnessPermissionReceipt.self, from: payload) else { return false }
  return receipt.decision == .ask
}, "等待用户审批的状态必须作为 durable Permission Receipt 持久化")

let nonZeroDefinition = ToolDefinition(
  id: "nonzero.tool",
  title: "失败工具",
  description: "返回非零退出码的工具",
  permissionScopes: [.readWorkspace]
)
let nonZeroRegistry = ToolRegistry(definitions: [nonZeroDefinition])
_ = try awaitValue { await nonZeroRegistry.register(nonZeroDefinition, executor: ClosureToolExecutor { _ in
  ToolExecutionResult(output: "验证失败上下文", exitCode: 1)
}) }
let nonZeroStore = HarnessEventStore()
let nonZeroJournal = ToolEffectJournal(store: nonZeroStore, sessionID: kernelSessionID, lane: .main)
let nonZeroCoordinator = ToolExecutionCoordinator(
  registry: nonZeroRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .allow),
  journal: nonZeroJournal
)
let nonZeroExecution: Result<ToolExecutionResult, Error> = Result {
  try awaitValue {
    try await nonZeroCoordinator.execute(ToolExecutionRequest(
      taskID: kernelTaskID,
      sessionID: kernelSessionID,
      operationID: operationID,
      agentID: "main",
      toolID: "nonzero.tool"
    ))
  }
}
if case .success = nonZeroExecution {
  expect(false, "非零 Tool 结果必须进入失败 receipt，而不是伪装成功")
}
let nonZeroReceipts = try awaitValue { await nonZeroStore.events(operationID: operationID) }
expect(nonZeroReceipts.contains { event in
  guard event.kind == .effectSettled, let payload = event.payload,
        let receipt = try? JSONDecoder().decode(HarnessEffectReceipt.self, from: payload) else { return false }
  return receipt.outcome == .failure
}, "非零 Tool 结果必须持久化 failure receipt")

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

let singleWriterStore = HarnessEventStore()
let singleWriterDefinition = ToolDefinition(id: "single-writer.tool", title: "单写入工具", description: "验证 Harness 是唯一 effect writer", permissionScopes: [.readWorkspace])
let singleWriterRegistry = ToolRegistry(definitions: [singleWriterDefinition])
_ = try awaitValue { await singleWriterRegistry.register(singleWriterDefinition, executor: ClosureToolExecutor { _ in ToolExecutionResult(output: "ok") }) }
let singleWriterHarness = AgentHarness(store: singleWriterStore) { context, emit in
  let journal = ToolEffectJournal(store: singleWriterStore, sessionID: context.sessionID, lane: context.lane, eventSink: emit)
  let coordinator = ToolExecutionCoordinator(
    registry: singleWriterRegistry,
    permissionResolver: StaticToolPermissionResolver(decision: .allow),
    journal: journal
  )
  _ = try await coordinator.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: context.sessionID,
    operationID: context.operationID,
    agentID: "main",
    toolID: "single-writer.tool"
  ))
}
let singleWriterOperation = try awaitValue { try await singleWriterHarness.prompt(PromptInput(text: "单写入")) }
_ = try awaitValue { try await singleWriterHarness.wait(for: singleWriterOperation, timeout: 1); return true }
let singleWriterEffects = try awaitValue { await singleWriterStore.events(operationID: singleWriterOperation) }
expect(singleWriterEffects.filter { $0.kind == .effectIntentWritten }.count == 1, "Harness 模式下 intent 只能写入一次")
expect(singleWriterEffects.filter { $0.kind == .effectSettled }.count == 1, "Harness 模式下 receipt 只能写入一次")

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
let legacyState = AppState(tasks: [AgentTask(
  title: "旧任务导入",
  mode: .plan,
  workspacePath: temporaryDirectory.path,
  events: ["旧事件"]
)])
let legacyImport = try awaitValue { try await HarnessLegacyMigrator.import(state: legacyState) }
expect(legacyImport.count == 1 && legacyImport[0].entries.contains { $0.kind == .legacy }, "旧 state.json 必须能导入为只读历史 Session")

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

let providerContext = HarnessProviderContext(
  sessionID: recoverySessionID,
  operationID: recoveryOperation,
  lane: .main,
  modelID: "kimi-k2.7-code",
  messages: [
    HarnessChatMessage(role: .system, content: "始终使用中文。"),
    .user("你好"),
    .assistant("我会读取文件。", toolCalls: [HarnessToolCall(id: "provider-call", name: "read", argumentsJSON: #"{\"path\":\"README.md\"}"#)]),
    .tool(HarnessToolResult(callID: "provider-call", toolName: "read", output: "README 内容", isError: false))
  ]
)
expect(providerContext.messages.map(\.role) == [.system, .user, .assistant, .tool], "Provider Context 必须保留 system/user/assistant/tool 的原始角色顺序")
let provider = StaticHarnessModelProvider(events: [.text("回复")])
let providerEvents = try awaitValue {
  let stream = try await provider.stream(context: providerContext, tools: [], signal: nil)
  var values: [HarnessModelEvent] = []
  for try await event in stream { values.append(event) }
  return values
}
expect(providerEvents.contains { $0.kind == .text && $0.text == "回复" }, "Provider Adapter 必须输出统一 ModelEvent")
let retryingProvider = RetryingHarnessModelProvider(
  base: FlakyHarnessProvider(),
  maxAttempts: 2,
  backoffNanoseconds: 1
)
let retryingEvents = try awaitValue {
  let stream = try await retryingProvider.stream(context: providerContext, tools: [], signal: nil)
  var values: [HarnessModelEvent] = []
  for try await event in stream { values.append(event) }
  return values
}
expect(retryingEvents.contains { $0.text == "retry succeeded" }, "Provider 瞬态失败必须在没有输出时按退避策略重试")
let retryingConversationProvider = RetryingHarnessConversationProvider(
  base: FlakyConversationProvider(),
  maxAttempts: 2,
  backoffNanoseconds: 1
)
let retryingConversationEvents = try awaitValue {
  let stream = try await retryingConversationProvider.stream(
    request: HarnessConversationRequest(modelID: "kimi", messages: [.user("重试")]),
    tools: [],
    signal: nil
  )
  var values: [HarnessConversationEvent] = []
  for try await event in stream { values.append(event) }
  return values
}
expect(retryingConversationEvents.contains { $0 == .text("conversation retry succeeded") }, "Conversation Provider 瞬态失败必须在没有输出时自动重试")

let nativeLoopProvider = ScriptedHarnessConversationProvider(turns: [
  [.text("我先读取文件。"), .toolCall(id: "call-1", name: "read", argumentsJSON: "{\"path\":\"README.md\"}")],
  [.text("文件读取完成。")]
])
let nativeLoopTrace = ThreadSafeStringTrace()
let nativeLoop = HarnessConversationLoop(
  provider: nativeLoopProvider,
  maxRounds: 4,
  executeTool: { call, _ in
    expect(call.name == "read", "Native Harness Loop 必须接收模型 Tool Call")
    return HarnessToolResult(callID: call.id, toolName: call.name, output: "README 内容", isError: false)
  },
  eventSink: { event in
    switch event {
    case .turnStarted: nativeLoopTrace.append("turnStarted")
    case .stepStarted: nativeLoopTrace.append("stepStarted")
    case .requestHeader: nativeLoopTrace.append("requestHeader")
    case .modelChunk: nativeLoopTrace.append("modelChunk")
    case .assistantMessage: nativeLoopTrace.append("assistantMessage")
    case .toolCallDeclared: nativeLoopTrace.append("toolCallDeclared")
    case .toolResultRecorded: nativeLoopTrace.append("toolResultRecorded")
    case .stepEnded: nativeLoopTrace.append("stepEnded")
    case .turnEnded: nativeLoopTrace.append("turnEnded")
    default: break
    }
  }
)
let nativeLoopResult = try awaitValue {
  try await nativeLoop.run(
    request: HarnessConversationRequest(
      modelID: "kimi-k2.7-code",
      messages: [.user("读取 README.md")]
    ),
    tools: []
  )
}
expect(nativeLoopResult.text.contains("文件读取完成"), "Native Harness Loop 必须把 Tool Result 回传后继续请求模型")
expect(nativeLoopResult.toolResults.count == 1, "Native Harness Loop 必须记录 Tool Result")
expect(nativeLoopTrace.snapshot.contains("requestHeader") && nativeLoopTrace.snapshot.contains("modelChunk"), "Native Harness Loop 必须把请求头和原始模型流交给 durable Harness")
expect(nativeLoopTrace.snapshot.contains("assistantMessage") && nativeLoopTrace.snapshot.contains("toolResultRecorded"), "Native Harness Loop 必须输出规范 assistant message 和 tool result 事实")
expect(nativeLoopTrace.snapshot.last == "turnEnded", "Native Harness Loop 必须在每个回合结束时写入 turnEnded")

let injectedStepQueue = ThreadSafePromptQueue()
let steeredLoopProvider = ScriptedHarnessConversationProvider(turns: [
  [.toolCall(id: "step-read", name: "read", argumentsJSON: #"{"path":"README.md"}"#)],
  [.text("已按补充要求继续。")]
])
let steeredLoop = HarnessConversationLoop(
  provider: steeredLoopProvider,
  maxRounds: 3,
  executeTool: { call, _ in
    injectedStepQueue.append(PromptInput(text: "只读取，不修改文件"))
    return HarnessToolResult(callID: call.id, toolName: call.name, output: "README", isError: false)
  },
  nextStepInput: { injectedStepQueue.take() }
)
_ = try awaitValue {
  try await steeredLoop.run(
    request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("读取 README")]),
    tools: []
  )
}
let steeredRequests = try awaitValue { await steeredLoopProvider.requests() }
let secondSteeredRequest = steeredRequests.count > 1 ? steeredRequests[1] : nil
let didInjectSteering = secondSteeredRequest?.messages.contains { message in
  message.role == .user && (message.content?.contains("只读取，不修改文件") ?? false)
} ?? false
expect(didInjectSteering, "next-step 输入必须在工具结算后的下一模型请求注入，不需要重新启动回合")
let repeatedFailureProvider = ScriptedHarnessConversationProvider(turns: [
  [.toolCall(id: "bad-1", name: "web.fetch", argumentsJSON: "{}")],
  [.toolCall(id: "bad-2", name: "web.fetch", argumentsJSON: "{}")]
])
let repeatedFailureLoop = HarnessConversationLoop(provider: repeatedFailureProvider, maxRounds: 8) { call, _ in
  HarnessToolResult(callID: call.id, toolName: call.name, output: "工具缺少参数：url", isError: true)
}
let repeatedFailureResult = try awaitValue {
  try await repeatedFailureLoop.run(
    request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("预测天气")]),
    tools: []
  )
}
expect(repeatedFailureResult.blockedByToolFailure, "同一 Tool 参数连续失败时必须停止重试并返回明确阻断状态")
expect(repeatedFailureResult.text.contains("url"), "Tool 参数失败必须把可修复的参数提示返回给用户")

let missingSearchArguments = HarnessConversationLoop.recoverToolCall(
  HarnessToolCall(id: "missing-query", name: "web.search", argumentsJSON: "{}"),
  request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("明天天气怎么样？")])
)
let missingSearchObject = try? JSONSerialization.jsonObject(
  with: Data(missingSearchArguments.argumentsJSON.utf8)
) as? [String: Any]
expect(
  missingSearchArguments.name == "web.search" &&
    missingSearchObject?.isEmpty == true,
  "web.search 缺少 query 时必须由模型在下一步显式修正"
)

let longComposedSearchPrompt = TaskPromptComposer.compose(
  prompt: "明天北京天气如何",
  mode: .agent,
  workspacePath: "/Users/eastbuy/Projects/sample",
  tools: ToolCatalog.defaultDefinitions
)
let recoveredComposedPromptSearch = HarnessConversationLoop.recoverToolCall(
  HarnessToolCall(id: "long-composed-query", name: "web.search", argumentsJSON: "{}"),
  request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user(longComposedSearchPrompt)])
)
let recoveredComposedPromptObject = try? JSONSerialization.jsonObject(
  with: Data(recoveredComposedPromptSearch.argumentsJSON.utf8)
) as? [String: Any]
expect(
  recoveredComposedPromptObject?.isEmpty == true,
  "长任务提示不能被 Harness 反向解析为 Web Search 参数"
)
expect(
  recoveredComposedPromptSearch.argumentsJSON == "{}",
  "Harness 必须原样保留模型缺失的 Web Search 参数"
)

let emptySearchArguments = HarnessConversationLoop.recoverToolCall(
  HarnessToolCall(id: "empty-query", name: "web_search", argumentsJSON: #"{"query":""}"#),
  request: HarnessConversationRequest(modelID: "kimi-k2.7-code", messages: [.user("上海今天下雨吗？")])
)
let emptySearchObject = try? JSONSerialization.jsonObject(
  with: Data(emptySearchArguments.argumentsJSON.utf8)
) as? [String: Any]
expect(
  emptySearchArguments.name == "web.search" &&
    emptySearchObject?["query"] as? String == "",
  "web_search 空 query 只能规范化名称，不能恢复用户问题"
)

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

let nativeToolWorkspace = temporaryDirectory.appendingPathComponent("native-tool-workspace", isDirectory: true)
try FileManager.default.createDirectory(at: nativeToolWorkspace, withIntermediateDirectories: true)
try "hello harness".write(to: nativeToolWorkspace.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
let nativeToolRuntime = NativeHarnessToolRuntime(workspaceURL: nativeToolWorkspace)
expect(NativeHarnessToolRuntime.webFetchExitCode(for: 200) == 0, "HTTP 2xx Web Fetch 必须被 Harness 视为成功")
expect(NativeHarnessToolRuntime.webFetchExitCode(for: 404) == 404, "HTTP 错误状态必须保留为失败码")
let nativeReadResult = try awaitValue {
  try await nativeToolRuntime.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: operationID,
    agentID: "main",
    toolID: "read",
    input: ["path": "hello.txt"]
  ))
}
expect(nativeReadResult.output.contains("hello harness"), "Harness Native Tool Runtime 必须能读取工作区文件")
let nativeFetchServer = try startLocalHTTPServer()
let nativeFetchPort = nativeFetchServer.port
let nativeFetchResult = try awaitValue {
  try await nativeToolRuntime.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: operationID,
    agentID: "main",
    toolID: "web.fetch",
    input: ["url": "http://127.0.0.1:\(nativeFetchPort)"]
  ))
}
nativeFetchServer.stop()
expect(
  nativeFetchResult.exitCode == 0 && nativeFetchResult.output.contains("sandbox-http-ok") && nativeFetchResult.metadata["transport"] == "sandboxed-curl",
  "Harness Web Fetch 必须通过受限网络执行器返回真实内容"
)
let nativeShellInsideResult = try awaitValue {
  try await nativeToolRuntime.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: operationID,
    agentID: "main",
    toolID: "shell",
    input: ["command": "printf native-shell-ok > native-shell-inside.txt"]
  ))
}
expect(
  nativeShellInsideResult.exitCode == 0 && FileManager.default.fileExists(atPath: nativeToolWorkspace.appendingPathComponent("native-shell-inside.txt").path),
  "Harness Shell 必须在受限 Worktree 中执行写入"
)
let nativeShellEscapeURL = nativeToolWorkspace.deletingLastPathComponent().appendingPathComponent("kimi-native-shell-escape-\(UUID().uuidString)")
let nativeShellEscapeResult = try awaitValue {
  try await nativeToolRuntime.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: operationID,
    agentID: "main",
    toolID: "shell",
    input: ["command": "touch '\(nativeShellEscapeURL.path)' && rm '\(nativeShellEscapeURL.path)'"]
  ))
}
expect(
  nativeShellEscapeResult.exitCode != 0 && !FileManager.default.fileExists(atPath: nativeShellEscapeURL.path),
  "Harness Shell 必须由 Seatbelt 阻止 Worktree 外写入"
)
let secretOutsideWorkspace = temporaryDirectory.appendingPathComponent("kimi-secret-\(UUID().uuidString).txt")
try "top-secret".write(to: secretOutsideWorkspace, atomically: true, encoding: .utf8)
try FileManager.default.createSymbolicLink(
  at: nativeToolWorkspace.appendingPathComponent("leak-link.txt"),
  withDestinationURL: secretOutsideWorkspace
)
let nativeSymlinkReadResult = try? awaitValue {
  try await nativeToolRuntime.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: operationID,
    agentID: "main",
    toolID: "read",
    input: ["path": "leak-link.txt"]
  ))
}
expect(
  nativeSymlinkReadResult?.output.contains("top-secret") != true,
  "Harness Native Tool 必须解析符号链接并阻止工作区外读取"
)
let symlinkWriteTarget = temporaryDirectory.appendingPathComponent("kimi-symlink-write-\(UUID().uuidString).txt")
try FileManager.default.createSymbolicLink(
  at: nativeToolWorkspace.appendingPathComponent("write-link.txt"),
  withDestinationURL: symlinkWriteTarget
)
let nativeSymlinkWriteResult = try? awaitValue {
  try await nativeToolRuntime.execute(ToolExecutionRequest(
    taskID: kernelTaskID,
    sessionID: kernelSessionID,
    operationID: operationID,
    agentID: "main",
    toolID: "write",
    input: ["path": "write-link.txt", "content": "should-not-land"]
  ))
}
expect(
  nativeSymlinkWriteResult == nil && !FileManager.default.fileExists(atPath: symlinkWriteTarget.path),
  "Harness Native Tool 必须阻止通过符号链接向工作区外写入"
)

// Specialized adapters must be executable through the same native runtime
// boundary as filesystem and shell tools. These checks exercise the Browser,
// MCP, and Computer Use paths through their production Harness adapters.
let specializedCalls = LockedStringCollector()
let specializedRuntime = NativeHarnessToolRuntime(
  workspaceURL: nativeToolWorkspace,
  browserHandler: { request in
    specializedCalls.append("browser:\(request.toolID)")
    return ToolExecutionResult(output: "browser-ok", metadata: ["adapter": "browser"])
  },
  computerUseHandler: { request in
    specializedCalls.append("computer:\(request.toolID)")
    return ToolExecutionResult(output: "computer-ok", metadata: ["adapter": "computer"])
  },
  mcpHandler: { request in
    specializedCalls.append("mcp:\(request.toolID)")
    return ToolExecutionResult(output: "mcp-ok", metadata: ["adapter": "mcp"])
  }
)
let specializedRequests = [
  ("browser", "browser-ok"),
  ("computer_use.click", "computer-ok"),
  ("mcp", "mcp-ok")
]
for (toolID, expected) in specializedRequests {
  let specializedResult = try awaitValue {
    try await specializedRuntime.execute(ToolExecutionRequest(
      taskID: kernelTaskID,
      sessionID: kernelSessionID,
      operationID: operationID,
      agentID: "main",
      toolID: toolID,
      input: ["url": "http://localhost"]
    ))
  }
  expect(specializedResult.output == expected, "\(toolID) 必须通过 Native Harness Adapter 执行")
}
expect(specializedCalls.values.count == 3, "三个专用 Adapter 都必须被真实调用")
let mcpServerID = UUID()
let mcpToolID = MCPHarnessToolIdentifier.make(serverID: mcpServerID, toolName: "echo")
expect(MCPHarnessToolIdentifier.parse(mcpToolID)?.serverID == mcpServerID, "MCP 工具 ID 必须保留 Server 身份")
expect(MCPHarnessToolIdentifier.parse(mcpToolID)?.toolName == "echo", "MCP 工具 ID 必须保留 Tool 名称")
let browserRequest = ToolExecutionRequest(
  taskID: kernelTaskID,
  sessionID: kernelSessionID,
  operationID: operationID,
  agentID: "browser",
  toolID: "browser",
  input: ["action": "open", "url": "http://localhost:3000"]
)
let browserPlan = try BrowserHarnessRequestDecoder.plan(from: browserRequest)
expect(browserPlan.steps.first?.kind == .open, "Browser Adapter 必须支持 action 形式的最小计划")
expect(browserPlan.steps.first?.url?.absoluteString == "http://localhost:3000", "Browser Adapter 必须保留目标 URL")
let browserFallbackRequest = ToolExecutionRequest(
  taskID: kernelTaskID,
  sessionID: kernelSessionID,
  operationID: operationID,
  agentID: "browser",
  toolID: "browser",
  input: ["action": "screenshot"]
)
let browserFallbackPlan = try BrowserHarnessRequestDecoder.plan(
  from: browserFallbackRequest,
  fallbackURL: URL(string: "https://example.com/")
)
expect(browserFallbackPlan.steps.map(\.kind) == [.open, .screenshot], "独立 screenshot 调用必须复用用户显式 URL 打开页面")
expect(browserFallbackPlan.steps.first?.url?.host == "example.com", "Browser URL 回退只能使用用户明确给出的目标")
let pollutedBrowserRequest = ToolExecutionRequest(
  taskID: kernelTaskID,
  sessionID: kernelSessionID,
  operationID: operationID,
  agentID: "browser",
  toolID: "browser",
  input: ["action": "open", "url": "https://example.com/%EF%BC%8C检查页面"]
)
let sanitizedBrowserPlan = try BrowserHarnessRequestDecoder.plan(
  from: pollutedBrowserRequest,
  fallbackURL: URL(string: "https://example.com/")
)
expect(sanitizedBrowserPlan.steps.first?.url?.absoluteString == "https://example.com/", "Browser 同域污染 URL 必须回退到用户显式目标")
expect(BrowserHarnessRequestDecoder.firstHTTPURL(in: "打开 https://example.com/path?x=1 后截图")?.absoluteString == "https://example.com/path?x=1", "Browser URL 提取必须保留用户指定的完整 URL")
expect(BrowserHarnessRequestDecoder.firstHTTPURL(in: "打开 https://example.com/，检查页面")?.absoluteString == "https://example.com/", "Browser URL 提取必须去除中文标点后的自然语言")
expect(HarnessToolNameCodec.wireName(for: "web.fetch") == "web_fetch", "Provider 工具名必须符合 Kimi API 命名规则")
expect(HarnessToolNameCodec.runtimeName(for: "web_fetch") == "web.fetch", "Provider 工具名必须能映射回 Runtime 工具 ID")
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
let childRuntimeConfiguration = KimiChildRuntimeConfiguration(
  nodePath: "/usr/bin/node",
  hostScriptURL: temporaryDirectory.appendingPathComponent("agent-host.cjs"),
  runtimePath: "/tmp/kimi.mjs",
  workspacePath: temporaryDirectory.path,
  taskID: kernelTaskID.uuidString,
  modelID: "kimi-k2.7-code",
  skillsDirectories: []
)
let childRuntimeExecutor = KimiChildRuntimeExecutor(configuration: childRuntimeConfiguration, onEvent: { _ in })
expect(childRuntimeExecutor.configuration.modelID == "kimi-k2.7-code", "Child Runtime 必须携带独立模型配置")
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
let secondTurn = ConversationTurn(sequence: 2, userMessage: "继续检查", status: .running)
let firstTurnEvent = AgentEvent(sessionID: turnTestSessionID, taskID: turnTestTaskID, turnID: firstTurn.id, sequence: 1, actor: "kimi-runtime", kind: .output, payload: ["text": firstTurn.assistantMessage])
let secondTurnEvent = AgentEvent(sessionID: turnTestSessionID, taskID: turnTestTaskID, turnID: secondTurn.id, sequence: 2, actor: "desktop", kind: .taskStarted, payload: ["text": "正在启动 Kimi Runtime…"])
let conversationEvents: [AgentEvent] = [
  firstTurnEvent,
  secondTurnEvent
]
let turnConversationTask = AgentTask(
  id: turnTestTaskID,
  title: firstTurn.userMessage,
  mode: .plan,
  workspacePath: temporaryDirectory.path,
  sessionID: turnTestSessionID.uuidString,
  structuredEvents: conversationEvents,
  turns: [firstTurn, secondTurn],
  activeTurnID: secondTurn.id
)
let turnConversationEntries = AgentConversationPresentation.entries(for: turnConversationTask)
expect(turnConversationEntries.filter { $0.role == .user }.count == 2, "同一会话的两轮用户消息必须各显示一次")
expect(turnConversationEntries.filter { $0.role == .assistant }.count == 1, "助手正文必须合并为一个回答块")
expect(!turnConversationEntries.contains { $0.text.contains("正在启动 Kimi Runtime") }, "Runtime 状态不能混入主对话气泡")

let streamedTurn = ConversationTurn(sequence: 1, userMessage: "继续", status: .running)
let streamedTaskID = UUID()
let streamedSessionID = UUID()
let streamedFirstChunk = AgentEvent(
  sessionID: streamedSessionID,
  taskID: streamedTaskID,
  turnID: streamedTurn.id,
  sequence: 1,
  actor: "kimi-acp-host",
  kind: .output,
  payload: ["contentType": "text", "text": "第一段"]
)
let streamedSecondChunk = AgentEvent(
  sessionID: streamedSessionID,
  taskID: streamedTaskID,
  turnID: streamedTurn.id,
  sequence: 2,
  actor: "kimi-acp-host",
  kind: .output,
  payload: ["contentType": "text", "text": "第二段"]
)
let streamedTask = AgentTask(
  id: streamedTaskID,
  title: streamedTurn.userMessage,
  mode: .plan,
  workspacePath: temporaryDirectory.path,
  sessionID: streamedSessionID.uuidString,
  structuredEvents: [streamedFirstChunk, streamedSecondChunk],
  turns: [streamedTurn],
  activeTurnID: streamedTurn.id
)
let streamedEntries = AgentConversationPresentation.entries(for: streamedTask)
let streamedAssistantEntries = streamedEntries.filter { $0.role == .assistant }
expect(streamedAssistantEntries.count == 1, "流式助手正文必须仍然只有一个回答块")
expect(streamedAssistantEntries.first?.id == "turn-assistant-\(streamedTurn.id.uuidString)", "流式助手回答块 ID 必须按 Turn 稳定，避免 SwiftUI 每个 chunk 重建布局")
let longReply = String(repeating: "北京未来三小时以雷阵雨为主，来源已核验。\n\n", count: 80)
let longReplyTurn = ConversationTurn(sequence: 1, userMessage: "查询天气", assistantMessage: longReply, status: .completed)
let longReplyTask = AgentTask(title: "查询天气", mode: .plan, workspacePath: "/tmp/demo", turns: [longReplyTurn])
let longReplyEntry = AgentConversationPresentation.entries(for: longReplyTask).first { $0.role == .assistant }
expect(longReplyEntry?.text.count == longReply.trimmingCharacters(in: .whitespacesAndNewlines).count, "长助手回复必须完整保留，展示层不能截断正文")

let legacyWebFailureText = "工具调用连续失败：Web Search 请求失败：HTTP 502：Web Search 请求失败：官方联网失败，公开检索也失败。官方：kimi_official Web Search 超时，已自动切换公开检索。；公开检索：Web Search 查询不能超过 500 个字符。"
let legacyWebFailureTurn = ConversationTurn(
  sequence: 1,
  userMessage: "明天北京天气如何",
  assistantMessage: legacyWebFailureText,
  status: .failed,
  errorMessage: legacyWebFailureText
)
let legacyWebFailureTask = AgentTask(
  title: "明天北京天气如何",
  mode: .plan,
  status: .failed,
  workspacePath: "/tmp/demo",
  turns: [legacyWebFailureTurn],
  activeTurnID: legacyWebFailureTurn.id
)
let legacyWebFailureEntries = AgentConversationPresentation.entries(for: legacyWebFailureTask)
expect(
  !legacyWebFailureEntries.contains { $0.text.contains("查询不能超过 500 个字符") },
  "旧版 Web Search 长 query 失败不能继续用红色长日志污染主对话"
)
expect(
  legacyWebFailureEntries.contains { $0.text.contains("旧版联网失败记录") },
  "旧版 Web Search 长 query 失败应折叠为可理解的历史失败提示"
)
expect(
  ConversationDisplayPolicy.shouldFollowStreamingText(previousID: "reply", previousText: "第一段", currentID: "reply", currentText: "第一段第二段"),
  "流式正文内容增长时，即使消息 ID 不变也必须触发自动滚动"
)
expect(
  AgentEvent(sessionID: turnTestSessionID, taskID: turnTestTaskID, sequence: 3, actor: "desktop", kind: .output).assigningTurn(firstTurn.id).turnID == firstTurn.id,
  "运行事件必须能够绑定到具体 Turn"
)
let thinkingOnlyEvent = AgentEvent(
  sessionID: turnTestSessionID,
  taskID: turnTestTaskID,
  turnID: firstTurn.id,
  sequence: 4,
  actor: "kimi-acp-host",
  kind: .output,
  payload: ["contentType": "thinking", "text": "分析中"]
)
let finalReplyEvent = AgentEvent(
  sessionID: turnTestSessionID,
  taskID: turnTestTaskID,
  turnID: firstTurn.id,
  sequence: 5,
  actor: "kimi-acp-host",
  kind: .output,
  payload: ["contentType": "text", "text": "已完成"]
)
expect(
  ConversationExecutionOutcome.resolve(exitCode: 0, events: [thinkingOnlyEvent], turnID: firstTurn.id) == .failed("模型未返回有效回复。"),
  "只有思考事件时不能把任务判定为成功"
)
expect(
  ConversationExecutionOutcome.resolve(exitCode: 0, events: [thinkingOnlyEvent, finalReplyEvent], turnID: firstTurn.id) == .completed,
  "待刷新的助手事件也必须能够完成任务"
)

// Harness v2 contract: malformed model tool calls must fail schema validation
// before permission evaluation or approval UI. This is intentionally placed in
// CoreChecks first so the implementation is driven by a regression contract.
let schemaProbe = InvocationCounter()
let schemaRegistry = ToolRegistry(definitions: [
  ToolDefinition(
    id: "write",
    title: "写入文件",
    description: "测试 Schema 顺序",
    permissionScopes: [.writeWorkspace],
    risk: .medium,
    inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#
  )
])
let schemaCoordinator = ToolExecutionCoordinator(
  registry: schemaRegistry,
  permissionResolver: StaticToolPermissionResolver(decision: .ask),
  approvalHandler: { _, _ in
    schemaProbe.increment()
    return .allow
  },
  journal: nil
)
let malformedRequest = ToolExecutionRequest(
  taskID: UUID(),
  sessionID: UUID(),
  operationID: UUID(),
  agentID: "test",
  toolID: "write",
  inputJSON: .object(["content": .string("missing path")])
)
let malformedResult = try awaitValue {
  do {
    _ = try await schemaCoordinator.execute(malformedRequest)
    return false
  } catch is ToolSchemaValidationError {
    return true
  } catch {
    return false
  }
}
expect(malformedResult, "无效 Tool Call 必须返回结构化 Schema 错误")
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

let traceRecorder = ProviderTraceRecorder()
let traceID = try awaitValue {
  await traceRecorder.start(
    request: HarnessConversationRequest(modelID: "kimi-k2", messages: [.user("搜索 Swift 6")]),
    tools: [ToolCatalog.defaultDefinitions.first { $0.id == "web.search" }!]
  )
}
try awaitValue {
  await traceRecorder.append(.toolCallDelta(id: "call-web", name: "web.search", argumentsDelta: ""))
  await traceRecorder.append(.toolCallDelta(id: "call-web", name: nil, argumentsDelta: #"{\"query\":\"Swift "#))
  await traceRecorder.append(.toolCallDelta(id: "call-web", name: nil, argumentsDelta: #"6\"}"#))
  await traceRecorder.finish(.toolCalls)
  return ()
}
let providerTrace = try awaitValue { await traceRecorder.record(id: traceID) }
expect(providerTrace?.blocks.count == 4, "Provider Trace 必须保留所有原始流式块")
let replayedEvents = ProviderReplayRunner.events(from: providerTrace!)
var replayAssembler = HarnessModelStreamAssembler()
replayedEvents.forEach { replayAssembler.push($0) }
expect(replayAssembler.toolCalls.first?.argumentsJSON == #"{\"query\":\"Swift 6\"}"#, "Provider Replay 必须正确恢复碎片化 Tool 参数")
let redactedTraceRecorder = ProviderTraceRecorder()
let redactedTraceID = try awaitValue {
  await redactedTraceRecorder.start(
    request: HarnessConversationRequest(modelID: "kimi-k2", messages: [.user("Authorization: Bearer sk-secret-token")]),
    tools: []
  )
}
try awaitValue {
  await redactedTraceRecorder.append(.text("api_key=super-secret"))
  await redactedTraceRecorder.finish(.stop)
  return ()
}
let redactedTrace = try awaitValue { await redactedTraceRecorder.record(id: redactedTraceID) }
let redactedTraceData = try JSONEncoder().encode(redactedTrace)
let redactedTraceText = String(data: redactedTraceData, encoding: .utf8) ?? ""
expect(!redactedTraceText.contains("sk-secret-token") && !redactedTraceText.contains("super-secret"), "Provider Trace 不得写入明文密钥")

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

final class AgentHostCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var envelopes: [AgentHostEnvelope] = []

  func append(_ envelope: AgentHostEnvelope) {
    lock.lock()
    envelopes.append(envelope)
    lock.unlock()
  }

  var receivedOutput: Bool {
    lock.lock()
    defer { lock.unlock() }
    return envelopes.contains { $0.event?.payload["text"] == "host-ready" }
  }
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

final class LockedStringCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
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
  KimiRuntimeEvent(sessionID: "session-1", kind: .assistantText, text: "桥接成功")
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
let idleMapped = KimiRuntimeEventBridge.map(KimiRuntimeEvent(sessionID: "s1", kind: .sessionIdle))
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
