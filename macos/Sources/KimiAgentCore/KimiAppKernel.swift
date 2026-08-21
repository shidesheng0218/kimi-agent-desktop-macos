import Foundation

/// The engine turn times out far beyond any realistic agentic run; the old
/// 300s ceiling failed long tasks while the engine kept executing in the
/// background, leaving UI and engine state permanently split.
public struct KimiDriverTimeoutError: Error, Sendable {
  public init() {}
}

public actor KimiRuntimeOperationDriver {
  private let client: any KimiRuntimeSessionClient
  private let completionTimeout: Duration
  private var sessionID: String?
  private var directory: String?
  private var modelID: String = KimiRuntimeIdentityStore.defaultModelID

  public init(client: any KimiRuntimeSessionClient, completionTimeout: Duration = .seconds(1_800)) {
    self.client = client
    self.completionTimeout = completionTimeout
  }

  public func setSession(_ sessionID: String, directory: String? = nil) {
    self.sessionID = sessionID
    self.directory = directory
  }

  public func setModel(_ modelID: String) {
    let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { self.modelID = trimmed }
  }

  public func run(
    context: HarnessOperationContext,
    sink: @escaping AgentHarness.DriverEventSink
  ) async throws {
    guard let sessionID else {
      throw KimiRuntimeError.requestFailed("当前没有可用的执行会话。")
    }
    let turnID = UUID()
    await sink(.turnStarted(HarnessTurnRecord(turnID: turnID, modelID: modelID)))
    await sink(.stepStarted(HarnessStepRecord(turnID: turnID, step: 1)))
    let events = try await client.subscribeEvents(sessionID: sessionID, directory: directory)
    try await client.prompt(KimiRuntimePromptInput(sessionID: sessionID, text: context.prompt.text, directory: directory, modelID: modelID))
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await Self.waitForCompletion(events, timeout: self.completionTimeout) }
        group.addTask { try await self.pumpSteering(context: context, sessionID: sessionID) }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    } catch is KimiDriverTimeoutError {
      // A timed-out Harness operation must not leave the engine turn running
      // detached; abort it so both sides agree the turn is over.
      try? await client.abort(sessionID: sessionID, directory: directory)
      throw KimiRuntimeError.requestFailed("执行会话在规定时间内没有进入空闲。")
    }
    await sink(.stepEnded(HarnessStepRecord(turnID: turnID, step: 1, status: .completed)))
    await sink(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: modelID, status: .completed)))
  }

  /// Drains Harness steering input into the running engine session. A prompt
  /// sent while the session is busy is admitted by the engine's loop on its
  /// next iteration, which provides the steer semantics the Harness queue
  /// was designed for but never delivered to.
  private func pumpSteering(context: HarnessOperationContext, sessionID: String) async throws {
    while !Task.isCancelled {
      let steering = await context.takeSteering()
      for input in steering where !input.text.isEmpty {
        try? await client.prompt(KimiRuntimePromptInput(sessionID: sessionID, text: input.text, directory: directory, modelID: modelID))
      }
      try await Task.sleep(for: .milliseconds(300))
    }
  }

  private static func waitForCompletion(
    _ events: AsyncThrowingStream<KimiRuntimeEvent, Error>,
    timeout: Duration
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await event in events {
          switch event.kind {
          case .sessionIdle:
            return
          case .sessionStatus:
            if event.payload["statusType"] == "idle" { return }
          case .error:
            throw KimiRuntimeError.requestFailed(event.text ?? "执行会话失败。")
          default:
            continue
          }
        }
        throw KimiRuntimeError.requestFailed("执行会话事件流在完成前中断。")
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw KimiDriverTimeoutError()
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }
}

/// The native application owns the UI projection and sends all user intent
/// through this actor. The embedded engine remains the headless execution service; the
/// Harness records the operation boundary and provides recovery semantics.
public actor KimiAppKernel {
  private let sessionClient: any KimiRuntimeSessionClient
  private let runtimeSupervisor: KimiRuntimeSupervisor?
  private let operationDriver: KimiRuntimeOperationDriver
  private let harness: AgentHarness
  private let stateStore: KimiAppStateStore?
  private let harnessStore: HarnessEventStore?
  private let activityStats: KimiActivityStatsStore?
  private let runtimeConfigurationProvider: (@Sendable (_ modelID: String, _ catalog: [String]) -> KimiRuntimeConfiguration?)?
  private let harnessSessionID: UUID
  private var state: KimiUIState
  private var operationSessions: [OperationID: String] = [:]
  private var sessionOperations: [String: OperationID] = [:]
  private var permissionOperations: [UUID: OperationID] = [:]
  private var effectByToolCall: [String: UUID] = [:]
  private var eventTasks: [String: Task<Void, Never>] = [:]
  private var eventTaskTokens: [String: UUID] = [:]
  private var reconnectAttempts: [String: Int] = [:]
  private var supervisorStateTask: Task<Void, Never>?
  private var continuations: [UUID: AsyncStream<KimiEvent>.Continuation] = [:]
  /// assistantText arrives per streaming delta; only the first delta of a
  /// turn counts as one reply in the activity statistics.
  private var replyCountedThisTurn = false
  private var reasoningActivityByPart: [String: UUID] = [:]
  private var recordedAssistantTurns: Set<UUID> = []
  /// Sessions the user deliberately aborted; the engine's resulting error
  /// frame is expected and must not surface as a red error banner.
  private var recentlyAbortedSessions: Set<String> = []
  private var lastTextPersistAt: Date = .distantPast

  public init(
    sessionClient: any KimiRuntimeSessionClient = UnavailableKimiRuntimeSessionClient(),
    runtimeSupervisor: KimiRuntimeSupervisor? = nil,
    sessionID: UUID = UUID(),
    persistence: KimiAppStateStore? = nil,
    harnessStore: HarnessEventStore? = nil,
    activityStats: KimiActivityStatsStore? = nil,
    runtimeConfigurationProvider: (@Sendable (_ modelID: String, _ catalog: [String]) -> KimiRuntimeConfiguration?)? = nil,
    modelCatalog: [String]? = nil
  ) {
    self.sessionClient = sessionClient
    self.runtimeSupervisor = runtimeSupervisor
    self.stateStore = persistence
    self.harnessStore = harnessStore
    self.activityStats = activityStats
    self.runtimeConfigurationProvider = runtimeConfigurationProvider
    let restored = persistence.flatMap { try? $0.load() }
    let resolvedHarnessSessionID = restored?.harnessSessionID ?? sessionID
    self.harnessSessionID = resolvedHarnessSessionID
    let driver = KimiRuntimeOperationDriver(client: sessionClient)
    self.operationDriver = driver
    self.harness = AgentHarness(
      sessionID: resolvedHarnessSessionID,
      store: harnessStore ?? HarnessEventStore(),
      driver: { context, sink in
        try await driver.run(context: context, sink: sink)
      }
    )
    var restoredState = restored?.uiState ?? KimiUIState()
    if let modelCatalog, !modelCatalog.isEmpty {
      restoredState.modelCatalog = modelCatalog
      if !modelCatalog.contains(restoredState.selectedModel) {
        restoredState.selectedModel = modelCatalog[0]
      }
    }
    self.state = restoredState
  }

  public func snapshot() -> KimiUIState {
    state
  }

  /// Dashboard statistics computed from the recorded Harness event log.
  public func usageStats(range: KimiUsageStatsRange = .all) async -> KimiUsageStats {
    guard let harnessStore else { return KimiUsageStats() }
    return await KimiUsageStatsComputer.compute(events: harnessStore.allEvents(), range: range)
  }

  /// Home-dashboard numbers merged from every real signal the app records.
  public func homeStats(range: KimiUsageStatsRange = .all) async -> KimiHomeStats {
    let records = await activityStats?.records() ?? []
    let activity = KimiActivityAggregator.aggregate(
      records: records,
      sessions: state.sessions,
      rangeDays: range.days
    )
    let usage = await usageStats(range: range)
    var home = KimiHomeStats()
    if let days = range.days, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) {
      home.sessionCount = state.sessions.filter { $0.updatedAt >= cutoff }.count
    } else {
      home.sessionCount = state.sessions.count
    }
    // The activity log and the Harness log both count user/assistant turns;
    // take the larger so a gap in either source never under-reports.
    home.messageCount = max(activity.messageCount, usage.totalMessages)
    home.toolCallCount = usage.totalToolCalls
    home.activeDays = activity.activeDays
    home.currentStreak = activity.currentStreak
    home.longestStreak = activity.longestStreak
    home.peakHour = activity.peakHour ?? usage.peakHour
    home.favoriteModel = usage.favoriteModel ?? state.selectedModel
    home.dailyCounts = activity.dailyCounts
    home.modelUsage = usage.modelUsage
    return home
  }

  public func events() -> AsyncStream<KimiEvent> {
    let token = UUID()
    return AsyncStream { continuation in
      continuations[token] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(token) }
      }
    }
  }

  public func startRuntime() async {
    try? await harness.restore()
    // Engine permission requests live only inside the engine process and the
    // in-memory operation mapping dies with the app, so a restored approval
    // card could never be answered. Drop it instead of leaving a dead button.
    state.pendingPermissions.removeAll()
    state.pendingQuestions.removeAll()
    state.busySessionIDs.removeAll()
    guard let runtimeSupervisor else {
      state.runtimeState = .degraded
      state.lastError = "后台执行引擎尚未打包或未配置。"
      publish(.runtimeChanged(.degraded))
      publish(.error(state.lastError ?? "后台执行引擎尚未连接。"))
      persistState()
      return
    }
    observeSupervisor(runtimeSupervisor)
    do {
      _ = try await runtimeSupervisor.start()
      try await runtimeSupervisor.waitUntilReady()
      state.runtimeState = .ready
      state.lastError = nil
      publish(.runtimeChanged(.ready))
      await restoreRuntimeSessions()
      await rewatchAllSessions()
      if let activeID = state.activeSessionID,
         let runtimeID = state.sessions.first(where: { $0.id == activeID })?.runtimeID {
        await loadHistory(sessionID: runtimeID)
      }
      await refreshModelCatalog()
      if let commands = try? await sessionClient.fetchCommands(directory: nil), !commands.isEmpty {
        state.availableCommands = commands
      }
      persistState()
    } catch {
      state.runtimeState = .failed
      state.lastError = error.localizedDescription
      publish(.error(error.localizedDescription))
      persistState()
    }
  }

  public func send(_ command: KimiAppCommand) async throws {
    switch command {
    case let .createSession(directory):
      let resolvedDirectory = directory ?? state.recentProjects.first
      let session = try await sessionClient.createSession(CreateSessionInput(directory: resolvedDirectory))
      let summary = KimiSessionSummary(id: UUID(), runtimeID: session.id, title: session.title ?? "新会话", projectPath: session.directory ?? resolvedDirectory)
      state.sessions.insert(summary, at: 0)
      state.activeSessionID = summary.id
      state.messages.removeAll()
      state.activities.removeAll()
      state.todos.removeAll()
      state.todosSessionID = nil
      recordRecentProject(summary.projectPath)
      await activityStats?.record(KimiActivityRecord(kind: .sessionCreated, project: summary.projectPath))
      try await watch(sessionID: session.id)
      publish(.sessionChanged(summary))

    case let .selectSession(id):
      guard state.sessions.contains(where: { $0.id == id }) else { return }
      state.activeSessionID = id
      state.messages.removeAll()
      state.activities.removeAll()
      state.todos.removeAll()
      state.todosSessionID = nil
      let runtimeID = state.sessions.first(where: { $0.id == id })?.runtimeID ?? id.uuidString
      try await watch(sessionID: runtimeID)
      await loadHistory(sessionID: runtimeID)

    case .showHome:
      state.activeSessionID = nil
      state.messages.removeAll()
      state.activities.removeAll()
      state.todos.removeAll()
      state.todosSessionID = nil

    case let .prompt(input):
      let session = try await ensureActiveSession()
      await operationDriver.setSession(session.id, directory: session.directory)
      await operationDriver.setModel(state.selectedModel)
      state.messages.append(KimiMessage(role: .user, text: input.text))
      publish(.userText(input.text))
      replyCountedThisTurn = false
      await activityStats?.record(KimiActivityRecord(kind: .promptSent, project: session.directory))
      let operationID = try await harness.prompt(input)
      operationSessions[operationID] = session.id
      sessionOperations[session.id] = operationID
      state.runtimeState = .ready
      state.lastError = nil

    case let .steer(input):
      let laneBusy = await harness.snapshot().lanes[.main]?.activeOperation != nil
      // Steering an idle lane is a new turn, not an intervention; route it to
      // the normal prompt path so the UI never loses a message.
      guard laneBusy else {
        try await send(.prompt(input))
        return
      }
      let session = try await ensureActiveSession()
      await operationDriver.setSession(session.id, directory: session.directory)
      state.messages.append(KimiMessage(role: .user, text: input.text))
      publish(.userText(input.text))
      try await harness.steer(input, lane: .main)

    case let .followUp(input):
      let laneBusy = await harness.snapshot().lanes[.main]?.activeOperation != nil
      guard laneBusy else {
        try await send(.prompt(input))
        return
      }
      let session = try await ensureActiveSession()
      await operationDriver.setSession(session.id, directory: session.directory)
      state.messages.append(KimiMessage(role: .user, text: input.text))
      publish(.userText(input.text))
      try await harness.followUp(input, lane: .main)

    case let .abort(operationID):
      if let sessionID = operationSessions[operationID] {
        recentlyAbortedSessions.insert(sessionID)
        try await sessionClient.abort(sessionID: sessionID, directory: directoryForSession(sessionID))
      }
      await harness.abort(operationID)

    case let .approve(permissionID):
      await respondToPermission(permissionID, reply: "once")

    case let .approveAlways(permissionID):
      await respondToPermission(permissionID, reply: "always")

    case let .deny(permissionID):
      await respondToPermission(permissionID, reply: "reject")

    case let .answerQuestion(requestID, answers):
      await respondToQuestion(requestID, answers: answers)

    case let .rejectQuestion(requestID):
      await respondToQuestion(requestID, answers: nil)

    case .revertLastTurn:
      guard let activeID = state.activeSessionID,
            let session = state.sessions.first(where: { $0.id == activeID }) else { break }
      let runtimeID = session.runtimeID ?? session.id.uuidString
      guard !state.busySessionIDs.contains(runtimeID) else {
        state.lastError = "执行中的会话不能撤销，请先停止。"
        publish(.error(state.lastError ?? "执行中的会话不能撤销。"))
        break
      }
      guard let messageID = state.lastUserMessageIDBySession[runtimeID] else {
        state.lastError = "当前会话还没有可撤销的用户消息。"
        publish(.error(state.lastError ?? "当前会话还没有可撤销的用户消息。"))
        break
      }
      do {
        try await sessionClient.revert(sessionID: runtimeID, messageID: messageID, directory: directoryForSession(runtimeID))
        if !state.revertedSessionIDs.contains(runtimeID) { state.revertedSessionIDs.append(runtimeID) }
        state.messages.append(KimiMessage(role: .system, text: "已撤销最近一轮的文件改动。选择“恢复撤销”可以还原。"))
        await loadHistory(sessionID: runtimeID)
      } catch {
        state.lastError = "撤销失败：\(error.localizedDescription)"
        publish(.error(state.lastError ?? "撤销失败。"))
      }

    case .unrevert:
      guard let activeID = state.activeSessionID,
            let session = state.sessions.first(where: { $0.id == activeID }) else { break }
      let runtimeID = session.runtimeID ?? session.id.uuidString
      do {
        try await sessionClient.unrevert(sessionID: runtimeID, directory: directoryForSession(runtimeID))
        state.revertedSessionIDs.removeAll { $0 == runtimeID }
        await loadHistory(sessionID: runtimeID)
      } catch {
        state.lastError = "恢复撤销失败：\(error.localizedDescription)"
        publish(.error(state.lastError ?? "恢复撤销失败。"))
      }

    case let .runSlashCommand(name, arguments):
      let session = try await ensureActiveSession()
      state.messages.append(KimiMessage(role: .user, text: "/\(name)\(arguments.isEmpty ? "" : " \(arguments)")"))
      do {
        try await sessionClient.runCommand(sessionID: session.id, command: name, arguments: arguments, directory: session.directory)
      } catch {
        state.lastError = "命令执行失败：\(error.localizedDescription)"
        publish(.error(state.lastError ?? "命令执行失败。"))
      }

    case .compact:
      guard let activeID = state.activeSessionID,
            let session = state.sessions.first(where: { $0.id == activeID }) else { break }
      let runtimeID = session.runtimeID ?? session.id.uuidString
      do {
        try await sessionClient.summarize(sessionID: runtimeID, modelID: state.selectedModel, directory: directoryForSession(runtimeID))
        state.activities.append(KimiActivity(title: "压缩上下文", detail: "已请求引擎压缩会话上下文。", state: .running))
      } catch {
        state.lastError = "压缩上下文失败：\(error.localizedDescription)"
        publish(.error(state.lastError ?? "压缩上下文失败。"))
      }

    case .retry:
      state.lastError = nil

    case .resume:
      try await harness.resume(.main)

    case .openTerminal:
      state.activePane = .conversation

    case .openDiff:
      state.activePane = .diff

    case .openBrowser:
      state.activePane = .browser

    case .openFile:
      state.activePane = .files

    case let .changeModel(model):
      let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed != state.selectedModel else { break }
      state.selectedModel = trimmed
      publish(.modelChanged(trimmed))
      // Apply immediately when the app supplied a configuration provider:
      // the engine reads its model from the launch-time config, so a model
      // change means reconfiguring and relaunching the runtime in place.
      if let runtimeSupervisor, let runtimeConfigurationProvider,
         let configuration = runtimeConfigurationProvider(trimmed, state.modelCatalog) {
        state.runtimeState = .starting
        publish(.runtimeChanged(.starting))
        do {
          try await runtimeSupervisor.reconfigure(configuration)
          state.runtimeState = .ready
          state.lastError = nil
          publish(.runtimeChanged(.ready))
          await restoreRuntimeSessions()
          await rewatchAllSessions()
        } catch {
          state.runtimeState = .failed
          state.lastError = error.localizedDescription
          publish(.runtimeChanged(.failed))
          publish(.error(error.localizedDescription))
        }
      } else {
        persistState()
      }

    case let .changeThinkingEffort(effort):
      let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, trimmed != state.thinkingEffort else { break }
      state.thinkingEffort = trimmed
      persistState()

    case .restartRuntime:
      if let runtimeSupervisor {
        _ = try await runtimeSupervisor.restart()
        try await runtimeSupervisor.waitUntilReady()
      }
      state.runtimeState = .ready
      state.lastError = nil
      publish(.runtimeChanged(.ready))
      await restoreRuntimeSessions()
      await rewatchAllSessions()
    }
    persistState()
  }

  /// Interrupts the turn running in the visible session. Works even when the
  /// operation mapping was lost (e.g. after a restart) by falling back to a
  /// plain engine abort for the session.
  public func abortActiveSession() async {
    guard let activeID = state.activeSessionID,
          let session = state.sessions.first(where: { $0.id == activeID }) else { return }
    let runtimeID = session.runtimeID ?? session.id.uuidString
    recentlyAbortedSessions.insert(runtimeID)
    if let operationID = sessionOperations[runtimeID] {
      try? await sessionClient.abort(sessionID: runtimeID, directory: directoryForSession(runtimeID))
      await harness.abort(operationID)
    } else {
      try? await sessionClient.abort(sessionID: runtimeID, directory: directoryForSession(runtimeID))
    }
    apply(.sessionBusy(sessionID: runtimeID, isBusy: false))
    publish(.sessionBusy(sessionID: runtimeID, isBusy: false))
    persistState()
  }

  private func ensureActiveSession() async throws -> KimiRuntimeSession {
    if let activeID = state.activeSessionID,
       let existing = state.sessions.first(where: { $0.id == activeID }) {
      return KimiRuntimeSession(id: existing.runtimeID ?? existing.id.uuidString, title: existing.title, directory: existing.projectPath)
    }
    guard let directory = state.recentProjects.first else {
      throw KimiRuntimeError.requestFailed("请先选择项目文件夹，再开始任务。")
    }
    let created = try await sessionClient.createSession(CreateSessionInput(directory: directory))
    let summary = KimiSessionSummary(id: UUID(), runtimeID: created.id, title: created.title ?? "新会话", projectPath: created.directory ?? directory)
    state.sessions.insert(summary, at: 0)
    state.activeSessionID = summary.id
    recordRecentProject(summary.projectPath)
    try await watch(sessionID: created.id)
    return created
  }

  private func recordRecentProject(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    state.recentProjects.removeAll { $0 == path }
    state.recentProjects.insert(path, at: 0)
    if state.recentProjects.count > 10 {
      state.recentProjects = Array(state.recentProjects.prefix(10))
    }
  }

  /// Rebuilds the conversation from the engine's durable message log. The
  /// local projection is intentionally replaced, not merged: the engine is
  /// the authoritative store, and live deltas re-attach by part identifier.
  private func loadHistory(sessionID: String) async {
    guard let history = try? await sessionClient.fetchMessages(sessionID: sessionID, directory: directoryForSession(sessionID)),
          !history.isEmpty else { return }
    var messages: [KimiMessage] = []
    var activities: [KimiActivity] = []
    for message in history {
      let createdAt = message.createdAt ?? .now
      if message.role == "user" {
        let text = message.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        if !text.isEmpty {
          messages.append(KimiMessage(role: .user, text: text, createdAt: createdAt))
        }
        continue
      }
      for part in message.parts {
        switch part.type {
        case "text":
          if let text = part.text, !text.isEmpty {
            messages.append(KimiMessage(role: .assistant, text: text, runtimePartID: part.partID, createdAt: createdAt))
          }
        case "tool":
          let failed = part.status == "failed" || part.status == "error"
          activities.append(KimiActivity(
            title: part.toolName ?? "工具活动",
            detail: part.output.map { String($0.prefix(4_000)) },
            state: failed ? .failed : .completed,
            toolCallID: part.callID,
            createdAt: createdAt,
            updatedAt: createdAt
          ))
        default:
          continue
        }
      }
    }
    state.messages = messages
    state.activities = activities
    state.lastUserMessageIDBySession[sessionID] = history.last(where: { $0.role == "user" })?.id
    if let todos = try? await sessionClient.fetchTodos(sessionID: sessionID, directory: directoryForSession(sessionID)) {
      state.todos = todos
      state.todosSessionID = sessionID
    }
  }

  /// Pulls the model catalog from the engine's provider listing. When the
  /// catalog changed (e.g. first launch after an upgrade), the runtime is
  /// reconfigured in place so the injected provider table covers every
  /// selectable model; the loopback endpoint survives the swap.
  private func refreshModelCatalog() async {
    guard let catalog = try? await sessionClient.fetchModelCatalog(directory: nil), !catalog.isEmpty else { return }
    guard Set(catalog) != Set(state.modelCatalog) else { return }
    state.modelCatalog = catalog
    if !catalog.contains(state.selectedModel), let first = catalog.first {
      state.selectedModel = first
    }
    await operationDriver.setModel(state.selectedModel)
    if let runtimeSupervisor, let runtimeConfigurationProvider,
       let configuration = runtimeConfigurationProvider(state.selectedModel, catalog) {
      state.runtimeState = .starting
      publish(.runtimeChanged(.starting))
      do {
        try await runtimeSupervisor.reconfigure(configuration)
        state.runtimeState = .ready
        state.lastError = nil
        publish(.runtimeChanged(.ready))
        await restoreRuntimeSessions()
        await rewatchAllSessions()
      } catch {
        state.runtimeState = .failed
        state.lastError = error.localizedDescription
        publish(.runtimeChanged(.failed))
        publish(.error(error.localizedDescription))
      }
    }
    persistState()
  }

  private func restoreRuntimeSessions() async {
    guard let sessions = try? await sessionClient.listSessions(directory: nil) else { return }
    for session in sessions {
      if let index = state.sessions.firstIndex(where: { $0.runtimeID == session.id }) {
        state.sessions[index].title = session.title ?? state.sessions[index].title
        state.sessions[index].projectPath = session.directory ?? state.sessions[index].projectPath
        state.sessions[index].updatedAt = .now
      } else {
        state.sessions.append(KimiSessionSummary(
          runtimeID: session.id,
          title: session.title ?? "新会话",
          projectPath: session.directory
        ))
      }
    }
    // Restoring sessions must not auto-open one: the app launches into the
    // home dashboard and the user explicitly picks where to continue.
    state.sessions.sort { $0.updatedAt > $1.updatedAt }
  }

  private func watch(sessionID: String) async throws {
    guard eventTasks[sessionID] == nil else { return }
    let stream = try await sessionClient.subscribeEvents(sessionID: sessionID, directory: directoryForSession(sessionID))
    let token = UUID()
    eventTaskTokens[sessionID] = token
    eventTasks[sessionID] = Task { [weak self] in
      do {
        for try await event in stream {
          await self?.ingest(event)
        }
      } catch {
        await self?.ingest(KimiRuntimeEvent(sessionID: sessionID, kind: .error, text: error.localizedDescription))
      }
      await self?.eventStreamDidEnd(sessionID: sessionID, token: token)
    }
  }

  /// A stream that ends while the engine stays healthy is a dropped
  /// connection, not a state change: re-subscribe with exponential backoff
  /// instead of leaving the session deaf to assistant text and approvals.
  private func eventStreamDidEnd(sessionID: String, token: UUID) {
    guard eventTaskTokens[sessionID] == token else { return }
    eventTasks.removeValue(forKey: sessionID)
    eventTaskTokens.removeValue(forKey: sessionID)
    guard state.runtimeState == .ready,
          state.sessions.contains(where: { $0.runtimeID == sessionID }) else { return }
    let attempt = (reconnectAttempts[sessionID] ?? 0) + 1
    reconnectAttempts[sessionID] = attempt
    guard attempt <= 12 else { return }
    let delay = min(pow(2.0, Double(attempt - 1)) * 0.5, 20.0)
    let retryToken = UUID()
    eventTaskTokens[sessionID] = retryToken
    eventTasks[sessionID] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      await self?.retryWatch(sessionID: sessionID, token: retryToken)
    }
  }

  private func retryWatch(sessionID: String, token: UUID) async {
    guard eventTaskTokens[sessionID] == token else { return }
    eventTasks.removeValue(forKey: sessionID)
    eventTaskTokens.removeValue(forKey: sessionID)
    try? await watch(sessionID: sessionID)
    await resyncSessionStatuses()
  }

  /// A reconnect happens precisely because at least one frame may have been
  /// dropped; if that frame was the turn-completion signal the busy marker
  /// would otherwise stick forever. Reconcile against the engine's own
  /// status map after every (re)subscription wave.
  private func resyncSessionStatuses() async {
    guard let statuses = try? await sessionClient.fetchSessionStatuses(directory: nil) else { return }
    for session in state.sessions {
      guard let runtimeID = session.runtimeID else { continue }
      let engineBusy = statuses[runtimeID].map { $0 != "idle" } ?? false
      let locallyBusy = state.busySessionIDs.contains(runtimeID)
      if !engineBusy, locallyBusy {
        apply(.sessionBusy(sessionID: runtimeID, isBusy: false))
        publish(.sessionBusy(sessionID: runtimeID, isBusy: false))
      } else if engineBusy, !locallyBusy {
        apply(.sessionBusy(sessionID: runtimeID, isBusy: true))
        publish(.sessionBusy(sessionID: runtimeID, isBusy: true))
      }
    }
    persistState()
  }

  private func rewatchAllSessions() async {
    for task in eventTasks.values { task.cancel() }
    eventTasks.removeAll()
    eventTaskTokens.removeAll()
    reconnectAttempts.removeAll()
    for session in state.sessions {
      guard let runtimeID = session.runtimeID else { continue }
      try? await watch(sessionID: runtimeID)
    }
    await resyncSessionStatuses()
  }

  private func observeSupervisor(_ runtimeSupervisor: KimiRuntimeSupervisor) {
    guard supervisorStateTask == nil else { return }
    supervisorStateTask = Task { [weak self] in
      let stream = await runtimeSupervisor.stateChanges()
      for await runtimeState in stream {
        await self?.handleRuntimeStateChange(runtimeState)
      }
    }
  }

  private func handleRuntimeStateChange(_ runtimeState: KimiRuntimeState) async {
    state.runtimeState = runtimeState
    publish(.runtimeChanged(runtimeState))
    // The supervisor recovers a crashed engine on the same endpoint; once it
    // is healthy again every session stream must be re-established, because
    // SSE connections do not survive the process swap.
    if runtimeState == .ready {
      await restoreRuntimeSessions()
      await rewatchAllSessions()
      if let activeID = state.activeSessionID,
         let runtimeID = state.sessions.first(where: { $0.id == activeID })?.runtimeID {
        await loadHistory(sessionID: runtimeID)
      }
    }
    persistState()
  }

  private func directoryForSession(_ runtimeID: String) -> String? {
    state.sessions.first(where: { $0.runtimeID == runtimeID })?.projectPath
  }

  private func ingest(_ event: KimiRuntimeEvent) async {
    if event.kind == .error, recentlyAbortedSessions.remove(event.sessionID) != nil {
      return
    }
    // message.updated for a user message carries the durable engine message
    // identifier that revert targets; capture it before mapping drops it.
    if event.kind == .userText, let messageID = event.messageID {
      state.lastUserMessageIDBySession[event.sessionID] = messageID
    }
    await recordKimiRuntimeEvent(event)
    var persistImmediately = true
    for mapped in KimiRuntimeEventBridge.map(event) {
      apply(mapped)
      publish(mapped)
      if case .assistantText = mapped { persistImmediately = false }
      if case .reasoningText = mapped { persistImmediately = false }
    }
    // Streaming deltas arrive at frame rate; persisting the whole state JSON
    // for each of them would dominate CPU. Bound those writes while keeping
    // every structural event (idle, tools, permissions) durable immediately.
    if persistImmediately || Date().timeIntervalSince(lastTextPersistAt) > 0.5 {
      persistState()
      lastTextPersistAt = .now
    }
  }

  private func apply(_ event: KimiEvent) {
    switch event {
    case let .runtimeChanged(runtime):
      state.runtimeState = runtime
    case let .modelChanged(model):
      state.selectedModel = model
    case let .sessionChanged(summary):
      if let index = state.sessions.firstIndex(where: { $0.id == summary.id }) { state.sessions[index] = summary }
      else { state.sessions.insert(summary, at: 0) }
    case let .userText(text):
      state.messages.append(KimiMessage(role: .user, text: text))
    case let .assistantText(text, partID, isSnapshot):
      if !text.isEmpty, !replyCountedThisTurn {
        replyCountedThisTurn = true
        let stats = activityStats
        Task { await stats?.record(KimiActivityRecord(kind: .replyReceived)) }
      }
      if let partID, let index = state.messages.lastIndex(where: { $0.role == .assistant && $0.runtimePartID == partID }) {
        state.messages[index].text = isSnapshot ? text : state.messages[index].text + text
        state.messages[index].isStreaming = true
      } else if partID == nil, let index = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
        state.messages[index].text += text
      } else {
        state.messages.append(KimiMessage(role: .assistant, text: text, isStreaming: true, runtimePartID: partID))
      }
    case let .reasoningText(text, partID, isSnapshot):
      let key = partID ?? "default"
      if let activityID = reasoningActivityByPart[key],
         let index = state.activities.firstIndex(where: { $0.id == activityID }) {
        state.activities[index].detail = isSnapshot ? text : (state.activities[index].detail ?? "") + text
        state.activities[index].updatedAt = .now
      } else {
        let activity = KimiActivity(
          title: "思考过程",
          detail: text,
          state: .running,
          toolCallID: "reasoning|\(key)"
        )
        reasoningActivityByPart[key] = activity.id
        state.activities.append(activity)
      }
    case let .sessionBusy(sessionID, isBusy):
      if isBusy {
        if !state.busySessionIDs.contains(sessionID) { state.busySessionIDs.append(sessionID) }
      } else {
        state.busySessionIDs.removeAll { $0 == sessionID }
        sealStreamingContent()
      }
    case let .todoUpdated(sessionID, todos):
      state.todos = todos
      state.todosSessionID = sessionID
    case let .questionAsked(request):
      // The engine re-emits asked events for an already-answered request;
      // identity is the engine requestID, not the per-event UUID.
      if let runtimeID = request.runtimeID,
         state.pendingQuestions.contains(where: { $0.runtimeID == runtimeID }) { break }
      if !state.pendingQuestions.contains(where: { $0.id == request.id }) {
        state.pendingQuestions.append(request)
      }
    case let .permissionSettled(requestID):
      state.pendingPermissions.removeAll { $0.runtimeID == requestID }
    case let .questionSettled(requestID):
      state.pendingQuestions.removeAll { $0.runtimeID == requestID }
    case let .activity(activity):
      if let index = state.activities.firstIndex(where: { $0.toolCallID == activity.toolCallID && activity.toolCallID != nil }) {
        state.activities[index] = activity
      } else { state.activities.append(activity) }
    case let .permission(permission):
      // The engine re-emits permission.asked after a reply; without dedupe by
      // engine requestID the second emission becomes an unanswerable zombie
      // card that keeps the turn-looking busy to the user.
      if let runtimeID = permission.runtimeID,
         state.pendingPermissions.contains(where: { $0.runtimeID == runtimeID }) { break }
      if !state.pendingPermissions.contains(where: { $0.id == permission.id }) { state.pendingPermissions.append(permission) }
    case let .error(message):
      state.lastError = message
    }
  }

  /// A finished turn seals every open stream: bubbles stop glowing and
  /// reasoning cards settle, regardless of which frame happened to arrive last.
  private func sealStreamingContent() {
    for index in state.messages.indices where state.messages[index].isStreaming {
      state.messages[index].isStreaming = false
    }
    for activityID in reasoningActivityByPart.values {
      if let index = state.activities.firstIndex(where: { $0.id == activityID && $0.state == .running }) {
        state.activities[index].state = .completed
        state.activities[index].updatedAt = .now
      }
    }
  }

  private func respondToQuestion(_ id: UUID, answers: [[String]]?) async {
    guard let request = state.pendingQuestions.first(where: { $0.id == id }) else { return }
    guard let runtimeID = request.runtimeID else {
      state.pendingQuestions.removeAll { $0.id == id }
      return
    }
    do {
      if let answers {
        try await sessionClient.answerQuestion(requestID: runtimeID, answers: answers, directory: directoryForSession(request.sessionID))
      } else {
        try await sessionClient.rejectQuestion(requestID: runtimeID, directory: directoryForSession(request.sessionID))
      }
      state.pendingQuestions.removeAll { $0.id == id }
    } catch {
      state.lastError = "问题回复发送失败：\(error.localizedDescription)"
      publish(.error(state.lastError ?? "问题回复发送失败。"))
    }
    persistState()
  }

  private func respondToPermission(_ id: UUID, reply: String) async {
    guard let permission = state.pendingPermissions.first(where: { $0.id == id }) else { return }
    guard let operationID = permissionOperations[id], let sessionID = operationSessions[operationID] else {
      state.pendingPermissions.removeAll { $0.id == id }
      state.lastError = "该审批请求已过期，请重新发起操作。"
      publish(.error(state.lastError ?? "该审批请求已过期。"))
      persistState()
      return
    }
    do {
      try await sessionClient.respondPermission(PermissionResponse(
        sessionID: sessionID,
        requestID: permission.runtimeID ?? permission.id.uuidString,
        reply: reply,
        directory: directoryForSession(sessionID)
      ))
    } catch {
      // The engine re-emits asked events for answered requests; a reply that
      // fails means the card references something that no longer exists
      // engine-side. Remove it so it never sits as a dead button, and say so.
      state.pendingPermissions.removeAll { $0.id == id }
      permissionOperations.removeValue(forKey: id)
      state.lastError = "审批回复失败（请求可能已过期）：\(error.localizedDescription)"
      publish(.error(state.lastError ?? "审批回复失败。"))
      persistState()
      return
    }
    state.pendingPermissions.removeAll { $0.id == id }
    let decision: PermissionDecision = reply == "reject" ? .deny : .allow
    await harness.record(
      .permissionSettled(HarnessPermissionReceipt(
        operationID: operationID,
        requestID: id,
        toolID: permission.toolID,
        decision: decision
      )),
      operationID: operationID
    )
    permissionOperations.removeValue(forKey: id)
    persistState()
  }

  private func recordKimiRuntimeEvent(_ event: KimiRuntimeEvent) async {
    guard let operationID = sessionOperations[event.sessionID] else { return }
    let snapshot = await harness.snapshot()
    let checkpoint = snapshot.checkpoints[operationID]
    let turnID = checkpoint?.turnID ?? UUID()
    let step = checkpoint?.step ?? 1
    switch event.kind {
    case .sessionIdle, .sessionStatus:
      let isIdle = event.kind == .sessionIdle || event.payload["statusType"] == "idle"
      // One assistantMessage record per completed turn feeds the dashboard's
      // model-usage distribution; both idle frame shapes map to the same turn.
      guard isIdle, !recordedAssistantTurns.contains(turnID) else { return }
      if recordedAssistantTurns.count > 256 { recordedAssistantTurns.removeAll() }
      recordedAssistantTurns.insert(turnID)
      await harness.record(
        .assistantMessage(HarnessAssistantMessageRecord(
          turnID: turnID,
          step: step,
          message: .assistant(""),
          modelID: state.selectedModel
        )),
        operationID: operationID
      )
    case .permissionAsked:
      permissionOperations[event.id] = operationID
    case .toolCall:
      let callID = event.toolCallID ?? event.id.uuidString
      let toolName = event.toolID ?? "unknown"
      let call = HarnessToolCall(
        id: callID,
        name: toolName,
        argumentsJSON: event.payload["arguments"] ?? "{}"
      )
      await harness.record(.toolCallDeclared(HarnessToolCallRecord(turnID: turnID, step: step, call: call)), operationID: operationID)
      let key = "\(operationID.uuidString)|\(callID)"
      if effectByToolCall[key] == nil {
        let intent = HarnessEffectIntent(
          operationID: operationID,
          kind: .tool,
          subject: toolName,
          risk: Self.toolRisk(for: toolName),
          inputDigest: HarnessDigest.sha256(call.argumentsJSON)
        )
        effectByToolCall[key] = intent.effectID
        await harness.record(.effectIntentWritten(intent), operationID: operationID)
        await harness.record(.effectStarted(intent), operationID: operationID)
      }
    case .toolResult:
      let callID = event.toolCallID ?? event.id.uuidString
      let toolName = event.toolID ?? "unknown"
      let result = HarnessToolResult(
        callID: callID,
        toolName: toolName,
        output: event.text ?? "",
        isError: event.payload["status"]?.lowercased() == "failed" || event.payload["error"] != nil
      )
      await harness.record(.toolResultRecorded(HarnessToolResultRecord(turnID: turnID, step: step, result: result)), operationID: operationID)
      let key = "\(operationID.uuidString)|\(callID)"
      if let effectID = effectByToolCall.removeValue(forKey: key) {
        let receipt = HarnessEffectReceipt(
          operationID: operationID,
          effectID: effectID,
          outcome: result.isError ? .failure : .success,
          output: result.output,
          errorMessage: result.isError ? result.output : nil,
          retryable: result.isError && Self.toolRisk(for: toolName) == .low
        )
        await harness.record(.effectSettled(receipt), operationID: operationID)
      }
    default:
      break
    }
  }

  private static func toolRisk(for toolID: String) -> ToolRisk {
    ToolCatalog.defaultDefinitions.first(where: { $0.id == toolID })?.risk ?? .medium
  }

  /// Computes the working-tree diff of the active session's project against
  /// the local git checkout. Spawns git off the actor so big diffs never
  /// stall event ingestion.
  public func loadDiffSnapshot() async -> DiffSnapshot? {
    guard let activeID = state.activeSessionID,
          let projectPath = state.sessions.first(where: { $0.id == activeID })?.projectPath,
          !projectPath.isEmpty else { return nil }
    let directory = URL(fileURLWithPath: projectPath, isDirectory: true)
    return try? await Task.detached(priority: .userInitiated) {
      try DiffEngine.snapshot(baseDirectory: directory)
    }.value
  }

  /// Live MCP server health and discovered skills for the integrations panel.
  public func loadIntegrationStatus() async -> KimiIntegrationStatus {
    async let mcpFetch = sessionClient.fetchMcpStatus(directory: nil)
    async let skillFetch = sessionClient.fetchSkills(directory: nil)
    let mcp = (try? await mcpFetch) ?? []
    let skills = (try? await skillFetch) ?? []
    return KimiIntegrationStatus(mcpServers: mcp, skills: skills)
  }

  /// The Harness intent/receipt journal joined into per-effect rows, newest
  /// first, for the verification panel.
  public func loadVerificationRecords() async -> [KimiVerificationRecord] {
    let snapshot = await harness.snapshot()
    return snapshot.intents.values.map { intent in
      let receipt = snapshot.receipts[intent.effectID]
      return KimiVerificationRecord(
        effectID: intent.effectID,
        subject: intent.subject,
        kind: intent.kind.rawValue,
        risk: intent.risk.rawValue,
        outcome: receipt?.outcome.rawValue,
        errorMessage: receipt?.errorMessage,
        retryable: receipt?.retryable ?? false,
        createdAt: intent.createdAt
      )
    }.sorted { $0.createdAt > $1.createdAt }
  }

  private func persistState() {
    guard let stateStore else { return }
    try? stateStore.save(KimiPersistedAppState(harnessSessionID: harnessSessionID, uiState: state))
  }

  private func publish(_ event: KimiEvent) {
    continuations.values.forEach { $0.yield(event) }
  }

  private func removeContinuation(_ token: UUID) {
    continuations.removeValue(forKey: token)
  }
}

public final class UnavailableKimiRuntimeSessionClient: KimiRuntimeSessionClient, @unchecked Sendable {
  public init() {}

  public func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。")
  }

  public func prompt(_ input: KimiRuntimePromptInput) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func steer(_ input: KimiRuntimeSteerInput) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func abort(sessionID: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func respondPermission(_ input: PermissionResponse) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<KimiRuntimeEvent, Error> { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func fetchMessages(sessionID: String, directory: String?) async throws -> [KimiRuntimeHistoryMessage] { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func fetchModelCatalog(directory: String?) async throws -> [String] { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
}
