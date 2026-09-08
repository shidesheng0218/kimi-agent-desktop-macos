import Foundation

/// The engine turn times out far beyond any realistic agentic run; the old
/// 300s ceiling failed long tasks while the engine kept executing in the
/// background, leaving UI and engine state permanently split.
public struct KimiDriverTimeoutError: Error, Sendable {
  public init() {}
}

public actor KimiRuntimeOperationDriver {
  private let client: any EngineProvider
  private let completionTimeout: Duration
  private var sessionID: String?
  private var directory: String?
  private var modelID: String = KimiRuntimeIdentityStore.defaultModelID

  public init(client: any EngineProvider, completionTimeout: Duration = .seconds(1_800)) {
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
    try await client.prompt(KimiRuntimePromptInput(sessionID: sessionID, text: context.prompt.text, directory: directory, modelID: modelID, attachments: context.prompt.attachments, agent: context.prompt.agent))
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
  ///
  /// A failed steer delivery throws instead of being swallowed: the user
  /// already sees their steering message in the timeline, so silently
  /// dropping it would claim a delivery that never happened.
  private func pumpSteering(context: HarnessOperationContext, sessionID: String) async throws {
    while !Task.isCancelled {
      let steering = await context.takeSteering()
      for input in steering where !input.text.isEmpty || !input.attachments.isEmpty {
        do {
          try await client.prompt(KimiRuntimePromptInput(sessionID: sessionID, text: input.text, directory: directory, modelID: modelID, attachments: input.attachments, agent: input.agent))
        } catch {
          throw KimiRuntimeError.requestFailed("补充指令没有送达执行引擎：\(error.localizedDescription)")
        }
      }
      try await Task.sleep(for: .milliseconds(300))
    }
  }

  private static func waitForCompletion(
    _ events: AsyncThrowingStream<EngineRuntimeEvent, Error>,
    timeout: Duration
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await event in events {
          switch event.turnOutcome {
          case .completed:
            return
          case .failed, .aborted:
            throw KimiRuntimeError.requestFailed(event.text ?? "执行会话失败。")
          case nil:
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
  private let sessionClient: any EngineProvider
  private let runtimeSupervisor: KimiRuntimeSupervisor?
  private let operationDriver: KimiRuntimeOperationDriver
  private let harness: AgentHarness
  private let stateStore: KimiAppStateStore?
  private let harnessStore: HarnessEventStore?
  private let activityStats: KimiActivityStatsStore?
  private let usageLedger: UsageLedger?
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
  /// Latest assistant `message.updated` usage per engine session, overwritten
  /// as cumulative frames stream in and consumed once at turn settlement.
  private var turnUsageBySession: [String: AssistantTurnUsage] = [:]
  /// Turn start wall-clock per engine session, recorded when the prompt is
  /// sent so the ledger entry carries a real latency figure.
  private var turnStartedAtBySession: [String: Date] = [:]
  /// 侧聊轮次的引擎消息 ID(message.updated 帧携带),用于派生确定性的账本
  /// entryID——重连重放同一轮帧序列时命中 UsageLedger 的 id 去重。
  private var turnMessageIDBySession: [String: String] = [:]
  /// Sessions the user deliberately aborted; the engine's resulting error
  /// frame is expected and must not surface as a red error banner.
  private var recentlyAbortedSessions: Set<String> = []
  private var lastTextPersistAt: Date = .distantPast
  /// The most recent failed Harness operation, so the UI's retry button has
  /// a concrete target without the view layer tracking operation IDs.
  private var lastFailedOperationID: OperationID?

  public init(
    sessionClient: any EngineProvider = UnavailableKimiRuntimeSessionClient(),
    runtimeSupervisor: KimiRuntimeSupervisor? = nil,
    sessionID: UUID = UUID(),
    persistence: KimiAppStateStore? = nil,
    harnessStore: HarnessEventStore? = nil,
    activityStats: KimiActivityStatsStore? = nil,
    usageLedger: UsageLedger? = nil,
    runtimeConfigurationProvider: (@Sendable (_ modelID: String, _ catalog: [String]) -> KimiRuntimeConfiguration?)? = nil,
    modelCatalog: [String]? = nil
  ) {
    self.sessionClient = sessionClient
    self.runtimeSupervisor = runtimeSupervisor
    self.stateStore = persistence
    self.harnessStore = harnessStore
    self.activityStats = activityStats
    self.usageLedger = usageLedger
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
    // Surfaces asynchronous Harness failures (driver timeout, engine stream
    // dying mid-turn, …) as a user-visible error. Without this the operation
    // settles as `.failed` inside the Harness while the UI keeps showing a
    // turn that simply never answers. Fire-and-forget: the loop exits when
    // the kernel deallocates (weak self), and the kernel lives for the app's
    // lifetime.
    let observedHarness = self.harness
    Task { [weak self] in
      for await event in await observedHarness.events() {
        guard let self else { return }
        await self.handleHarnessEvent(event)
      }
    }
  }

  private func handleHarnessEvent(_ event: HarnessEvent) {
    guard event.kind == .operationStateChanged,
          let payload = event.payload,
          let operation = try? JSONDecoder().decode(HarnessOperation.self, from: payload) else { return }
    if operation.state == .failed {
      lastFailedOperationID = operation.id
      let message = operation.errorMessage ?? "任务执行失败。"
      state.lastError = message
      publish(.error(message))
      persistState()
    } else if operation.state == .completed, operation.id == lastFailedOperationID {
      lastFailedOperationID = nil
    }
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
      await cleanupOrphanSideChats()
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
      do {
        let resolvedDirectory = directory ?? state.recentProjects.first
        // 独立工作区:git 仓库项目在 <repo>/.kimi/worktrees/<id> 创建
        // worktree,会话绑定到 worktree 目录;非 git 项目静默回退项目根,
        // git 失败时回退并在会话里注明。引擎 worktree 端点
        // (/experimental/worktree)未采用:它把 worktree 放在引擎全局数据
        // 目录、分支固定 opencode/<name> 且异步填充,不满足 .kimi 前缀
        // + 会话分支徽标 + 立即可绑定的要求。
        let localID = UUID()
        let (worktree, worktreeNote) = await resolveNewSessionWorktree(directory: resolvedDirectory, sessionID: localID)
        let session = try await sessionClient.createSession(CreateSessionInput(directory: worktree?.path.path ?? resolvedDirectory))
        let summary = KimiSessionSummary(
          id: localID,
          runtimeID: session.id,
          title: session.title ?? "新会话",
          projectPath: resolvedDirectory,
          worktreePath: worktree?.path.path,
          worktreeBranch: worktree?.branch
        )
        state.sessions.insert(summary, at: 0)
        state.activeSessionID = summary.id
        state.messages.removeAll()
        state.activities.removeAll()
        state.todos.removeAll()
        state.todosSessionID = nil
        if let worktreeNote {
          state.messages.append(KimiMessage(role: .system, text: worktreeNote))
        }
        recordRecentProject(summary.projectPath)
        await activityStats?.record(KimiActivityRecord(kind: .sessionCreated, project: summary.workingPath))
        try await watch(sessionID: session.id)
        publish(.sessionChanged(summary))
        state.lastError = nil
      } catch {
        let message = "创建会话失败：\(error.localizedDescription)"
        state.lastError = message
        publish(.error(message))
        persistState()
        throw error
      }

    case .createScratchSession:
      do {
        let scratchDirectory = try resolveScratchDirectory()
        let session = try await sessionClient.createSession(CreateSessionInput(directory: scratchDirectory.path, title: "临时对话"))
        let summary = KimiSessionSummary(
          id: UUID(),
          runtimeID: session.id,
          title: session.title ?? "临时对话",
          projectPath: session.directory ?? scratchDirectory.path,
          isScratch: true
        )
        state.sessions.insert(summary, at: 0)
        state.activeSessionID = summary.id
        state.messages.removeAll()
        state.activities.removeAll()
        state.todos.removeAll()
        state.todosSessionID = nil
        // Deliberately no recordRecentProject: the scratch directory must
        // never surface as a suggested folder for real project sessions.
        await activityStats?.record(KimiActivityRecord(kind: .sessionCreated, project: summary.projectPath))
        try await watch(sessionID: session.id)
        publish(.sessionChanged(summary))
        state.lastError = nil
      } catch {
        let message = "创建会话失败：\(error.localizedDescription)"
        state.lastError = message
        publish(.error(message))
        persistState()
        throw error
      }

    case let .forkSession(id, messageID):
      guard let source = state.sessions.first(where: { $0.id == id }), let sourceRuntimeID = source.runtimeID else {
        throw KimiRuntimeError.notRunning
      }
      let forked = try await sessionClient.forkSession(sessionID: sourceRuntimeID, messageID: messageID, directory: source.workingPath)
      let summary = KimiSessionSummary(
        id: UUID(),
        runtimeID: forked.id,
        title: forked.title ?? "\(source.title) 分支",
        // fork 与源会话在同一目录工作:继承项目根与 worktree 绑定,
        // 不取引擎返回的 directory(那是 worktree 路径,会破坏侧栏分组)。
        projectPath: source.projectPath,
        parentRuntimeID: forked.parentID ?? sourceRuntimeID,
        worktreePath: source.worktreePath,
        worktreeBranch: source.worktreeBranch
      )
      state.sessions.insert(summary, at: 0)
      state.activeSessionID = summary.id
      state.messages.removeAll()
      state.activities.removeAll()
      state.todos.removeAll()
      state.todosSessionID = nil
      recordRecentProject(summary.projectPath)
      await activityStats?.record(KimiActivityRecord(kind: .sessionCreated, project: summary.projectPath))
      try await watch(sessionID: forked.id)
      await loadHistory(sessionID: forked.id)
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
      do {
        let session = try await ensureActiveSession()
        await syncSessionPermissionRules(sessionID: session.id, directory: session.directory)
        await operationDriver.setSession(session.id, directory: session.directory)
        await operationDriver.setModel(state.selectedModel)
        state.messages.append(KimiMessage(role: .user, text: input.text, attachments: input.attachments))
        publish(.userText(input.text))
        replyCountedThisTurn = false
        await activityStats?.record(KimiActivityRecord(kind: .promptSent, project: session.directory))
        // Opt-in cost ceiling: only active when KIMI_AGENT_BUDGET_USD parses
        // as a positive Decimal and a usage ledger is attached. A .warning
        // verdict still passes; only .exceeded blocks the turn.
        if let usageLedger,
           let rawBudget = ProcessInfo.processInfo.environment["KIMI_AGENT_BUDGET_USD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let budget = Decimal(string: rawBudget), budget > 0 {
          let spent = usageLedger.totalCost()
          if CostBudgetGate.decision(spent: spent, budget: budget) == .exceeded {
            throw KimiRuntimeError.requestFailed("已超出成本预算：累计已花费 $\(spent)，预算上限 $\(budget)（KIMI_AGENT_BUDGET_USD）。本轮未发送，请调整预算或稍后重试。")
          }
        }
        turnStartedAtBySession[session.id] = .now
        let operationID = try await harness.prompt(input)
        operationSessions[operationID] = session.id
        sessionOperations[session.id] = operationID
        state.runtimeState = .ready
        state.lastError = nil
      } catch {
        // The turn never reached the engine: drop the sent-looking bubble so
        // the timeline stays truthful, surface the failure, and rethrow so
        // the view layer can restore the composer text.
        if state.messages.last?.role == .user, state.messages.last?.text == input.text {
          state.messages.removeLast()
        }
        let message = "发送失败：\(error.localizedDescription)"
        state.lastError = message
        publish(.error(message))
        persistState()
        throw error
      }

    case let .steer(input):
      let laneBusy = await harness.snapshot().lanes[.main]?.activeOperation != nil
      // Steering an idle lane is a new turn, not an intervention; route it to
      // the normal prompt path so the UI never loses a message.
      guard laneBusy else {
        try await send(.prompt(input))
        return
      }
      do {
        let session = try await ensureActiveSession()
        await syncSessionPermissionRules(sessionID: session.id, directory: session.directory)
        await operationDriver.setSession(session.id, directory: session.directory)
        state.messages.append(KimiMessage(role: .user, text: input.text, attachments: input.attachments))
        publish(.userText(input.text))
        try await harness.steer(input, lane: .main)
      } catch {
        if state.messages.last?.role == .user, state.messages.last?.text == input.text {
          state.messages.removeLast()
        }
        let message = "补充指令没有送达：\(error.localizedDescription)"
        state.lastError = message
        publish(.error(message))
        persistState()
        throw error
      }

    case let .followUp(input):
      let laneBusy = await harness.snapshot().lanes[.main]?.activeOperation != nil
      guard laneBusy else {
        try await send(.prompt(input))
        return
      }
      do {
        let session = try await ensureActiveSession()
        await operationDriver.setSession(session.id, directory: session.directory)
        state.messages.append(KimiMessage(role: .user, text: input.text, attachments: input.attachments))
        publish(.userText(input.text))
        try await harness.followUp(input, lane: .main)
      } catch {
        if state.messages.last?.role == .user, state.messages.last?.text == input.text {
          state.messages.removeLast()
        }
        let message = "排队指令没有送达：\(error.localizedDescription)"
        state.lastError = message
        publish(.error(message))
        persistState()
        throw error
      }

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

    case let .retry(operationID):
      // Retry used to be a no-op that only cleared the error banner. Resend
      // the failed operation's stored prompt through the normal prompt path
      // so a failed turn is actually recoverable.
      let harnessSnapshot = await harness.snapshot()
      guard let operation = harnessSnapshot.operations[operationID],
            operation.state == .failed,
            let prompt = operation.prompt else {
        state.lastError = "没有可重试的失败任务。"
        publish(.error(state.lastError ?? "没有可重试的失败任务。"))
        break
      }
      try await send(.prompt(prompt))

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

    case let .openAuxPane(pane):
      // 仅限纯本地投影面板与返回会话;diff/browser/files 各有专用命令。
      guard pane == .conversation || pane == .verification || pane == .integrations || pane == .tasks else { break }
      state.activePane = pane

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

    case let .deleteSession(id):
      guard let index = state.sessions.firstIndex(where: { $0.id == id }) else { break }
      let summary = state.sessions[index]
      if let runtimeID = summary.runtimeID {
        try? await sessionClient.deleteSession(sessionID: runtimeID, directory: summary.workingPath)
        eventTasks[runtimeID]?.cancel()
        eventTasks.removeValue(forKey: runtimeID)
        eventTaskTokens.removeValue(forKey: runtimeID)
        sessionOperations.removeValue(forKey: runtimeID)
        state.lastUserMessageIDBySession.removeValue(forKey: runtimeID)
        state.revertedSessionIDs.removeAll { $0 == runtimeID }
        state.busySessionIDs.removeAll { $0 == runtimeID }
      }
      state.sessions.remove(at: index)
      if state.activeSessionID == id {
        state.activeSessionID = nil
        state.messages.removeAll()
        state.activities.removeAll()
        state.todos.removeAll()
        state.todosSessionID = nil
      }

    case .openSideChat:
      // 侧聊 = 主会话的临时 fork:引擎侧复制完整历史,天然“能读到主会话
      // 上下文但不写入主会话”。不走 prompt_async 的 noReply(它只是不回
      // 复的单向写入)或消息摘要注入(fork 已带全量上下文,注入摘要只会
      // 更差)。临时会话不进 state.sessions,侧栏无感。
      guard state.sideChat == nil,
            let activeID = state.activeSessionID,
            let session = state.sessions.first(where: { $0.id == activeID }) else { break }
      let runtimeID = session.runtimeID ?? session.id.uuidString
      do {
        let forked = try await sessionClient.forkSession(sessionID: runtimeID, messageID: nil, directory: session.workingPath)
        state.sideChat = KimiSideChatState(
          sessionRuntimeID: forked.id,
          parentRuntimeID: runtimeID,
          directory: session.workingPath
        )
        if !state.sideChatRuntimeIDs.contains(forked.id) {
          state.sideChatRuntimeIDs.append(forked.id)
        }
        try await watch(sessionID: forked.id)
        publish(.sideChatUpdated)
        state.lastError = nil
      } catch {
        state.lastError = "打开侧聊失败：\(error.localizedDescription)"
        publish(.error(state.lastError ?? "打开侧聊失败。"))
      }

    case .closeSideChat:
      guard let sideChat = state.sideChat else { break }
      eventTasks[sideChat.sessionRuntimeID]?.cancel()
      eventTasks.removeValue(forKey: sideChat.sessionRuntimeID)
      eventTaskTokens.removeValue(forKey: sideChat.sessionRuntimeID)
      turnUsageBySession.removeValue(forKey: sideChat.sessionRuntimeID)
      turnStartedAtBySession.removeValue(forKey: sideChat.sessionRuntimeID)
      turnMessageIDBySession.removeValue(forKey: sideChat.sessionRuntimeID)
      state.sideChat = nil
      state.pendingPermissions.removeAll { $0.sessionRuntimeID == sideChat.sessionRuntimeID }
      state.sideChatRuntimeIDs.removeAll { $0 == sideChat.sessionRuntimeID }
      // 临时会话用完即删;失败则留在 sideChatRuntimeIDs 里,下次启动时
      // cleanupOrphanSideChats 重试。
      if (try? await sessionClient.deleteSession(sessionID: sideChat.sessionRuntimeID, directory: sideChat.directory)) == nil {
        state.sideChatRuntimeIDs.append(sideChat.sessionRuntimeID)
      }
      publish(.sideChatUpdated)

    case let .sideChatPrompt(text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, var sideChat = state.sideChat else { break }
      sideChat.messages.append(KimiMessage(role: .user, text: trimmed))
      sideChat.error = nil
      state.sideChat = sideChat
      publish(.sideChatUpdated)
      do {
        try await sessionClient.prompt(KimiRuntimePromptInput(
          sessionID: sideChat.sessionRuntimeID,
          text: trimmed,
          directory: sideChat.directory,
          modelID: state.selectedModel,
          agent: permissionMode.promptAgent
        ))
        // 与主通道一致:prompt 送达时记下轮次起点,结算时写真实时延。
        turnStartedAtBySession[sideChat.sessionRuntimeID] = .now
        state.sideChat?.busy = true
        publish(.sideChatUpdated)
      } catch {
        // 与主通道一致:送达失败的乐观气泡要撤回,输入交还给用户重发。
        if state.sideChat?.messages.last?.role == .user, state.sideChat?.messages.last?.text == trimmed {
          state.sideChat?.messages.removeLast()
        }
        state.sideChat?.error = "侧聊发送失败：\(error.localizedDescription)"
        publish(.sideChatUpdated)
      }

    case .sideChatAbort:
      guard let sideChat = state.sideChat else { break }
      try? await sessionClient.abort(sessionID: sideChat.sessionRuntimeID, directory: sideChat.directory)
      state.sideChat?.busy = false
      publish(.sideChatUpdated)

    case .restartRuntime:
      // Without a supervisor (engine not bundled) there is nothing to
      // restart; reporting ready here would lie about the runtime state.
      guard let runtimeSupervisor else {
        state.runtimeState = .failed
        state.lastError = "后台执行引擎尚未打包或未配置，无法重启。"
        publish(.runtimeChanged(.failed))
        publish(.error(state.lastError ?? "后台执行引擎尚未连接。"))
        persistState()
        break
      }
      do {
        _ = try await runtimeSupervisor.restart()
        try await runtimeSupervisor.waitUntilReady()
        state.runtimeState = .ready
        state.lastError = nil
        publish(.runtimeChanged(.ready))
        await restoreRuntimeSessions()
        await rewatchAllSessions()
      } catch {
        state.runtimeState = .failed
        state.lastError = "重启执行引擎失败：\(error.localizedDescription)"
        publish(.runtimeChanged(.failed))
        publish(.error(state.lastError ?? "重启执行引擎失败。"))
      }
    }
    persistState()
  }

  /// Retries the most recent failed Harness operation, if it is still in a
  /// failed state. Backs the error banner's retry button so the view layer
  /// never has to track operation IDs.
  public func retryLastFailure() async {
    guard let operationID = lastFailedOperationID else { return }
    let harnessSnapshot = await harness.snapshot()
    guard harnessSnapshot.operations[operationID]?.state == .failed else { return }
    try? await send(.retry(operationID))
  }

  /// Accumulated token/cost for one runtime session, read from the usage
  /// ledger. Nil when no ledger is attached or nothing has been settled for
  /// the session yet.
  public func sessionUsage(sessionID: String) -> (tokens: Int, cost: Decimal)? {
    usageLedger?.sessionUsage(sessionID: sessionID)
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

  /// 新会话的独立工作区解析:设置开启且目录是有 HEAD 的 git 仓库时创建
  /// .kimi/worktrees/<id> worktree;非 git 项目静默返回 nil,git 失败返回
  /// nil 并附注明文案。git 子进程全部在 detached 任务里执行。
  private func resolveNewSessionWorktree(directory: String?, sessionID: UUID) async -> (worktree: GitWorktree?, note: String?) {
    guard worktreeIsolationEnabled, let directory else { return (nil, nil) }
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    guard await GitWorktreeManager.canCreateSessionWorktree(root) else { return (nil, nil) }
    do {
      return (try await GitWorktreeManager.createSessionWorktree(projectRoot: root, sessionID: sessionID), nil)
    } catch {
      return (nil, "无法创建独立工作区（\(error.localizedDescription)），本次会话直接在项目目录运行。")
    }
  }

  private func ensureActiveSession() async throws -> KimiRuntimeSession {
    if let activeID = state.activeSessionID,
       let existing = state.sessions.first(where: { $0.id == activeID }) {
      return KimiRuntimeSession(id: existing.runtimeID ?? existing.id.uuidString, title: existing.title, directory: existing.workingPath)
    }
    guard let directory = state.recentProjects.first else {
      throw KimiRuntimeError.requestFailed("请先选择项目文件夹，再开始任务。")
    }
    // 隐式建会话(无会话直接发消息)与 ⌘N 走同一条 worktree 隔离路径。
    let localID = UUID()
    let (worktree, worktreeNote) = await resolveNewSessionWorktree(directory: directory, sessionID: localID)
    let created = try await sessionClient.createSession(CreateSessionInput(directory: worktree?.path.path ?? directory))
    let summary = KimiSessionSummary(
      id: localID,
      runtimeID: created.id,
      title: created.title ?? "新会话",
      projectPath: directory,
      worktreePath: worktree?.path.path,
      worktreeBranch: worktree?.branch
    )
    state.sessions.insert(summary, at: 0)
    state.activeSessionID = summary.id
    if let worktreeNote {
      state.messages.append(KimiMessage(role: .system, text: worktreeNote))
    }
    recordRecentProject(summary.projectPath)
    try await watch(sessionID: created.id)
    return created
  }

  // MARK: - 权限模式

  /// 当前权限模式（ViewModel 持久化在 UserDefaults，启动时回放到这里）。
  /// plan 模式的 agent 切换由 ViewModel 经 PromptInput.agent 携带；这里只
  /// 负责会话级 edit 规则的运行时 PATCH。
  private var permissionMode: KimiSessionPermissionMode = .manual

  /// 新会话是否绑定独立 git worktree(ViewModel 持久化在 UserDefaults,
  /// 启动时与拨动开关时回放到这里)。非 git 项目/git 失败自动回退项目根。
  private var worktreeIsolationEnabled = true

  public func setWorktreeIsolationEnabled(_ enabled: Bool) {
    worktreeIsolationEnabled = enabled
  }

  public func setPermissionMode(_ mode: KimiSessionPermissionMode) async {
    permissionMode = mode
    if let activeID = state.activeSessionID,
       let session = state.sessions.first(where: { $0.id == activeID }) {
      let runtimeID = session.runtimeID ?? session.id.uuidString
      await syncSessionPermissionRules(sessionID: runtimeID, directory: session.workingPath)
    }
  }

  /// 会话级 permission ruleset 运行时下发。引擎 Permission.evaluate 取最后
  /// 命中，会话规则覆盖配置级 ask；best-effort —— 失败只意味着回落到引擎
  /// 默认询问行为，不阻断发送。每条 prompt 前同步一次（loopback 开销可忽略），
  /// 这样会话切换、引擎重启后状态也不会漂移。
  private func syncSessionPermissionRules(sessionID: String, directory: String?) async {
    try? await sessionClient.updateSessionPermission(sessionID: sessionID, ruleset: permissionMode.sessionPermissionRules, directory: directory)
  }

  private func recordRecentProject(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    state.recentProjects.removeAll { $0 == path }
    state.recentProjects.insert(path, at: 0)
    if state.recentProjects.count > 10 {
      state.recentProjects = Array(state.recentProjects.prefix(10))
    }
  }

  /// The app's private directory for scratch sessions — always a real path,
  /// so the engine's `directory` query parameter is never omitted (an
  /// omitted directory falls back to the engine process's own cwd, silently
  /// running tools in the wrong place). Never surfaced in the folder picker
  /// or `state.recentProjects`, so it can't be confused with a project the
  /// user actually chose.
  private func resolveScratchDirectory() throws -> URL {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Kimi Code Agent/scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Rebuilds the conversation from the engine's durable message log. The
  /// local projection is intentionally replaced, not merged: the engine is
  /// the authoritative store, and live deltas re-attach by part identifier.
  private func loadHistory(sessionID: String) async {
    guard let history = try? await sessionClient.fetchMessages(sessionID: sessionID, directory: directoryForSession(sessionID)),
          !history.isEmpty else { return }
    let projected = Self.projectHistory(history)
    state.messages = projected.messages
    state.activities = projected.activities
    state.lastUserMessageIDBySession[sessionID] = history.last(where: { $0.role == "user" })?.id
    if let todos = try? await sessionClient.fetchTodos(sessionID: sessionID, directory: directoryForSession(sessionID)) {
      state.todos = todos
      state.todosSessionID = sessionID
    }
  }

  /// loadHistory 的纯函数部分:把引擎持久消息日志投影成 消息 + 活动 两条
  /// 时间线。活跃会话(loadHistory)与双会话分屏的次会话列(sessionHistory)
  /// 共用同一份映射,保证两侧渲染一致。
  private static func projectHistory(_ history: [KimiRuntimeHistoryMessage]) -> (messages: [KimiMessage], activities: [KimiActivity]) {
    var messages: [KimiMessage] = []
    var activities: [KimiActivity] = []
    for message in history {
      let createdAt = message.createdAt ?? .now
      if message.role == "user" {
        // 合成文本（file part 触发的 "Called the Read tool..." 与文件内容）
        // 不属于用户输入，重建气泡时排除；file part 本身还原为附件 chip。
        let text = message.parts.filter { $0.type == "text" && !$0.synthetic }.compactMap(\.text).joined(separator: "\n")
        let attachments = message.parts
          .filter { $0.type == "file" }
          .map { part in
            KimiPromptAttachment(
              filename: part.filename ?? "附件",
              mime: part.mime ?? "application/octet-stream",
              url: part.url ?? "",
              byteCount: 0
            )
          }
        if !text.isEmpty || !attachments.isEmpty {
          messages.append(KimiMessage(role: .user, text: text, runtimeMessageID: message.id, attachments: attachments, createdAt: createdAt))
        }
        continue
      }
      for part in message.parts {
        switch part.type {
        case "text":
          if let text = part.text, !text.isEmpty {
            messages.append(KimiMessage(role: .assistant, text: text, runtimePartID: part.partID, runtimeMessageID: message.id, createdAt: createdAt))
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
    return (messages, activities)
  }

  /// 双会话分屏的次会话列数据源:只读引擎持久历史,不触碰活跃会话投影。
  /// 返回空数组表示该会话暂无历史(与 loadHistory 的"空则不动"不同,
  /// 次会话列需要显式清空)。
  public func sessionHistory(sessionID runtimeID: String) async -> (messages: [KimiMessage], activities: [KimiActivity]) {
    guard let history = try? await sessionClient.fetchMessages(sessionID: runtimeID, directory: directoryForSession(runtimeID)) else {
      return ([], [])
    }
    return Self.projectHistory(history)
  }

  /// 分屏次会话的发送通道:绕开 Harness 主通道(Harness 车道绑定活跃会话,
  /// 切换会打断主会话),与侧聊同款走引擎直连 prompt。忙碌/权限/文本事件
  /// 经该会话的 watch 流按 sessionID 回流(busy 进全局 busySessionIDs,
  /// 文本走 .sessionEvent 直通)。
  public func promptSession(_ sessionID: UUID, input: PromptInput) async throws {
    guard let session = state.sessions.first(where: { $0.id == sessionID }) else {
      throw KimiRuntimeError.requestFailed("会话不存在或已删除。")
    }
    let runtimeID = session.runtimeID ?? session.id.uuidString
    await syncSessionPermissionRules(sessionID: runtimeID, directory: session.workingPath)
    try await sessionClient.prompt(KimiRuntimePromptInput(
      sessionID: runtimeID,
      text: input.text,
      directory: session.workingPath,
      modelID: state.selectedModel,
      attachments: input.attachments,
      agent: input.agent
    ))
  }

  /// 分屏次会话的斜杠命令通道:与 .runSlashCommand 同构,但按显式会话 ID
  /// 路由,不触碰活跃会话投影(主通道经 ensureActiveSession 绑定活跃会话)。
  public func runSessionSlashCommand(_ sessionID: UUID, name: String, arguments: String) async throws {
    guard let session = state.sessions.first(where: { $0.id == sessionID }) else {
      throw KimiRuntimeError.requestFailed("会话不存在或已删除。")
    }
    let runtimeID = session.runtimeID ?? session.id.uuidString
    try await sessionClient.runCommand(sessionID: runtimeID, command: name, arguments: arguments, directory: session.workingPath)
  }

  /// 中断指定会话(分屏次会话列的「停止」)。与 abortActiveSession 同构,
  /// 只是按显式会话 ID 定位。
  public func abortSession(_ sessionID: UUID) async {
    guard let session = state.sessions.first(where: { $0.id == sessionID }) else { return }
    let runtimeID = session.runtimeID ?? session.id.uuidString
    recentlyAbortedSessions.insert(runtimeID)
    try? await sessionClient.abort(sessionID: runtimeID, directory: directoryForSession(runtimeID))
    if let operationID = sessionOperations[runtimeID] {
      await harness.abort(operationID)
    }
    apply(.sessionBusy(sessionID: runtimeID, isBusy: false))
    publish(.sessionBusy(sessionID: runtimeID, isBusy: false))
    persistState()
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

  /// 侧聊临时会话不持久化在 UI 里,但引擎侧会话是持久的:应用退出时若
  /// 来不及 DELETE,启动时按 sideChatRuntimeIDs 兜底删除,best-effort。
  private func cleanupOrphanSideChats() async {
    let orphans = state.sideChatRuntimeIDs
    guard !orphans.isEmpty else { return }
    var survivors: [String] = []
    for runtimeID in orphans {
      if (try? await sessionClient.deleteSession(sessionID: runtimeID, directory: nil)) == nil {
        survivors.append(runtimeID)
      }
    }
    state.sideChatRuntimeIDs = survivors
  }

  private func restoreRuntimeSessions() async {
    guard let sessions = try? await sessionClient.listSessions(directory: nil) else { return }
    for session in sessions {
      // 侧聊临时会话不进侧栏;启动时的清理若已删掉它们,这里也见不到。
      if state.sideChatRuntimeIDs.contains(session.id) { continue }
      if let index = state.sessions.firstIndex(where: { $0.runtimeID == session.id }) {
        state.sessions[index].title = session.title ?? state.sessions[index].title
        // worktree 会话的引擎 directory 是 worktree 路径;projectPath 必须
        // 保持项目根(侧栏分组/最近项目/PR 监控),不能被引擎值覆盖。
        if state.sessions[index].worktreePath == nil {
          state.sessions[index].projectPath = session.directory ?? state.sessions[index].projectPath
        }
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
    //
    // Sessions created in the same restore pass share the exact same `.now`
    // timestamp (set just above), so `updatedAt` alone is not a total order.
    // Array.sort() is not guaranteed stable, so ties on that key can flip
    // their relative order on every call — visible in the sidebar as rows
    // swapping places each time the engine reconnects. `id` breaks ties
    // deterministically so repeated restores stop reshuffling the list.
    state.sessions.sort {
      $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString > $1.id.uuidString
    }
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
        await self?.ingest(EngineRuntimeEvent(sessionID: sessionID, kind: .error, text: error.localizedDescription))
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
    state.sessions.first(where: { $0.runtimeID == runtimeID })?.workingPath
  }

  /// 侧聊会话的事件路由:不进主会话时间线(state.messages/activities),
  /// 只更新 state.sideChat 并发刷新信号。权限/问答请求仍走主通道
  /// (pendingPermissions/pendingQuestions),由侧聊面板按 session 过滤展示。
  private func ingestSideChat(_ event: EngineRuntimeEvent) async {
    guard var sideChat = state.sideChat, sideChat.sessionRuntimeID == event.sessionID else { return }
    switch event.kind {
    case .assistantText:
      if let text = event.text, !text.isEmpty {
        if let partID = event.partID,
           let index = sideChat.messages.lastIndex(where: { $0.role == .assistant && $0.runtimePartID == partID }) {
          sideChat.messages[index].text = event.isSnapshot ? text : sideChat.messages[index].text + text
          sideChat.messages[index].isStreaming = true
        } else {
          sideChat.messages.append(KimiMessage(role: .assistant, text: text, isStreaming: true, runtimePartID: event.partID))
        }
      }
    case .sessionStatus:
      sideChat.busy = event.payload["statusType"] != "idle"
      if !sideChat.busy {
        sealSideChatStreams(&sideChat)
        settleSideChatTurnUsage(event, parentRuntimeID: sideChat.parentRuntimeID)
      }
    case .sessionIdle:
      sideChat.busy = false
      sealSideChatStreams(&sideChat)
      settleSideChatTurnUsage(event, parentRuntimeID: sideChat.parentRuntimeID)
    case .unknown:
      // 侧聊 fork 会话的 message.updated 用量帧:攒最新一份,等轮次结束的
      // idle 信号结算(与主通道 recordKimiRuntimeEvent 的 .unknown 分支同款)。
      if let usage = Self.parseAssistantTurnUsage(payload: event.payload) {
        turnUsageBySession[event.sessionID] = usage
        if let messageID = event.messageID { turnMessageIDBySession[event.sessionID] = messageID }
      }
    case .error:
      sideChat.error = event.text ?? "侧聊执行出错。"
      sideChat.busy = false
      sealSideChatStreams(&sideChat)
    case .permissionAsked, .permissionReplied, .questionAsked, .questionReplied:
      for mapped in KimiRuntimeEventBridge.map(event) {
        apply(mapped)
      }
    default:
      break
    }
    state.sideChat = sideChat
    publish(.sideChatUpdated)
  }

  private func sealSideChatStreams(_ sideChat: inout KimiSideChatState) {
    for index in sideChat.messages.indices where sideChat.messages[index].isStreaming {
      sideChat.messages[index].isStreaming = false
    }
  }

  private func ingest(_ event: EngineRuntimeEvent) async {
    if event.sessionID == state.sideChat?.sessionRuntimeID {
      await ingestSideChat(event)
      return
    }
    if event.kind == .error, recentlyAbortedSessions.remove(event.sessionID) != nil {
      return
    }
    // message.updated for a user message carries the durable engine message
    // identifier that revert targets; capture it before mapping drops it.
    if event.kind == .userText, let messageID = event.messageID {
      state.lastUserMessageIDBySession[event.sessionID] = messageID
    }
    await recordKimiRuntimeEvent(event)
    // 主时间线(state.messages/activities/todos)只承载活跃会话。其余会话的
    // 文本/活动事件若照样 append,会在双会话分屏或后台任务运行时污染当前
    // 时间线;它们改走 .sessionEvent 直通,由 ViewModel 的次会话列消费。
    // 按会话键控的全局投影(busySessionIDs/pendingPermissions/pendingQuestions)
    // 不受此过滤影响。
    let activeRuntimeID = state.sessions
      .first(where: { $0.id == state.activeSessionID })
      .map { $0.runtimeID ?? $0.id.uuidString }
    let isActiveSession = event.sessionID == activeRuntimeID
    if !isActiveSession {
      publish(.sessionEvent(event))
    }
    var persistImmediately = true
    for mapped in KimiRuntimeEventBridge.map(event) {
      if !isActiveSession, mapped.targetsActiveTimeline { continue }
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
        // 工具结果帧整卡替换时保留首帧的创建时间,后台任务面板的耗时
        // (updatedAt - createdAt)才是真实执行时长而非刷新间隔。
        var merged = activity
        merged.createdAt = state.activities[index].createdAt
        state.activities[index] = merged
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
    case .sideChatUpdated:
      // 纯刷新信号:侧聊状态由 ingestSideChat 直接维护。
      break
    case .sessionEvent:
      // 非活跃会话的原始事件直通,不投影进主时间线;ingest 也不会把它送进 apply。
      break
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
      // 侧聊/分屏次会话的 prompt 不经 Harness,没有 operation 映射;但权限
      // 回复端点(/permission/:id/reply)本身不需要 operation 上下文,按请求
      // 自带的会话 ID 直接回复即可。
      if let sessionRuntimeID = permission.sessionRuntimeID,
         state.sideChat?.sessionRuntimeID == sessionRuntimeID
           || state.sessions.contains(where: { ($0.runtimeID ?? $0.id.uuidString) == sessionRuntimeID }) {
        let directory = state.sideChat?.sessionRuntimeID == sessionRuntimeID
          ? state.sideChat?.directory
          : directoryForSession(sessionRuntimeID)
        do {
          try await sessionClient.respondPermission(PermissionResponse(
            sessionID: sessionRuntimeID,
            requestID: permission.runtimeID ?? permission.id.uuidString,
            reply: reply,
            directory: directory
          ))
        } catch {
          state.lastError = "审批回复失败（请求可能已过期）：\(error.localizedDescription)"
          publish(.error(state.lastError ?? "审批回复失败。"))
        }
        state.pendingPermissions.removeAll { $0.id == id }
        persistState()
        return
      }
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

  private func recordKimiRuntimeEvent(_ event: EngineRuntimeEvent) async {
    guard let operationID = sessionOperations[event.sessionID] else { return }
    let snapshot = await harness.snapshot()
    let checkpoint = snapshot.checkpoints[operationID]
    let turnID = checkpoint?.turnID ?? UUID()
    let step = checkpoint?.step ?? 1
    switch event.kind {
    case .sessionIdle, .sessionStatus:
      // One assistantMessage record per completed turn feeds the dashboard's
      // model-usage distribution; every engine's idle signal funnels through
      // the same explicit turnOutcome contract, regardless of wire shape.
      guard event.turnOutcome == .completed, !recordedAssistantTurns.contains(turnID) else { return }
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
      // Settle the turn's token usage into the ledger at the same dedupe
      // point: the entry id derives from the turn id, so a replayed or
      // double-settled turn can never be billed twice.
      if let usage = turnUsageBySession.removeValue(forKey: event.sessionID) {
        let latencyMS = turnStartedAtBySession.removeValue(forKey: event.sessionID)
          .map { max(0, Int(Date().timeIntervalSince($0) * 1_000)) } ?? 0
        settleTurnUsage(
          usage,
          entryID: Self.usageLedgerEntryID(turnID: turnID),
          operationID: operationID,
          sessionID: event.sessionID,
          latencyMS: latencyMS
        )
      }
    case .unknown:
      // Assistant message.updated frames stream cumulative usage; keep the
      // latest one so turn settlement reads the final counts.
      if let usage = Self.parseAssistantTurnUsage(payload: event.payload) {
        turnUsageBySession[event.sessionID] = usage
      }
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

  /// 把一轮的 token 用量结算进 UsageLedger:计价优先本地价目表,引擎上报
  /// 成本仅作显式标记的兜底(unknown price 不伪装成 0)。entryID 由调用方
  /// 按轮次确定性生成,重复结算/重放命中账本的 id 去重,不会重复计费。
  private func settleTurnUsage(_ usage: AssistantTurnUsage, entryID: UUID, operationID: UUID, sessionID: String, latencyMS: Int) {
    guard let usageLedger else { return }
    let model = state.selectedModel
    let provider = KimiRuntimeIdentityStore.providerID
    let pricing = ModelPriceCatalog.cost(
      provider: provider,
      model: model,
      inputTokens: usage.inputTokens,
      outputTokens: usage.billedOutputTokens,
      cachedTokens: usage.cachedTokens
    )
    let estimatedCost: Decimal
    let pricingStatus: UsageCostStatus
    if pricing.status == .calculated {
      estimatedCost = pricing.value
      pricingStatus = .calculated
    } else if let engineCost = usage.engineCost {
      estimatedCost = engineCost
      pricingStatus = .estimated
    } else {
      estimatedCost = 0
      pricingStatus = .unconfigured
    }
    try? usageLedger.append(UsageLedgerEntry(
      id: entryID,
      operationID: operationID,
      stage: .implement,
      provider: provider,
      model: model,
      inputTokens: usage.inputTokens,
      outputTokens: usage.billedOutputTokens,
      cachedTokens: usage.cachedTokens,
      latencyMS: latencyMS,
      estimatedCost: estimatedCost,
      qualityScore: nil,
      pricingStatus: pricingStatus,
      sessionID: sessionID
    ))
  }

  /// 侧聊轮次的用量结算:prompt 直连引擎、不经 Harness,没有 operation
  /// 映射,但 fork 会话的 watch 流同样下发 message.updated 用量帧与 idle
  /// 完成信号。sessionID 记主会话 runtimeID,会话头部的按会话用量聚合
  /// (sessionUsage)因此自动包含侧聊消耗。operationID 无对应 Harness 操作,
  /// 用轮次键派生的确定性 UUID 占位。
  private func settleSideChatTurnUsage(_ event: EngineRuntimeEvent, parentRuntimeID: String) {
    guard event.turnOutcome == .completed,
          let usage = turnUsageBySession.removeValue(forKey: event.sessionID) else { return }
    let messageKey = turnMessageIDBySession.removeValue(forKey: event.sessionID) ?? UUID().uuidString
    let turnKey = "sidechat|\(event.sessionID)|\(messageKey)"
    let latencyMS = turnStartedAtBySession.removeValue(forKey: event.sessionID)
      .map { max(0, Int(Date().timeIntervalSince($0) * 1_000)) } ?? 0
    settleTurnUsage(
      usage,
      entryID: Self.usageLedgerEntryID(key: turnKey),
      operationID: Self.usageLedgerEntryID(key: "\(turnKey)|operation"),
      sessionID: parentRuntimeID,
      latencyMS: latencyMS
    )
  }

  /// One assistant turn's usage as reported by the engine's
  /// `message.updated` frame. Reasoning tokens are billed as output; cache
  /// read/write fold into the ledger's single cachedTokens field.
  private struct AssistantTurnUsage: Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var engineCost: Decimal?

    var billedOutputTokens: Int { outputTokens + reasoningTokens }
    var cachedTokens: Int { cacheReadTokens + cacheWriteTokens }
  }

  /// Parses the decoder-forwarded usage payload. JSON numbers arrive as
  /// NSNumber regardless of whether the engine sent Int or Double.
  private static func parseAssistantTurnUsage(payload: [String: String]) -> AssistantTurnUsage? {
    guard let raw = payload["usageTokens"],
          let data = raw.data(using: .utf8),
          let tokens = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    func intField(_ container: [String: Any]?, _ key: String) -> Int {
      guard let container else { return 0 }
      if let number = container[key] as? NSNumber { return max(0, number.intValue) }
      if let string = container[key] as? String, let value = Int(string) { return max(0, value) }
      return 0
    }
    let cache = tokens["cache"] as? [String: Any]
    var engineCost: Decimal? = nil
    if let rawCost = payload["usageCost"], let cost = Decimal(string: rawCost), cost >= 0 {
      engineCost = cost
    }
    return AssistantTurnUsage(
      inputTokens: intField(tokens, "input"),
      outputTokens: intField(tokens, "output"),
      reasoningTokens: intField(tokens, "reasoning"),
      cacheReadTokens: intField(cache, "read"),
      cacheWriteTokens: intField(cache, "write"),
      engineCost: engineCost
    )
  }

  /// Deterministic per-turn entry id: settling the same turn twice (replayed
  /// SSE frames, ledger restored from disk while the in-memory dedupe set was
  /// reset) hits UsageLedger's id dedupe instead of double-billing.
  private static func usageLedgerEntryID(turnID: UUID) -> UUID {
    usageLedgerEntryID(key: turnID.uuidString)
  }

  /// 侧聊等不经 Harness 的轮次没有 checkpoint turnID,按自定义键派生。
  private static func usageLedgerEntryID(key: String) -> UUID {
    let hex = HarnessDigest.sha256("kimi-usage-ledger|\(key)")
    let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
    return UUID(uuidString: formatted) ?? UUID()
  }

  /// Computes the working-tree diff of the active session's project against
  /// the local git checkout. Spawns git off the actor so big diffs never
  /// stall event ingestion.
  public func loadDiffSnapshot() async -> DiffSnapshot? {
    switch await loadDiffOutcome() {
    case .snapshot(let snapshot): return snapshot
    case .noActiveProject, .failed: return nil
    }
  }

  /// Like loadDiffSnapshot() but keeps the failure reason instead of folding
  /// every error into nil — the diff panel must not render a failed git
  /// invocation as "no changes".
  public func loadDiffOutcome() async -> KimiDiffLoadOutcome {
    guard let activeID = state.activeSessionID,
          let projectPath = state.sessions.first(where: { $0.id == activeID })?.workingPath,
          !projectPath.isEmpty else { return .noActiveProject }
    let directory = URL(fileURLWithPath: projectPath, isDirectory: true)
    do {
      let snapshot = try await Task.detached(priority: .userInitiated) {
        try DiffEngine.snapshot(baseDirectory: directory)
      }.value
      return .snapshot(snapshot)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// Live MCP server health and discovered skills for the integrations panel.
  public func loadIntegrationStatus() async -> KimiIntegrationStatus {
    async let mcpFetch = sessionClient.fetchMcpStatus(directory: nil)
    async let skillFetch = sessionClient.fetchSkills(directory: nil)
    let mcp = (try? await mcpFetch) ?? []
    let skills = (try? await skillFetch) ?? []
    return KimiIntegrationStatus(mcpServers: mcp, skills: skills)
  }

  /// Adds an MCP server to the running engine via its live `POST /mcp`
  /// endpoint — the server connects immediately, no engine restart required.
  /// This is a runtime-only addition: it does not persist the entry, so it
  /// won't survive the next engine relaunch unless the caller also writes it
  /// to the on-disk MCP server config that `KimiHeadlessRuntimeFactory`
  /// reads at startup.
  public func addMCPServerAtRuntime(_ entry: KimiMCPServerEntry) async throws {
    try await sessionClient.addMCPServer(entry, directory: nil)
  }

  /// Disconnects an MCP server from the running engine via its live
  /// `POST /mcp/{name}/disconnect` endpoint — no engine restart required.
  /// Same persistence caveat as `addMCPServerAtRuntime`.
  public func removeMCPServerAtRuntime(name: String) async throws {
    try await sessionClient.removeMCPServer(name: name, directory: nil)
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

public enum KimiDiffLoadOutcome: Sendable {
  case noActiveProject
  case snapshot(DiffSnapshot)
  case failed(String)
}

public final class UnavailableKimiRuntimeSessionClient: EngineProvider, @unchecked Sendable {
  public init() {}

  public func createSession(_ input: CreateSessionInput) async throws -> KimiRuntimeSession {
    throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。")
  }

  public func prompt(_ input: KimiRuntimePromptInput) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func steer(_ input: KimiRuntimeSteerInput) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func abort(sessionID: String, directory: String?) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func respondPermission(_ input: PermissionResponse) async throws { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func listSessions(directory: String?) async throws -> [KimiRuntimeSession] { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func subscribeEvents(sessionID: String, directory: String?) async throws -> AsyncThrowingStream<EngineRuntimeEvent, Error> { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func fetchMessages(sessionID: String, directory: String?) async throws -> [KimiRuntimeHistoryMessage] { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
  public func fetchModelCatalog(directory: String?) async throws -> [String] { throw KimiRuntimeError.requestFailed("后台执行引擎尚未连接。") }
}
