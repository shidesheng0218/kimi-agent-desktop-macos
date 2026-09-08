import SwiftUI
import AppKit
import Combine
import KimiAgentCore
import Sparkle

final class KimiAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      KimiNotificationCenter.shared.registerDefaults()
      KimiNotificationCenter.shared.requestAuthorizationIfNeeded()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // A normal quit (⌘Q, menu, Dock) must also stop the embedded engine;
    // otherwise the runtime process survives as an orphan holding the data
    // directory and a loopback port. The registry is actor-free and
    // synchronous, which is all the draining run loop can rely on here.
    KimiEngineTerminationRegistry.shared.terminateAll()
  }
}

@main
struct KimiCodeAgentApp: App {
  @NSApplicationDelegateAdaptor(KimiAppDelegate.self) private var appDelegate
  @StateObject private var model = KimiAppViewModel()
  private let updaterController: SPUStandardUpdaterController

  init() {
    // Start the updater early so scheduled background checks run even before
    // the user opens the update menu item. Sparkle reads SUFeedURL /
    // SUPublicEDKey from the bundle Info.plist at packaging time.
    updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }

  var body: some Scene {
    WindowGroup("Kimi Code Agent") {
      KimiRootView(model: model)
        // KimiRootView's panes have their own minimums (sidebar 200 + workspace
        // 420 + terminal 280 + 2 dividers ≈ 916 when all expanded): the
        // window's own minimum must be at least that or shrinking toward it
        // clips content. Collapsed panes drop out of the sum entirely.
        .frame(minWidth: 940, minHeight: 760)
        .task { await model.start() }
    }
    .defaultSize(width: 1_360, height: 860)
    .commands {
      CommandGroup(after: .newItem) {
        Button("新建会话") { model.createSession() }
          .keyboardShortcut("n", modifiers: [.command])
      }
      CommandGroup(replacing: .appInfo) {
        Button("检查更新…") {
          updaterController.checkForUpdates(nil)
        }
      }
      CommandMenu("视图") {
        Button(model.sidebarCollapsed ? "显示侧栏" : "隐藏侧栏") { model.toggleSidebar() }
          .keyboardShortcut("b", modifiers: [.command])
        Button(model.terminalCollapsed ? "显示终端" : "隐藏终端") { model.toggleTerminal() }
          .keyboardShortcut("t", modifiers: [.command, .shift])
        Button(model.state.activePane == .diff ? "隐藏 Diff 面板" : "显示 Diff 面板") { model.toggleDiffPanel() }
          .keyboardShortcut("d", modifiers: [.command, .shift])
        Button(model.state.activePane == .browser ? "隐藏 Browser 面板" : "显示 Browser 面板") { model.toggleBrowserPanel() }
          .keyboardShortcut("b", modifiers: [.command, .shift])
        Button(model.state.sideChat != nil ? "关闭侧聊" : "打开侧聊") { model.toggleSideChat() }
          .keyboardShortcut(";", modifiers: [.command])
          .disabled(model.state.activeSessionID == nil && model.state.sideChat == nil)
        Divider()
        Button("切换视图模式（当前：\(model.viewMode.title)）") { model.cycleViewMode() }
          .keyboardShortcut("o", modifiers: [.control])
        Divider()
        Button(model.secondarySessionID != nil ? "关闭分屏" : (model.secondaryPane != nil ? "关闭次面板" : "返回会话")) {
          model.closeFocusedSplitOrPanel()
        }
        .keyboardShortcut("\\", modifiers: [.command])
        .disabled(!model.canCloseSplitOrPanel)
      }
      CommandGroup(after: .help) {
        Button("键盘快捷键") { model.toggleShortcutsHelp() }
          .keyboardShortcut("/", modifiers: [.command])
      }
    }
    // Occupies the .appSettings command slot (⌘, + the "设置…" app menu item)
    // for free — no manual window management needed. Replaces four
    // independent sheets that used to hang off KimiRootView.
    Settings {
      KimiSettingsView(model: model)
        .preferredColorScheme(model.appearancePreference.colorScheme)
    }
  }
}

/// Diff 面板里待提交的逐行评审评论：锚定 文件 + 行号 + 行内容，
/// diff 刷新后锚点失效时标记为已过期，保留在待提交列表中可手动删除。
struct KimiDiffComment: Identifiable, Equatable {
  let id: UUID
  let filePath: String
  let line: Int
  /// 不含 diff 前缀（+/-/空格）的行内容，用于刷新后重新校验锚点。
  let lineContent: String
  var text: String
  var stale = false
}

/// composer 归属列:主列沿用活跃会话单例状态(.primary);分屏次列按会话 ID
/// 键控(.secondary)。首页简易输入框与主列共用 .primary。
enum KimiComposerScope: Equatable {
  case primary
  case secondary(UUID)
}

/// 一列 composer 的草稿状态:输入文本、待发送附件、轻量提示与 @提及选中项。
struct KimiComposerDraft: Equatable {
  var text = ""
  var attachments: [KimiPromptAttachment] = []
  var notice: String?
  var mentionSelection = 0
}

@MainActor
final class KimiAppViewModel: ObservableObject {
  @Published private(set) var state = KimiUIState()
  @Published var composerText = ""
  /// 输入区待发送的附件（图片缩略图 / 文件 chip），发送成功后清空。
  @Published var composerAttachments: [KimiPromptAttachment] = []
  /// 附件条上的轻量提示（如图片超 10MB 未添加），下次操作时清除。
  @Published var composerNotice: String?
  /// @提及浮层当前键盘选中项（候选数组下标）。
  @Published var mentionSelection = 0
  @Published private(set) var terminalOutput = ""
  @Published private(set) var terminalSessionID: UUID?
  @Published private(set) var homeStats = KimiHomeStats()
  @Published private(set) var diffSnapshot: DiffSnapshot?
  @Published private(set) var diffLoading = false
  /// Non-nil when the last diff computation failed; the panel must show this
  /// instead of the misleading "no changes" empty state.
  @Published private(set) var diffError: String?
  /// Diff 面板待提交的逐行评审评论（跨面板切换保留）。
  @Published var diffComments: [KimiDiffComment] = []
  /// Diff 面板顶部的轻量确认横幅（如"已发送 N 条评审意见"），数秒后自动消失。
  @Published private(set) var diffReviewNotice: String?
  @Published private(set) var integrationStatus = KimiIntegrationStatus()
  @Published private(set) var verificationRecords: [KimiVerificationRecord] = []
  /// 当前会话累计用量（"12.4k tok · ¥0.38"），来自 UsageLedger 的按会话聚合。
  @Published private(set) var activeSessionUsage: String?
  /// 侧聊输入框草稿(面板侧的状态在 state.sideChat)。
  @Published var sideChatDraft = ""
  /// 删除会话确认:待删除的会话与其 worktree 是否含未提交改动(异步预查)。
  @Published private(set) var sessionPendingDeletion: KimiSessionSummary?
  @Published private(set) var pendingDeletionWorktreeDirty = false
  /// 预览浏览器(常驻 WKWebView,跨面板切换保活)与会话级 dev server 管理器。
  /// 引擎的验证 webview 走 KimiNativeBridge,与这里的预览浏览器完全隔离。
  let browserPreview = KimiBrowserPreviewController()
  let devServer = KimiDevServerManager()

  // MARK: - 双会话分屏(⌘点击侧栏会话)

  /// 分屏次列的会话;nil = 单会话。不持久化,退出应用即丢。
  @Published private(set) var secondarySessionID: UUID?
  /// 分屏焦点侧:侧栏普通点击替换焦点侧;焦点列有顶部高亮条。
  @Published var splitFocus: KimiSplitFocus = .primary
  /// 次会话列的时间线缓存。state.messages 只承载活跃会话;次列经
  /// kernel.sessionHistory 拉持久历史,经 .sessionEvent 直通事件实时追加。
  @Published private(set) var secondaryMessages: [KimiMessage] = []
  @Published private(set) var secondaryActivities: [KimiActivity] = []
  /// 分屏次列 composer 草稿,按次列会话 ID 键控;主列/首页沿用上面的单例字段。
  @Published private var secondaryComposerDrafts: [UUID: KimiComposerDraft] = [:]
  /// 当前获得焦点的 composer 列:⌘V 图片粘贴的本地事件监听每列各装一个,
  /// 靠它把剪贴板图片路由到正在输入的那一列。
  @Published var focusedComposerScope: KimiComposerScope = .primary
  @Published private(set) var secondaryError: String?

  let kernel: KimiAppKernel
  let terminalController: KimiTerminalController
  /// PR/CI 状态条监控：随活跃会话切换启停轮询，gh/git 不可用时静默降级。
  let pullRequestMonitor = KimiPullRequestMonitor()
  private var eventTask: Task<Void, Never>?
  private var terminalPollTask: Task<Void, Never>?
  /// PR 监控是独立 ObservableObject：把它的变更转发给本模型的 objectWillChange，
  /// 否则会话头部「是否显示 PR 状态条」的布局判断不会随轮询结果刷新。
  private var pullRequestMonitorCancellable: AnyCancellable?

  init(kernel: KimiAppKernel? = nil) {
    let defaults = UserDefaults.standard
    appearancePreference = KimiAppearancePreference(rawValue: defaults.string(forKey: Self.appearanceDefaultsKey) ?? "") ?? .system
    sidebarCollapsed = defaults.bool(forKey: Self.sidebarCollapsedDefaultsKey)
    terminalCollapsed = defaults.bool(forKey: Self.terminalCollapsedDefaultsKey)
    permissionMode = KimiSessionPermissionMode(rawValue: defaults.string(forKey: Self.permissionModeDefaultsKey) ?? "") ?? .manual
    viewMode = KimiTimelineViewMode(rawValue: defaults.string(forKey: Self.viewModeDefaultsKey) ?? "") ?? .standard
    // 默认开:object(forKey:) 为 nil 表示用户从未拨动过开关。
    worktreeIsolationEnabled = defaults.object(forKey: Self.worktreeIsolationDefaultsKey) as? Bool ?? true
    secondaryPane = defaults.string(forKey: Self.secondaryPaneDefaultsKey)
      .flatMap(KimiActivePane.init(rawValue:))
      .flatMap { $0 == .conversation ? nil : $0 }
    panelSplitHorizontal = defaults.object(forKey: Self.panelSplitHorizontalDefaultsKey) as? Bool ?? true
    self.kernel = kernel ?? Self.makeDefaultKernel()
    self.terminalController = KimiTerminalController()
    devServer.onURLDetected = { [weak self] sessionID, url in
      Task { @MainActor [weak self] in
        self?.handleDevServerDetectedURL(sessionID: sessionID, url: url)
      }
    }
    pullRequestMonitorCancellable = pullRequestMonitor.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    eventTask = Task { [weak self] in
      guard let self else { return }
      let stream = await self.kernel.events()
      for await event in stream {
        // 非活跃会话的原始事件直通:双会话分屏的次会话列据此实时追加文本。
        if case let .sessionEvent(raw) = event {
          await MainActor.run { [weak self] in self?.handleSecondarySessionEvent(raw) }
        }
        let next = await self.kernel.snapshot()
        // 用量只在轮次结束/切换会话/新消息时才可能变化，流式 delta 事件
        // 不必每次都拷贝整个账本做聚合。
        let usageMayHaveChanged = await MainActor.run { [weak self] () -> Bool in
          guard let self else { return false }
          let previous = self.state
          let changed = next.activeSessionID != previous.activeSessionID
            || next.messages.count != previous.messages.count
            || next.busySessionIDs != previous.busySessionIDs
            // 侧聊轮次结束时会把 token/成本结算进主会话账本,busy 翻转即刷新。
            || next.sideChat?.busy != previous.sideChat?.busy
          self.state = next
          self.sanitizeSplit()
          self.notifyStateTransitions(from: previous, to: next)
          let nextProject = next.sessions.first(where: { $0.id == next.activeSessionID })?.projectPath
          if next.activeSessionID != previous.activeSessionID
            || nextProject != previous.sessions.first(where: { $0.id == previous.activeSessionID })?.projectPath {
            // 会话切换（含切到无项目会话）时重启或停止 PR 状态轮询。
            self.pullRequestMonitor.start(projectPath: nextProject, sessionID: next.activeSessionID)
          }
          return changed
        }
        if usageMayHaveChanged { await self.refreshSessionUsage() }
      }
    }
  }

  private static func makeDefaultKernel() -> KimiAppKernel {
    let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Kimi Code Agent", isDirectory: true)
    KimiRuntimeDataMigrator.migrateIfNeeded(applicationSupportDirectory: support)
    let stateStore = KimiAppStateStore(fileURL: support.appendingPathComponent("settings/ui-state.json"))
    // The persisted projection decides the launch-time model and seeds the
    // engine's provider model table, so the user's last selection survives
    // restarts and every catalog entry validates engine-side.
    let persisted = try? stateStore.load()
    guard let configuration = KimiHeadlessRuntimeFactory.makeConfiguration(
      resourcesDirectory: resources,
      applicationSupportDirectory: support,
      modelID: persisted?.uiState.selectedModel,
      modelCatalog: persisted?.uiState.modelCatalog ?? []
    ) else {
      return KimiAppKernel()
    }
    let supervisor = KimiRuntimeSupervisor(configuration: configuration)
    let client = URLSessionRuntimeClient(endpoint: configuration.endpoint)
    let harnessStore = HarnessEventStore(fileURL: support.appendingPathComponent("harness/events.jsonl"))
    let activityStats = KimiActivityStatsStore(fileURL: support.appendingPathComponent("harness/activity.jsonl"))
    let usageLedger = UsageLedger(fileURL: support.appendingPathComponent("harness/usage-ledger.json"))
    let endpoint = configuration.endpoint
    let configurationProvider: @Sendable (String, [String]) -> KimiRuntimeConfiguration? = { modelID, catalog in
      KimiHeadlessRuntimeFactory.makeConfiguration(
        resourcesDirectory: resources,
        applicationSupportDirectory: support,
        modelID: modelID,
        modelCatalog: catalog,
        endpointOverride: endpoint
      )
    }
    return KimiAppKernel(
      sessionClient: client,
      runtimeSupervisor: supervisor,
      persistence: stateStore,
      harnessStore: harnessStore,
      activityStats: activityStats,
      usageLedger: usageLedger,
      runtimeConfigurationProvider: configurationProvider
    )
  }

  deinit {
    eventTask?.cancel()
    terminalPollTask?.cancel()
    let controller = terminalController
    Task { await controller.closeAll() }
  }

  func start() async {
    await kernel.setWorktreeIsolationEnabled(worktreeIsolationEnabled)
    await kernel.setPermissionMode(permissionMode)
    await kernel.startRuntime()
    await refresh()
    await startTerminalIfNeeded()
    pullRequestMonitor.start(projectPath: activeProjectPath, sessionID: state.activeSessionID)
  }

  func startTerminalIfNeeded() async {
    guard terminalSessionID == nil else { return }
    let cwd = state.sessions.first(where: { $0.id == state.activeSessionID })?.workingPath
      ?? FileManager.default.currentDirectoryPath
    do {
      let id = try await terminalController.open(cwd: URL(fileURLWithPath: cwd, isDirectory: true))
      terminalSessionID = id
      terminalPollTask = Task { [weak self] in
        guard let self else { return }
        while !Task.isCancelled {
      guard let id = self.terminalSessionID else { return }
          let output = await self.terminalController.output(for: id)
          let cleaned = KimiTerminalSanitizer.strip(output)
          let capped = cleaned.count > 300_000 ? String(cleaned.suffix(300_000)) : cleaned
          await MainActor.run { [weak self] in self?.terminalOutput = capped }
          try? await Task.sleep(for: .milliseconds(80))
        }
      }
    } catch {
      terminalOutput = "终端启动失败：\(error.localizedDescription)"
    }
  }

  func sendTerminalInput(_ input: String) {
    guard let id = terminalSessionID else { return }
    Task { try? await terminalController.write(input, to: id) }
  }

  func refresh() async {
    state = await kernel.snapshot()
    sanitizeSplit()
    await refreshSessionUsage()
  }

  private func refreshSessionUsage() async {
    guard let session = state.sessions.first(where: { $0.id == state.activeSessionID }) else {
      activeSessionUsage = nil
      return
    }
    let runtimeID = session.runtimeID ?? session.id.uuidString
    guard let usage = await kernel.sessionUsage(sessionID: runtimeID) else {
      activeSessionUsage = nil
      return
    }
    activeSessionUsage = Self.formatSessionUsage(tokens: usage.tokens, cost: usage.cost)
  }

  /// 例：12.4k tok · ¥0.38。成本未配置计价（为 0）时只显示 token 数，
  /// 避免把"未知"误报成"免费"。
  private static func formatSessionUsage(tokens: Int, cost: Decimal) -> String {
    let tokenText = tokens >= 1_000 ? String(format: "%.1fk", Double(tokens) / 1_000) : "\(tokens)"
    guard cost > 0 else { return "\(tokenText) tok" }
    return String(format: "%@ tok · ¥%.2f", tokenText, (cost as NSDecimalNumber).doubleValue)
  }

  func loadHomeStats(range: KimiUsageStatsRange) async {
    homeStats = await kernel.homeStats(range: range)
  }

  var activeProjectPath: String? {
    // 会话绑定 worktree 时,文件面板/@提及/终端/路径解析都应指向会话实际
    // 工作的 worktree 目录,而不是项目根。
    state.sessions.first(where: { $0.id == state.activeSessionID })?.workingPath
  }

  // MARK: - 侧聊(⌘;)

  var sideChat: KimiSideChatState? { state.sideChat }

  /// ⌘;:有侧聊则关闭(删除临时会话),没有则为当前会话 fork 一条。
  func toggleSideChat() {
    Task {
      if state.sideChat != nil {
        try? await kernel.send(.closeSideChat)
      } else {
        try? await kernel.send(.openSideChat)
      }
      await refresh()
    }
  }

  func sendSideChat() {
    let text = sideChatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    sideChatDraft = ""
    Task {
      try? await kernel.send(.sideChatPrompt(text))
      await refresh()
    }
  }

  func abortSideChat() {
    Task {
      try? await kernel.send(.sideChatAbort)
      await refresh()
    }
  }

  // MARK: - 双会话分屏(⌘点击侧栏会话)

  var secondarySession: KimiSessionSummary? {
    guard let secondarySessionID else { return nil }
    return state.sessions.first(where: { $0.id == secondarySessionID })
  }

  var isSecondarySessionBusy: Bool {
    guard let session = secondarySession else { return false }
    return state.busySessionIDs.contains(session.runtimeID ?? session.id.uuidString)
  }

  /// 侧栏会话点击统一入口:⌘点击 = 开/关分屏;分屏中普通点击替换焦点侧
  /// (点击已显示的某一侧只移动焦点)。
  func handleSidebarSelect(_ id: UUID, commandPressed: Bool) {
    if commandPressed {
      toggleSplitSession(id)
      return
    }
    if secondarySessionID != nil {
      if id == state.activeSessionID { splitFocus = .primary; return }
      if id == secondarySessionID { splitFocus = .secondary; return }
      if splitFocus == .secondary {
        replaceSecondarySession(id)
        return
      }
    }
    select(id)
  }

  /// ⌘点击语义:未分屏时把该会话放进次列;再 ⌘点击次列会话关分屏;
  /// ⌘点击第三个会话替换次列。⌘点击活跃会话只把焦点移回主列。
  func toggleSplitSession(_ id: UUID) {
    guard id != state.activeSessionID else { splitFocus = .primary; return }
    if secondarySessionID == id { closeSplit(); return }
    // 面板属于单会话工作区:进分屏前主区退回会话,不与分屏叠加。
    if state.activePane != .conversation { show(.conversation) }
    splitFocus = .secondary
    replaceSecondarySession(id)
  }

  private func replaceSecondarySession(_ id: UUID) {
    secondarySessionID = id
    secondaryMessages = []
    secondaryActivities = []
    secondaryError = nil
    Task { await loadSecondaryHistory() }
  }

  func closeSplit() {
    if let id = secondarySessionID { secondaryComposerDrafts.removeValue(forKey: id) }
    secondarySessionID = nil
    splitFocus = .primary
    secondaryMessages = []
    secondaryActivities = []
    secondaryError = nil
    if case .secondary = focusedComposerScope { focusedComposerScope = .primary }
  }

  /// ⌘\ 的层层退让:关分屏 > 关次面板槽 > 主区退回会话。
  func closeFocusedSplitOrPanel() {
    if secondarySessionID != nil { closeSplit(); return }
    if secondaryPane != nil { secondaryPane = nil; return }
    if state.activePane != .conversation { show(.conversation) }
  }

  var canCloseSplitOrPanel: Bool {
    secondarySessionID != nil || secondaryPane != nil || state.activePane != .conversation
  }

  func loadSecondaryHistory() async {
    guard let session = secondarySession else { return }
    let runtimeID = session.runtimeID ?? session.id.uuidString
    let history = await kernel.sessionHistory(sessionID: runtimeID)
    // 等待期间分屏可能已关闭或次列已换会话。
    guard secondarySessionID == session.id else { return }
    secondaryMessages = history.messages
    secondaryActivities = history.activities
    secondaryError = nil
  }

  /// 次会话列的实时事件(kernel .sessionEvent 直通):流式文本按 partID
  /// 追加/快照替换,轮次结束回拉一次持久历史(补齐工具活动与最终文本)。
  private func handleSecondarySessionEvent(_ event: EngineRuntimeEvent) {
    guard let session = secondarySession else { return }
    let runtimeID = session.runtimeID ?? session.id.uuidString
    guard event.sessionID == runtimeID else { return }
    switch event.kind {
    case .assistantText:
      guard let text = event.text, !text.isEmpty else { return }
      if let partID = event.partID,
         let index = secondaryMessages.lastIndex(where: { $0.role == .assistant && $0.runtimePartID == partID }) {
        secondaryMessages[index].text = event.isSnapshot ? text : secondaryMessages[index].text + text
        secondaryMessages[index].isStreaming = true
      } else {
        secondaryMessages.append(KimiMessage(role: .assistant, text: text, isStreaming: true, runtimePartID: event.partID))
      }
    case .sessionIdle:
      sealSecondaryStreams()
      Task { await loadSecondaryHistory() }
    case .sessionStatus:
      if event.payload["statusType"] == "idle" {
        sealSecondaryStreams()
        Task { await loadSecondaryHistory() }
      }
    case .error:
      secondaryError = event.text ?? "次会话执行出错。"
      sealSecondaryStreams()
    default:
      break
    }
  }

  private func sealSecondaryStreams() {
    for index in secondaryMessages.indices where secondaryMessages[index].isStreaming {
      secondaryMessages[index].isStreaming = false
    }
  }

  /// 快照刷新后的分屏自净:次会话被删除、或经其他路径(通知跳转等)变成
  /// 活跃会话时自动退出分屏。
  private func sanitizeSplit() {
    guard let secondarySessionID else { return }
    if secondarySessionID == state.activeSessionID
      || !state.sessions.contains(where: { $0.id == secondarySessionID }) {
      closeSplit()
    }
  }

  /// 次列 composer 发送:按次列会话 ID 路由,不经主通道 composer 状态。
  /// 附件/斜杠命令与主通道同款;失败时撤回乐观气泡并把输入交还(与主通道一致)。
  func sendSecondaryPrompt() {
    guard let sessionID = secondarySessionID else { return }
    let draft = composerDraft(for: .secondary(sessionID))
    let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = draft.attachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    // Harness 要求 prompt 文本非空:纯附件发送时补一句指代文本(与主通道一致)。
    let promptText = text.isEmpty ? "请查看我附上的内容。" : text
    updateComposerDraft(KimiComposerDraft(), for: .secondary(sessionID))
    secondaryMessages.append(KimiMessage(role: .user, text: promptText, attachments: attachments))
    secondaryError = nil
    Task {
      do {
        // 与主通道一致:已知斜杠命令走引擎 command 端点;带附件时不做斜杠
        // 路由,附件需要走普通 prompt 的 parts 通道。
        if attachments.isEmpty, text.hasPrefix("/") {
          let body = String(text.dropFirst())
          let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
          if let name = parts.first, state.availableCommands.contains(where: { $0.name == name }) {
            try await kernel.runSessionSlashCommand(sessionID, name: name, arguments: parts.count > 1 ? parts[1] : "")
            return
          }
        }
        try await kernel.promptSession(sessionID, input: PromptInput(text: promptText, attachments: attachments, agent: permissionMode.promptAgent))
      } catch {
        if secondaryMessages.last?.role == .user, secondaryMessages.last?.text == promptText {
          secondaryMessages.removeLast()
        }
        updateComposerDraft(draft, for: .secondary(sessionID))
        secondaryError = "发送失败：\(error.localizedDescription)"
      }
    }
  }

  func abortSecondary() {
    guard let sessionID = secondarySessionID else { return }
    Task { await kernel.abortSession(sessionID) }
  }

  // MARK: - composer 状态(按列键控)

  /// 读取某列 composer 的草稿;主列即活跃会话的单例字段,次列查字典。
  func composerDraft(for scope: KimiComposerScope) -> KimiComposerDraft {
    switch scope {
    case .primary:
      return KimiComposerDraft(text: composerText, attachments: composerAttachments, notice: composerNotice, mentionSelection: mentionSelection)
    case let .secondary(id):
      return secondaryComposerDrafts[id] ?? KimiComposerDraft()
    }
  }

  func updateComposerDraft(_ draft: KimiComposerDraft, for scope: KimiComposerScope) {
    switch scope {
    case .primary:
      composerText = draft.text
      composerAttachments = draft.attachments
      composerNotice = draft.notice
      mentionSelection = draft.mentionSelection
    case let .secondary(id):
      secondaryComposerDrafts[id] = draft
    }
  }

  /// SwiftUI TextField 绑定:次列草稿是字典值,需要显式 get/set。
  func composerTextBinding(for scope: KimiComposerScope) -> Binding<String> {
    Binding(
      get: { [weak self] in self?.composerDraft(for: scope).text ?? "" },
      set: { [weak self] text in
        guard let self else { return }
        var draft = self.composerDraft(for: scope)
        draft.text = text
        self.updateComposerDraft(draft, for: scope)
      }
    )
  }

  /// 该列会话的项目目录:@提及索引与文件引用按它解析;次列取自己会话的
  /// workingPath,不跟随活跃会话。
  func composerProjectPath(for scope: KimiComposerScope) -> String? {
    switch scope {
    case .primary:
      return activeProjectPath
    case let .secondary(id):
      return state.sessions.first(where: { $0.id == id })?.workingPath
    }
  }

  func isComposerSessionBusy(for scope: KimiComposerScope) -> Bool {
    switch scope {
    case .primary: return isActiveSessionBusy
    case .secondary: return isSecondarySessionBusy
    }
  }

  func sendComposerPrompt(for scope: KimiComposerScope) {
    switch scope {
    case .primary: sendPrompt()
    case .secondary: sendSecondaryPrompt()
    }
  }

  func abortComposerSession(for scope: KimiComposerScope) {
    switch scope {
    case .primary: abortActive()
    case .secondary: abortSecondary()
    }
  }

  // MARK: - 删除会话

  /// 侧栏「删除会话…」:先异步查 worktree 是否有未提交改动,再弹确认框。
  func requestDeleteSession(_ session: KimiSessionSummary) {
    Task {
      var dirty = false
      if let worktree = Self.sessionWorktree(for: session) {
        dirty = await GitWorktreeManager.hasUncommittedChanges(worktree)
      }
      pendingDeletionWorktreeDirty = dirty
      sessionPendingDeletion = session
    }
  }

  func cancelDeleteSession() {
    sessionPendingDeletion = nil
  }

  /// 确认删除:引擎会话必删;worktree 按用户选择清理(--force,未提交
  /// 改动已在确认框里警告过)。
  func confirmDeleteSession(removeWorktree: Bool) {
    guard let session = sessionPendingDeletion else { return }
    sessionPendingDeletion = nil
    if session.id == secondarySessionID { closeSplit() }
    Task {
      try? await kernel.send(.deleteSession(session.id))
      if removeWorktree, let worktree = Self.sessionWorktree(for: session) {
        try? await GitWorktreeManager.removeSessionWorktree(worktree)
      }
      await refresh()
    }
  }

  private static func sessionWorktree(for session: KimiSessionSummary) -> GitWorktree? {
    guard let worktreePath = session.worktreePath,
          let branch = session.worktreeBranch,
          let projectPath = session.projectPath else { return nil }
    return GitWorktree(
      repositoryPath: projectPath,
      path: URL(fileURLWithPath: worktreePath, isDirectory: true),
      branch: branch,
      baseCommit: ""
    )
  }

  func loadDiff() async {
    diffLoading = true
    switch await kernel.loadDiffOutcome() {
    case .snapshot(let snapshot):
      diffSnapshot = snapshot
      diffError = nil
      markDiffCommentsStale()
    case .noActiveProject:
      diffSnapshot = nil
      diffError = nil
    case .failed(let message):
      diffSnapshot = nil
      diffError = message
    }
    diffLoading = false
  }

  // MARK: - Diff 逐行评审

  func addDiffComment(filePath: String, line: Int, lineContent: String, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    diffComments.append(KimiDiffComment(id: UUID(), filePath: filePath, line: line, lineContent: lineContent, text: trimmed))
  }

  func removeDiffComment(_ id: UUID) {
    diffComments.removeAll { $0.id == id }
  }

  func discardDiffComments() {
    diffComments.removeAll()
  }

  /// diff 刷新后重新校验每条评论的锚点（文件仍在 diff 中且该行内容未变），
  /// 失效的标记为已过期但保留在列表里。
  private func markDiffCommentsStale() {
    guard !diffComments.isEmpty, let snapshot = diffSnapshot else { return }
    diffComments = diffComments.map { comment in
      var next = comment
      next.stale = !Self.commentAnchorExists(comment, in: snapshot)
      return next
    }
  }

  private static func commentAnchorExists(_ comment: KimiDiffComment, in snapshot: DiffSnapshot) -> Bool {
    guard let file = snapshot.files.first(where: { $0.path == comment.filePath }) else { return false }
    return file.displayRows().contains { row in
      guard case let .line(number, _) = row.kind, number == comment.line else { return false }
      return String(row.text.dropFirst()) == comment.lineContent
    }
  }

  private func showDiffReviewNotice(_ text: String) {
    diffReviewNotice = text
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard let self, self.diffReviewNotice == text else { return }
      self.diffReviewNotice = nil
    }
  }

  /// ⌘Enter：把所有待提交评论打包成一条评审消息发给引擎
  /// （忙碌走 steer 插话，空闲走普通 prompt），成功后清空。
  func sendDiffReview() {
    let comments = diffComments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !comments.isEmpty else { return }
    var lines = ["以下是针对当前工作区改动的评审意见（共 \(comments.count) 条）：", ""]
    for (index, comment) in comments.enumerated() {
      lines.append("\(index + 1). \(comment.filePath):\(comment.line)\(comment.stale ? "（该行已过期，diff 已变化）" : "")")
      lines.append("   代码：\(comment.lineContent.trimmingCharacters(in: .whitespaces))")
      lines.append("   评论：\(comment.text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    let text = lines.joined(separator: "\n")
    let count = comments.count
    Task {
      do {
        if isActiveSessionBusy {
          try await kernel.send(.steer(PromptInput(text: text, agent: permissionMode.promptAgent)))
        } else {
          try await kernel.send(.prompt(PromptInput(text: text, agent: permissionMode.promptAgent)))
        }
        diffComments.removeAll()
        showDiffReviewNotice("已发送 \(count) 条评审意见")
      } catch {
        // 失败经 state.lastError 横幅展示，评论保留可修改后重发。
      }
      await refresh()
    }
  }

  /// 「AI 评审」：把当前 diff（截断到 100KB）作为上下文让引擎自审，
  /// 结果作为普通助手消息出现在会话中。
  func requestAIReview() {
    guard let snapshot = diffSnapshot, !snapshot.files.isEmpty else { return }
    var diffText = ""
    for file in snapshot.files {
      diffText += "diff \(file.path)（\(file.status.rawValue)）\n"
      for hunk in file.hunks {
        diffText += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
        diffText += hunk.lines.joined(separator: "\n") + "\n"
      }
    }
    let truncated = diffText.count > 100_000
    if truncated { diffText = String(diffText.prefix(100_000)) }
    var text = "请评审以下未提交改动的编译错误、逻辑错误、安全漏洞和明显 bug，不要评论风格问题。\n\n\(diffText)"
    if truncated { text += "\n\n…（diff 过大，已截断到 100KB）" }
    Task {
      do {
        if isActiveSessionBusy {
          try await kernel.send(.steer(PromptInput(text: text, agent: permissionMode.promptAgent)))
        } else {
          try await kernel.send(.prompt(PromptInput(text: text, agent: permissionMode.promptAgent)))
        }
        showDiffReviewNotice("已发送 AI 评审请求，结果将出现在会话中")
      } catch {
        // 失败经 state.lastError 横幅展示。
      }
      await refresh()
    }
  }

  func loadIntegrations() async {
    integrationStatus = await kernel.loadIntegrationStatus()
  }

  func loadVerification() async {
    verificationRecords = await kernel.loadVerificationRecords()
  }

  func createSession() {
    guard let directory = pickProjectDirectory() else { return }
    Task {
      // The kernel surfaces the failure via state.lastError; the home pane
      // banner renders it, so the user is never left on a dead click.
      try? await kernel.send(.createSession(directory: directory.path))
      await refresh()
    }
  }

  /// Skips the folder picker: the session binds to the app's private
  /// scratch directory instead of a user-chosen project. See
  /// KimiAppKernel.resolveScratchDirectory for why this is never a truly
  /// directory-less session.
  func createScratchSession() {
    Task {
      try? await kernel.send(.createScratchSession)
      await refresh()
    }
  }

  /// Retries the most recent failed turn. Backs the retry button on the
  /// error banner.
  func retryLastFailure() {
    Task {
      await kernel.retryLastFailure()
      await refresh()
    }
  }

  /// All session creation funnels through a project picker: the engine
  /// resolves the working directory per session, so a session without a
  /// project would silently run in the engine's cwd instead of user code.
  @MainActor
  func pickProjectDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "选择项目文件夹"
    panel.message = "选择 Kimi Code Agent 要工作的项目文件夹"
    if let recent = state.recentProjects.first {
      panel.directoryURL = URL(fileURLWithPath: recent, isDirectory: true)
    }
    return panel.runModal() == .OK ? panel.url : nil
  }

  func goHome() {
    // 回首页即退出分屏:首页没有工作区,分屏状态留着会在下次选会话时意外复活。
    if secondarySessionID != nil { closeSplit() }
    Task {
      try? await kernel.send(.showHome)
      await refresh()
    }
  }

  func changeModel(_ model: String) {
    Task {
      try? await kernel.send(.changeModel(model))
      await refresh()
    }
  }

  /// Re-bind the active session to a different project directory chosen by
  /// the user. Mirrors createSession but skips spawning a new session —
  /// the engine keeps the same session; only the working directory changes.
  @MainActor
  func changeProjectDirectory() {
    guard let newDir = pickProjectDirectory() else { return }
    Task {
      guard let activeID = state.activeSessionID,
            let session = state.sessions.first(where: { $0.id == activeID }),
            let runtimeID = session.runtimeID else { return }
      // Re-create the session with the new directory (engine binds directory
      // at session creation time, so the cleanest way is a new session in the
      // new directory while keeping the UI in the same view).
      try? await kernel.send(.createSession(directory: newDir.path))
      await refresh()
      _ = runtimeID // silence warning; the old session stays in history
    }
  }

  func changeThinkingEffort(_ effort: String) {
    Task {
      try? await kernel.send(.changeThinkingEffort(effort))
      await refresh()
    }
  }

  // MARK: - API key management

  /// Returns true when any provider has a credential saved. Checks the
  /// per-provider Keychain buckets via KimiRuntimeIdentityStore rather than
  /// the old single legacy key — that legacy key gets migrated into a
  /// per-provider bucket and deleted by migrateIfNeeded(), so checking it
  /// directly would report "not configured" even right after a successful
  /// first-time save.
  @MainActor
  func loadAPIKeyStatus() -> Bool {
    let store = KimiRuntimeIdentityStore(vault: MacKeychainCredentialVault())
    return !((try? store.configuredProviderIDs()) ?? []).isEmpty
  }

  func restartRuntime() {
    Task {
      try? await kernel.send(.restartRuntime)
      await refresh()
    }
  }

  func select(_ id: UUID) {
    Task {
      try? await kernel.send(.selectSession(id))
      await refresh()
    }
  }

  /// Forks a session into a new branch. `messageID` is the engine message ID
  /// to branch from (nil forks the entire history up to now). The new
  /// session becomes active immediately, same as creating a fresh one.
  func forkSession(_ id: UUID, messageID: String?) {
    Task {
      try? await kernel.send(.forkSession(id, messageID: messageID))
      await refresh()
    }
  }

  func sendPrompt() {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = composerAttachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    // Harness 要求 prompt 文本非空：纯附件发送时补一句指代文本。
    let promptText = text.isEmpty ? "请查看我附上的内容。" : text
    // No session yet and no known project: pick the project first so the
    // implicit session lands in real user code.
    if state.activeSessionID == nil, state.recentProjects.isEmpty {
      guard let directory = pickProjectDirectory() else { return }
      composerText = ""
      composerAttachments = []
      composerNotice = nil
      Task {
        do {
          try await kernel.send(.createSession(directory: directory.path))
          try await kernel.send(.prompt(PromptInput(text: promptText, attachments: attachments, agent: permissionMode.promptAgent)))
        } catch {
          // Failure is already surfaced via state.lastError; give the user
          // their input back so a failed send never eats typed text.
          composerText = text
          composerAttachments = attachments
        }
        await refresh()
      }
      return
    }
    composerText = ""
    composerAttachments = []
    composerNotice = nil
    Task {
      do {
        // Slash commands route to the engine's command endpoint; unknown slash
        // text falls through to a normal prompt. 带附件时不做斜杠路由，
        // 附件需要走普通 prompt 的 parts 通道。
        if attachments.isEmpty, text.hasPrefix("/") {
          let body = String(text.dropFirst())
          let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
          if let name = parts.first, state.availableCommands.contains(where: { $0.name == name }) {
            try await kernel.send(.runSlashCommand(name: name, arguments: parts.count > 1 ? parts[1] : ""))
            await refresh()
            return
          }
        }
        // While the session is executing, a submitted message steers the
        // running turn instead of failing on a busy lane.
        if isActiveSessionBusy {
          try await kernel.send(.steer(PromptInput(text: promptText, attachments: attachments, agent: permissionMode.promptAgent)))
        } else {
          try await kernel.send(.prompt(PromptInput(text: promptText, attachments: attachments, agent: permissionMode.promptAgent)))
        }
      } catch {
        composerText = text
        composerAttachments = attachments
      }
      await refresh()
    }
  }

  // MARK: - 附件与 @提及

  private let mentionIndex = KimiFileMentionIndex()
  /// 各项目的相对路径索引缓存（同步过滤用；异步扫描完成后回填）。
  /// 分屏两列可能各自绑定不同项目,按项目键控避免互相挤掉。
  private var mentionPathsByProject: [String: [String]] = [:]

  /// 粘贴板图片 → 附件。返回 false 表示粘贴板里没有图片，调用方继续走文本粘贴。
  @MainActor
  @discardableResult
  func pasteComposerImage(from pasteboard: NSPasteboard, scope: KimiComposerScope = .primary) -> Bool {
    let imageData: Data? = pasteboard.data(forType: .png)
      ?? pasteboard.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    guard let data = imageData else { return false }
    addComposerImageData(data, suggestedName: nil, scope: scope)
    return true
  }

  /// 拖拽/粘贴图片的统一入口：大小校验 + data URL 附件。
  @MainActor
  func addComposerImageData(_ data: Data, suggestedName: String?, scope: KimiComposerScope = .primary) {
    var draft = composerDraft(for: scope)
    guard data.count <= KimiPromptAttachment.maxImageBytes else {
      draft.notice = "图片超过 10MB，未添加（\(String(format: "%.1f", Double(data.count) / 1_048_576))MB）"
      updateComposerDraft(draft, for: scope)
      return
    }
    let mime = KimiPromptAttachment.sniffImageMIME(data) ?? "image/png"
    let ext = mime == "image/jpeg" ? "jpg" : (mime == "image/gif" ? "gif" : (mime == "image/webp" ? "webp" : "png"))
    let name = suggestedName ?? "截图-\(Self.attachmentTimestamp()).\(ext)"
    draft.attachments.append(.image(data: data, filename: name, mime: mime))
    draft.notice = nil
    updateComposerDraft(draft, for: scope)
  }

  /// 拖拽文件：图片读内容做 data URL 附件；其余按 file:// 引用（引擎端读取）。
  @MainActor
  func addComposerFileURLs(_ urls: [URL], scope: KimiComposerScope = .primary) {
    var draft = composerDraft(for: scope)
    for url in urls {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
      if let data = try? Data(contentsOf: url), KimiPromptAttachment.sniffImageMIME(data) != nil {
        updateComposerDraft(draft, for: scope)
        addComposerImageData(data, suggestedName: url.lastPathComponent, scope: scope)
        draft = composerDraft(for: scope)
        continue
      }
      let reference = KimiPromptAttachment.fileReference(absolutePath: url.path)
      if !draft.attachments.contains(where: { $0.url == reference.url }) {
        draft.attachments.append(reference)
      }
    }
    draft.notice = nil
    updateComposerDraft(draft, for: scope)
  }

  @MainActor
  func removeComposerAttachment(_ id: UUID, scope: KimiComposerScope = .primary) {
    var draft = composerDraft(for: scope)
    draft.attachments.removeAll { $0.id == id }
    updateComposerDraft(draft, for: scope)
  }

  private static func attachmentTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: .now)
  }

  /// 异步建立/刷新指定项目的 @提及索引；每个项目只扫一次。
  func refreshMentionIndex(project: String?) {
    guard let project, !project.isEmpty, mentionPathsByProject[project] == nil else { return }
    // 先占位,避免扫描期间重复发起;完成后回填。
    mentionPathsByProject[project] = []
    Task {
      let paths = await mentionIndex.paths(root: project)
      mentionPathsByProject[project] = paths
    }
  }

  /// @提及候选：文件名前缀匹配优先，其次路径包含；上限 8 条。
  func mentionCandidates(for query: String, project: String?) -> [String] {
    let lowered = query.lowercased()
    let pool = project.flatMap { mentionPathsByProject[$0] } ?? []
    if lowered.isEmpty { return Array(pool.prefix(8)) }
    let prefixMatches = pool.filter { ($0 as NSString).lastPathComponent.lowercased().hasPrefix(lowered) }
    let containsMatches = pool.filter { $0.lowercased().contains(lowered) && !($0 as NSString).lastPathComponent.lowercased().hasPrefix(lowered) }
    return Array((prefixMatches + containsMatches).prefix(8))
  }

  /// 选中候选：把输入框尾部的 @query 替换为 @相对路径，并加入文件引用附件。
  @MainActor
  func applyMention(_ relativePath: String, replacingQuery query: String, scope: KimiComposerScope = .primary) {
    var draft = composerDraft(for: scope)
    let tail = "@\(query)"
    if draft.text.hasSuffix(tail) {
      draft.text = String(draft.text.dropLast(tail.count)) + "@\(relativePath) "
    }
    draft.mentionSelection = 0
    if let project = composerProjectPath(for: scope) {
      let absolute = (project as NSString).appendingPathComponent(relativePath)
      let reference = KimiPromptAttachment.fileReference(absolutePath: absolute)
      if !draft.attachments.contains(where: { $0.url == reference.url }) {
        draft.attachments.append(reference)
      }
    }
    updateComposerDraft(draft, for: scope)
  }

  var isActiveSessionBusy: Bool {
    guard let session = state.sessions.first(where: { $0.id == state.activeSessionID }) else { return false }
    return state.busySessionIDs.contains(session.runtimeID ?? session.id.uuidString)
  }

  func abortActive() {
    Task {
      await kernel.abortActiveSession()
      await refresh()
    }
  }

  /// 重新生成：把该条助手消息之前最近的一条用户消息原样重发，
  /// 走与 composer 相同的 prompt/steer 通道。
  func regenerateResponse(to messageID: UUID) {
    guard let index = state.messages.firstIndex(where: { $0.id == messageID }),
          let text = state.messages[..<index].last(where: { $0.role == .user })?.text,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    Task {
      do {
        if isActiveSessionBusy {
          try await kernel.send(.steer(PromptInput(text: text, agent: permissionMode.promptAgent)))
        } else {
          try await kernel.send(.prompt(PromptInput(text: text, agent: permissionMode.promptAgent)))
        }
      } catch {
        // 失败经 state.lastError 的横幅展示，无需在此再处理。
      }
      await refresh()
    }
  }

  func approve(_ id: UUID) {
    Task {
      try? await kernel.send(.approve(id))
      await refresh()
    }
  }

  func approveAlways(_ id: UUID) {
    Task {
      try? await kernel.send(.approveAlways(id))
      await refresh()
    }
  }

  func deny(_ id: UUID) {
    Task {
      try? await kernel.send(.deny(id))
      await refresh()
    }
  }

  func answerQuestion(_ id: UUID, _ answers: [[String]]) {
    Task {
      try? await kernel.send(.answerQuestion(id, answers))
      await refresh()
    }
  }

  func rejectQuestion(_ id: UUID) {
    Task {
      try? await kernel.send(.rejectQuestion(id))
      await refresh()
    }
  }

  var activeRuntimeID: String? {
    guard let session = state.sessions.first(where: { $0.id == state.activeSessionID }) else { return nil }
    return session.runtimeID ?? session.id.uuidString
  }

  var canRevertActive: Bool {
    guard let runtimeID = activeRuntimeID else { return false }
    return state.lastUserMessageIDBySession[runtimeID] != nil
      && !state.busySessionIDs.contains(runtimeID)
      && !state.revertedSessionIDs.contains(runtimeID)
  }

  func revertLastTurn() {
    Task {
      try? await kernel.send(.revertLastTurn)
      await refresh()
    }
  }

  func unrevert() {
    Task {
      try? await kernel.send(.unrevert)
      await refresh()
    }
  }

  func compact() {
    Task {
      try? await kernel.send(.compact)
      await refresh()
    }
  }

  func sendFollowUp() {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    composerText = ""
    Task {
      try? await kernel.send(.followUp(PromptInput(text: text, agent: permissionMode.promptAgent)))
      await refresh()
    }
  }

  // MARK: - 系统通知

  /// 状态快照 diff：某会话由忙碌转空闲（完成）或出现新的待审批权限卡时，
  /// 若该会话不是当前查看会话、或应用窗口不在前台，发系统通知。
  private func notifyStateTransitions(from old: KimiUIState, to new: KimiUIState) {
    let appInactive = !NSApplication.shared.isActive
    let activeRuntimeID = new.sessions
      .first(where: { $0.id == new.activeSessionID })
      .map { $0.runtimeID ?? $0.id.uuidString }
    // 分屏次列也在屏幕上,它的完成/审批同样不需要系统通知。
    let secondaryRuntimeID = secondarySessionID
      .flatMap { id in new.sessions.first(where: { $0.id == id }) }
      .map { $0.runtimeID ?? $0.id.uuidString }
    func summary(forRuntimeID runtimeID: String?) -> KimiSessionSummary? {
      new.sessions.first(where: { ($0.runtimeID ?? $0.id.uuidString) == runtimeID })
    }
    func shouldNotify(runtimeID: String?) -> Bool {
      appInactive || (runtimeID != activeRuntimeID && runtimeID != secondaryRuntimeID)
    }
    for runtimeID in old.busySessionIDs where !new.busySessionIDs.contains(runtimeID) {
      guard shouldNotify(runtimeID: runtimeID) else { continue }
      let session = summary(forRuntimeID: runtimeID)
      KimiNotificationCenter.shared.post(
        title: session?.title ?? "会话",
        body: "任务执行完成",
        sessionID: session?.id ?? new.activeSessionID ?? UUID()
      )
    }
    for permission in new.pendingPermissions where !old.pendingPermissions.contains(permission) {
      guard shouldNotify(runtimeID: permission.sessionRuntimeID) else { continue }
      let session = summary(forRuntimeID: permission.sessionRuntimeID)
      KimiNotificationCenter.shared.post(
        title: session?.title ?? "会话",
        body: "需要确认：\(permission.reason)",
        sessionID: session?.id ?? new.activeSessionID ?? UUID()
      )
    }
  }

  // MARK: - 外观与布局

  private static let appearanceDefaultsKey = "kimi.appearance"
  private static let sidebarCollapsedDefaultsKey = "kimi.layout.sidebarCollapsed"
  private static let terminalCollapsedDefaultsKey = "kimi.layout.terminalCollapsed"
  private static let permissionModeDefaultsKey = "kimi.permissionMode"
  private static let viewModeDefaultsKey = "kimi.viewMode"
  private static let worktreeIsolationDefaultsKey = "kimi.worktreeIsolation"
  private static let secondaryPaneDefaultsKey = "kimi.layout.secondaryPane"
  private static let panelSplitHorizontalDefaultsKey = "kimi.layout.panelSplitHorizontal"

  @Published var appearancePreference: KimiAppearancePreference {
    didSet { UserDefaults.standard.set(appearancePreference.rawValue, forKey: Self.appearanceDefaultsKey) }
  }
  @Published var sidebarCollapsed: Bool {
    didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarCollapsedDefaultsKey) }
  }
  @Published var terminalCollapsed: Bool {
    didSet { UserDefaults.standard.set(terminalCollapsed, forKey: Self.terminalCollapsedDefaultsKey) }
  }
  /// 权限模式（手动确认 / 自动接受编辑 / 计划模式），全局持久化；
  /// 切换即下发到引擎当前会话，发送 prompt 时也会按最新值同步。
  @Published var permissionMode: KimiSessionPermissionMode {
    didSet { UserDefaults.standard.set(permissionMode.rawValue, forKey: Self.permissionModeDefaultsKey) }
  }
  /// 会话时间线视图模式（标准 / 详细 / 精简），全局持久化。
  @Published var viewMode: KimiTimelineViewMode {
    didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeDefaultsKey) }
  }
  /// 「新会话使用独立工作区」:git 仓库项目的新会话绑定 .kimi/worktrees
  /// 下的 worktree。全局持久化,同步到 kernel 在创建会话时生效。
  @Published var worktreeIsolationEnabled: Bool {
    didSet {
      UserDefaults.standard.set(worktreeIsolationEnabled, forKey: Self.worktreeIsolationDefaultsKey)
      Task { await kernel.setWorktreeIsolationEnabled(worktreeIsolationEnabled) }
    }
  }
  @Published var shortcutsHelpVisible = false
  /// 文件面板待定位的文件：聊天/diff 里的路径点击后跳转预览。
  @Published var revealedFileURL: URL?
  /// 次面板槽显示的面板;nil = 不显示。主区面板仍是 state.activePane
  /// (kernel 持久化),次槽是 ViewModel 本地布局,持久化在 UserDefaults。
  @Published var secondaryPane: KimiActivePane? {
    didSet {
      if let secondaryPane {
        UserDefaults.standard.set(secondaryPane.rawValue, forKey: Self.secondaryPaneDefaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: Self.secondaryPaneDefaultsKey)
      }
    }
  }
  /// 主区与次面板槽的分屏方向:true = 左右,false = 上下。持久化。
  @Published var panelSplitHorizontal: Bool {
    didSet { UserDefaults.standard.set(panelSplitHorizontal, forKey: Self.panelSplitHorizontalDefaultsKey) }
  }

  /// 面板菜单「在次面板显示」:勾选式——再点同一面板取消;与主区同面板时
  /// 主区退回会话,避免两个槽位显示同一面板。
  func showInSecondary(_ pane: KimiActivePane) {
    guard pane != .conversation else { secondaryPane = nil; return }
    if secondaryPane == pane { secondaryPane = nil; return }
    if state.activePane == pane { show(.conversation) }
    secondaryPane = pane
  }

  func closeSecondaryPane() { secondaryPane = nil }
  func togglePanelSplitOrientation() { panelSplitHorizontal.toggle() }

  /// 面板头部「返回会话/关闭面板」:按面板所在槽位路由——主区退回会话,
  /// 次槽只关闭次槽,不影响主区显示。
  func closePanel(in slot: KimiPanelSlot) {
    switch slot {
    case .primary: show(.conversation)
    case .secondary: secondaryPane = nil
    }
  }

  func toggleSidebar() { sidebarCollapsed.toggle() }
  func toggleTerminal() { terminalCollapsed.toggle() }
  func toggleShortcutsHelp() { shortcutsHelpVisible.toggle() }

  func changePermissionMode(_ mode: KimiSessionPermissionMode) {
    permissionMode = mode
    Task { await kernel.setPermissionMode(mode) }
  }

  /// ⌃O：标准 → 详细 → 精简 循环切换。
  func cycleViewMode() {
    let modes = KimiTimelineViewMode.allCases
    let index = modes.firstIndex(of: viewMode) ?? 0
    viewMode = modes[(index + 1) % modes.count]
  }

  /// 聊天消息 / diff 里的路径点击入口：相对路径按当前项目根解析，
  /// 然后切到文件面板并预览该文件。
  func navigateToFile(_ path: String) {
    let url = Self.resolveFileURL(path, projectPath: activeProjectPath)
    revealedFileURL = url
    guard state.activePane != .files else { return }
    show(.files)
  }

  /// 路径解析：绝对路径与 ~/ 直接使用，其余按项目根拼接；无项目时相对
  /// 路径无法定位，仍返回按当前工作目录解析的结果供 Finder/编辑器使用。
  nonisolated static func resolveFileURL(_ raw: String, projectPath: String?) -> URL {
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.hasPrefix("~") {
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path)
    }
    let base = projectPath ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: (base as NSString).appendingPathComponent(path))
  }

  /// 聊天里的 http(s) 链接右键「在浏览器面板中打开」:导航 + 切到 Browser 面板。
  func navigateToBrowser(url: URL) {
    browserPreview.navigate(to: url)
    guard state.activePane != .browser else { return }
    show(.browser)
  }

  /// 项目内 HTML/PDF/图片/视频路径「在浏览器面板中打开」:
  /// webview 允许读取会话 workingPath 目录,HTML 的相对资源才能加载。
  func navigateToBrowserFile(_ path: String) {
    let url = Self.resolveFileURL(path, projectPath: activeProjectPath)
    let root = activeProjectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    browserPreview.openFile(url, readAccessRoot: root)
    guard state.activePane != .browser else { return }
    show(.browser)
  }

  /// dev server 输出首次出现本地地址时自动导航;只跟随当前活跃会话,
  /// 后台会话的 server 出地址不打断用户当前浏览。
  private func handleDevServerDetectedURL(sessionID: UUID, url: URL) {
    guard sessionID == state.activeSessionID else { return }
    browserPreview.navigate(to: url)
  }

  /// ⌘⇧B：在会话与 Browser 预览面板之间切换。
  func toggleBrowserPanel() {
    show(state.activePane == .browser ? .conversation : .browser)
  }

  /// ⌘⇧D：在会话与 Diff 审阅之间切换，对应面板区的显隐。
  func toggleDiffPanel() {
    show(state.activePane == .diff ? .conversation : .diff)
  }

  func show(_ pane: KimiActivePane) {
    if pane != .conversation {
      // 面板属于单会话工作区:分屏中打开面板 = 退出分屏并聚焦该面板;
      // 面板移到主区时清空次槽,避免两槽同显。
      if secondarySessionID != nil { closeSplit() }
      if secondaryPane == pane { secondaryPane = nil }
    }
    Task {
      switch pane {
      case .conversation, .verification, .integrations, .tasks:
        try? await kernel.send(.openAuxPane(pane))
      case .diff:
        try? await kernel.send(.openDiff(UUID()))
      case .browser:
        try? await kernel.send(.openBrowser(UUID()))
      case .files:
        try? await kernel.send(.openFile(""))
      }
      await refresh()
    }
  }
}

/// 双会话分屏的焦点侧:决定侧栏普通点击替换哪一列,焦点列有顶部高亮条。
enum KimiSplitFocus {
  case primary
  case secondary
}

/// 外观偏好：跟随系统 / 浅色 / 深色，持久化在 UserDefaults，立即生效。
enum KimiAppearancePreference: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return "跟随系统"
    case .light: return "浅色"
    case .dark: return "深色"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

/// 会话时间线视图模式：标准 = 现状；详细 = 活动卡默认展开全部工具细节；
/// 精简 = 只保留用户/助手消息，活动卡全部隐藏（权限卡与问答卡始终显示）。
/// 全局生效，持久化在 UserDefaults。
enum KimiTimelineViewMode: String, CaseIterable, Identifiable {
  case standard
  case verbose
  case summary

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: return "标准"
    case .verbose: return "详细"
    case .summary: return "精简"
    }
  }
}

enum KimiDesign {
  /// 双态自适应颜色：外观（浅色/深色）在运行时解析，跟随窗口当前
  /// colorScheme，无需在调用侧做任何分支。
  static func adaptive(
    light: (r: Double, g: Double, b: Double),
    dark: (r: Double, g: Double, b: Double)
  ) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let rgb = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? dark : light
      return NSColor(calibratedRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    })
  }

  static let background = adaptive(light: (0.965, 0.973, 0.984), dark: (0.105, 0.11, 0.125))
  static let surface = adaptive(light: (1, 1, 1), dark: (0.155, 0.165, 0.185))
  static let surfaceSecondary = adaptive(light: (0.945, 0.953, 0.969), dark: (0.21, 0.22, 0.25))
  static let primary = adaptive(light: (0.10, 0.40, 0.95), dark: (0.38, 0.58, 1.0))
  static let accent = adaptive(light: (0.47, 0.35, 0.95), dark: (0.62, 0.52, 1.0))
  static let text = adaptive(light: (0.12, 0.15, 0.20), dark: (0.92, 0.93, 0.95))
  static let muted = adaptive(light: (0.44, 0.48, 0.56), dark: (0.58, 0.62, 0.69))
  static let border = adaptive(light: (0.88, 0.90, 0.93), dark: (0.30, 0.31, 0.35))
  static let diffAddedText = adaptive(light: (0.10, 0.45, 0.15), dark: (0.35, 0.80, 0.42))
  static let diffRemovedText = adaptive(light: (0.65, 0.15, 0.15), dark: (0.95, 0.50, 0.50))
  /// 代码块卡片底色与五类语法高亮色，双态自适应。
  static let codeBackground = adaptive(light: (0.94, 0.945, 0.965), dark: (0.11, 0.12, 0.145))
  static let syntaxKeyword = adaptive(light: (0.55, 0.20, 0.65), dark: (0.80, 0.58, 0.95))
  static let syntaxString = adaptive(light: (0.68, 0.16, 0.18), dark: (0.95, 0.58, 0.52))
  static let syntaxComment = adaptive(light: (0.42, 0.47, 0.52), dark: (0.50, 0.56, 0.62))
  static let syntaxNumber = adaptive(light: (0.12, 0.30, 0.72), dark: (0.55, 0.72, 1.0))
  static let syntaxType = adaptive(light: (0.05, 0.45, 0.48), dark: (0.42, 0.76, 0.72))
  static let radius: CGFloat = 12

  static func statusColor(_ status: SessionStatus) -> Color {
    switch status {
    case .running: return primary
    case .awaitingApproval: return .orange
    case .failed, .interrupted: return .red
    case .completed: return .green
    case .paused, .cancelled: return .gray
    case .idle: return Color(red: 0.62, green: 0.66, blue: 0.73)
    }
  }
}

struct KimiRootView: View {
  @ObservedObject var model: KimiAppViewModel
  @Environment(\.openSettings) private var openSettings
  @AppStorage("kimi.layout.sidebarWidth") private var sidebarWidth: Double = 260
  @AppStorage("kimi.layout.terminalWidth") private var terminalWidth: Double = 360
  @AppStorage("kimi.layout.sideChatWidth") private var sideChatWidth: Double = 340
  @State private var escapeMonitor: Any?

  var body: some View {
    HStack(spacing: 0) {
      if !model.sidebarCollapsed {
        KimiSidebarView(
          model: model,
          onOpenSettings: { openSettings() }
        )
          .frame(width: sidebarWidth)
        KimiResizeDivider(width: $sidebarWidth, range: 200...360)
      }
      if model.state.activeSessionID == nil {
        KimiHomePane(model: model)
          .frame(minWidth: 420, maxWidth: .infinity)
      } else {
        KimiWorkspacePane(model: model)
          .frame(minWidth: 420, maxWidth: .infinity)
      }
      if let sideChat = model.state.sideChat {
        KimiResizeDivider(width: $sideChatWidth, range: 280...520, inverted: true)
        KimiSideChatPane(model: model, sideChat: sideChat)
          .frame(width: sideChatWidth)
      }
      if !model.terminalCollapsed {
        KimiResizeDivider(width: $terminalWidth, range: 280...560, inverted: true)
        KimiTerminalPane(state: model.state, output: model.terminalOutput, sendInput: model.sendTerminalInput)
          .frame(width: terminalWidth)
      }
    }
    .background(KimiDesign.background)
    .preferredColorScheme(model.appearancePreference.colorScheme)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(action: model.toggleSidebar) {
          Image(systemName: "sidebar.left")
        }
        .help(model.sidebarCollapsed ? "显示侧栏 (⌘B)" : "隐藏侧栏 (⌘B)")
      }
      ToolbarItem(placement: .primaryAction) {
        Button(action: model.toggleTerminal) {
          Image(systemName: "sidebar.right")
        }
        .help(model.terminalCollapsed ? "显示终端 (⌘⇧T)" : "隐藏终端 (⌘⇧T)")
      }
    }
    // ⌃` 的备选快捷键：菜单命令里已有一个可见的 ⌘⇧T，这里用隐藏按钮补充。
    .background(
      Button("", action: model.toggleTerminal)
        .keyboardShortcut("`", modifiers: [.control])
        .hidden()
    )
    .overlay {
      if model.shortcutsHelpVisible {
        KimiShortcutsHelpOverlay(close: { model.shortcutsHelpVisible = false })
      }
    }
    .onAppear {
      installEscapeMonitor()
      // 点击系统通知跳转对应会话。
      KimiNotificationCenter.shared.onSelectSession = { [weak model] sessionID in
        model?.select(sessionID)
      }
      // No provider configured yet: open the settings window instead of a
      // forced, uncancellable modal — the user can still dismiss it, since
      // there's no good way to block "use the app" from here without also
      // reintroducing the old first-run trap.
      if !model.loadAPIKeyStatus() {
        openSettings()
      }
    }
    .onDisappear {
      if let escapeMonitor {
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
      }
    }
  }

  /// Esc = 停止当前生成。用本地事件监听而不是按钮快捷键，这样才能区分
  /// 输入框聚焦的场景：焦点在文本编辑里时 Esc 交还给输入框，不拦截。
  private func installEscapeMonitor() {
    guard escapeMonitor == nil else { return }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53 else { return event }
      if model.shortcutsHelpVisible {
        model.shortcutsHelpVisible = false
        return nil
      }
      if event.window?.firstResponder is NSTextView { return event }
      if model.isActiveSessionBusy {
        model.abortActive()
        return nil
      }
      return event
    }
  }
}

/// 三栏之间可拖拽的分隔条：1pt 视觉线 + 两侧各 3pt 的命中区域，
/// 拖拽结果经 @AppStorage 绑定直接持久化。
struct KimiResizeDivider: View {
  @Binding var width: Double
  let range: ClosedRange<Double>
  /// 右侧栏（终端）的宽度与拖拽方向相反：向左拖变宽。
  var inverted: Bool = false
  @State private var dragStartWidth: Double?

  var body: some View {
    Rectangle()
      .fill(KimiDesign.border)
      .frame(width: 1)
      .frame(maxHeight: .infinity)
      .padding(.horizontal, 3)
      .contentShape(Rectangle())
      .onHover { hovering in
        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
          .onChanged { value in
            let base = dragStartWidth ?? width
            dragStartWidth = base
            let delta = inverted ? -value.translation.width : value.translation.width
            width = min(max(base + delta, range.lowerBound), range.upperBound)
          }
          .onEnded { _ in dragStartWidth = nil }
      )
  }
}

/// 上下分屏用的水平分隔条:与 KimiResizeDivider 同构,只是拖拽改变高度。
/// 用于面板区「上下」方向的主区/次面板槽分隔。
struct KimiHorizontalResizeDivider: View {
  @Binding var height: Double
  let range: ClosedRange<Double>
  /// 下侧槽位(次面板)的高度与拖拽方向相反:向上拖变高。
  var inverted: Bool = false
  @State private var dragStartHeight: Double?

  var body: some View {
    Rectangle()
      .fill(KimiDesign.border)
      .frame(height: 1)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
      .onHover { hovering in
        if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
      }
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
          .onChanged { value in
            let base = dragStartHeight ?? height
            dragStartHeight = base
            let delta = inverted ? -value.translation.height : value.translation.height
            height = min(max(base + delta, range.lowerBound), range.upperBound)
          }
          .onEnded { _ in dragStartHeight = nil }
      )
  }
}

/// ⌘/ 呼出的快捷键帮助浮层：居中面板，列出全部快捷键。
private struct KimiShortcutsHelpOverlay: View {
  let close: () -> Void

  private static let entries: [(keys: String, action: String)] = [
    ("⌘N", "新建会话"),
    ("Esc", "停止当前生成（输入框聚焦时不拦截）"),
    ("⌘B", "折叠/展开侧栏"),
    ("⌘⇧T 或 ⌃`", "折叠/展开终端"),
    ("⌘⇧D", "显示/隐藏 Diff 面板"),
    ("⌘⇧B", "显示/隐藏 Browser 预览面板"),
    ("⌘;", "打开/关闭当前会话的侧聊"),
    ("⌘点击侧栏会话", "打开/关闭双会话分屏；分屏中普通点击替换焦点侧"),
    ("⌘\\", "关闭分屏 / 次面板 / 返回会话（层层退让）"),
    ("⌘Enter", "发送全部待提交评审意见（Diff 面板）"),
    ("⌃O", "循环切换视图模式（标准/详细/精简）"),
    ("⌘/", "键盘快捷键帮助"),
    ("⌘,", "设置"),
  ]

  var body: some View {
    ZStack {
      Color.black.opacity(0.3)
        .ignoresSafeArea()
        .onTapGesture(perform: close)
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("键盘快捷键")
            .font(.title3.weight(.semibold))
          Spacer()
          Button(action: close) {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(KimiDesign.muted)
        }
        ForEach(Self.entries, id: \.keys) { entry in
          HStack(spacing: 12) {
            Text(entry.keys)
              .font(.caption.monospaced().weight(.medium))
              .frame(minWidth: 90, alignment: .leading)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(KimiDesign.surfaceSecondary)
              .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(entry.action)
              .font(.subheadline)
              .foregroundStyle(KimiDesign.text)
            Spacer()
          }
        }
      }
      .padding(24)
      .frame(width: 420)
      .background(KimiDesign.surface)
      .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
      .overlay(
        RoundedRectangle(cornerRadius: KimiDesign.radius)
          .stroke(KimiDesign.border, lineWidth: 1)
      )
      .shadow(radius: 24)
    }
  }
}

struct KimiTerminalPane: View {
  let state: KimiUIState
  let output: String
  let sendInput: (String) -> Void
  @State private var input = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Label("终端", systemImage: "terminal")
          Spacer()
          Circle().fill(.green).frame(width: 7, height: 7)
        }
        // The pane is only 360pt wide; a status caption next to the title
        // was overflowing the window edge instead of wrapping or truncating.
        Text("本机交互终端 · 不经权限门")
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.45))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(16)
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        ScrollViewReader { proxy in
          ScrollView {
            Text(output.isEmpty ? "$ 等待命令…" : output)
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id("terminal-output")
          }
          .onChange(of: output) { _, _ in
            withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo("terminal-output", anchor: .bottom) }
          }
        }
        HStack(spacing: 6) {
          TextField("输入命令…", text: $input)
            .textFieldStyle(.plain)
            .font(.system(.footnote, design: .monospaced))
            .onSubmit {
              let command = input + "\n"
              input = ""
              sendInput(command)
            }
          Button {
            let command = input + "\n"
            input = ""
            sendInput(command)
          } label: { Image(systemName: "arrow.up.circle.fill") }
          .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      .padding(16)
    }
    .background(Color(red: 0.12, green: 0.14, blue: 0.18))
    .foregroundStyle(.white)
  }
}
