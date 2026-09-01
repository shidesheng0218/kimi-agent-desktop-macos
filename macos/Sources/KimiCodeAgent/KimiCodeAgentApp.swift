import SwiftUI
import AppKit
import KimiAgentCore
import Sparkle

final class KimiAppDelegate: NSObject, NSApplicationDelegate {
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
        // KimiRootView's three panes have their own minimums (260 sidebar +
        // 540 workspace + 360 terminal + 2 dividers = 1162): the window's own
        // minimum must be at least that or shrinking toward it clips content.
        .frame(minWidth: 1_180, minHeight: 760)
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
    }
  }
}

@MainActor
final class KimiAppViewModel: ObservableObject {
  @Published private(set) var state = KimiUIState()
  @Published var composerText = ""
  @Published private(set) var terminalOutput = ""
  @Published private(set) var terminalSessionID: UUID?
  @Published private(set) var homeStats = KimiHomeStats()
  @Published private(set) var diffSnapshot: DiffSnapshot?
  @Published private(set) var diffLoading = false
  @Published private(set) var integrationStatus = KimiIntegrationStatus()
  @Published private(set) var verificationRecords: [KimiVerificationRecord] = []

  let kernel: KimiAppKernel
  let terminalController: KimiTerminalController
  private var eventTask: Task<Void, Never>?
  private var terminalPollTask: Task<Void, Never>?

  init(kernel: KimiAppKernel? = nil) {
    self.kernel = kernel ?? Self.makeDefaultKernel()
    self.terminalController = KimiTerminalController()
    eventTask = Task { [weak self] in
      guard let self else { return }
      let stream = await self.kernel.events()
      for await event in stream {
        _ = event
        let next = await self.kernel.snapshot()
        await MainActor.run { [weak self] in self?.state = next }
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
    await kernel.startRuntime()
    await refresh()
    await startTerminalIfNeeded()
  }

  func startTerminalIfNeeded() async {
    guard terminalSessionID == nil else { return }
    let cwd = state.sessions.first(where: { $0.id == state.activeSessionID })?.projectPath
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
  }

  func loadHomeStats(range: KimiUsageStatsRange) async {
    homeStats = await kernel.homeStats(range: range)
  }

  var activeProjectPath: String? {
    state.sessions.first(where: { $0.id == state.activeSessionID })?.projectPath
  }

  func loadDiff() async {
    diffLoading = true
    diffSnapshot = await kernel.loadDiffSnapshot()
    diffLoading = false
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

  /// Returns true when a non-empty API key is saved in the credential vault.
  @MainActor
  func loadAPIKeyStatus() -> Bool {
    let vault = MacKeychainCredentialVault()
    return (try? vault.read(key: "kimi.runtime.identity.apiKey"))?
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  /// Saves the key to the Keychain and restarts the engine so it takes effect.
  func saveAPIKey(_ apiKey: String) {
    let vault = MacKeychainCredentialVault()
    let store = KimiRuntimeIdentityStore(vault: vault)
    do {
      try store.connectAPI(apiKey: apiKey)
      Task {
        try? await kernel.send(.restartRuntime)
        await refresh()
      }
    } catch {
      Task { @MainActor in
        self.state.lastError = "API 密钥保存失败：\(error.localizedDescription)"
      }
    }
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
    guard !text.isEmpty else { return }
    // No session yet and no known project: pick the project first so the
    // implicit session lands in real user code.
    if state.activeSessionID == nil, state.recentProjects.isEmpty {
      guard let directory = pickProjectDirectory() else { return }
      composerText = ""
      Task {
        try? await kernel.send(.createSession(directory: directory.path))
        try? await kernel.send(.prompt(PromptInput(text: text)))
        await refresh()
      }
      return
    }
    composerText = ""
    Task {
      // Slash commands route to the engine's command endpoint; unknown slash
      // text falls through to a normal prompt.
      if text.hasPrefix("/") {
        let body = String(text.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        if let name = parts.first, state.availableCommands.contains(where: { $0.name == name }) {
          try? await kernel.send(.runSlashCommand(name: name, arguments: parts.count > 1 ? parts[1] : ""))
          await refresh()
          return
        }
      }
      // While the session is executing, a submitted message steers the
      // running turn instead of failing on a busy lane.
      if isActiveSessionBusy {
        try? await kernel.send(.steer(PromptInput(text: text)))
      } else {
        try? await kernel.send(.prompt(PromptInput(text: text)))
      }
      await refresh()
    }
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
      try? await kernel.send(.followUp(PromptInput(text: text)))
      await refresh()
    }
  }

  func show(_ pane: KimiActivePane) {
    Task {
      switch pane {
      case .conversation:
        break
      case .diff:
        try? await kernel.send(.openDiff(UUID()))
      case .browser:
        try? await kernel.send(.openBrowser(UUID()))
      case .files:
        try? await kernel.send(.openFile(""))
      case .verification, .integrations:
        state.activePane = pane
      }
      await refresh()
    }
  }
}

enum KimiDesign {
  static let background = Color(red: 0.965, green: 0.973, blue: 0.984)
  static let surface = Color.white
  static let surfaceSecondary = Color(red: 0.945, green: 0.953, blue: 0.969)
  static let primary = Color(red: 0.10, green: 0.40, blue: 0.95)
  static let accent = Color(red: 0.47, green: 0.35, blue: 0.95)
  static let text = Color(red: 0.12, green: 0.15, blue: 0.20)
  static let muted = Color(red: 0.44, green: 0.48, blue: 0.56)
  static let border = Color(red: 0.88, green: 0.90, blue: 0.93)
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
  @State private var showAPIKeySetup = false
  @State private var showProviderSettings = false
  @State private var showMCPServers = false
  @State private var showHookSettings = false

  var body: some View {
    HStack(spacing: 0) {
      KimiSidebarView(
        model: model,
        onConfigureAPIKey: { showAPIKeySetup = true },
        onConfigureProviders: { showProviderSettings = true },
        onConfigureMCPServers: { showMCPServers = true },
        onConfigureHooks: { showHookSettings = true }
      )
        .frame(width: 260)
      Divider()
      if model.state.activeSessionID == nil {
        KimiHomePane(model: model)
          .frame(minWidth: 540, maxWidth: .infinity)
      } else {
        KimiWorkspacePane(model: model)
          .frame(minWidth: 540, maxWidth: .infinity)
      }
      Divider()
      KimiTerminalPane(state: model.state, output: model.terminalOutput, sendInput: model.sendTerminalInput)
        .frame(width: 360)
    }
    .background(KimiDesign.background)
    .preferredColorScheme(.light)
    .sheet(isPresented: $showAPIKeySetup) {
      KimiAPIKeySetupView(model: model, isPresented: $showAPIKeySetup)
    }
    .sheet(isPresented: $showProviderSettings) {
      KimiProviderSettingsView(model: model, isPresented: $showProviderSettings)
    }
    .sheet(isPresented: $showMCPServers) {
      KimiMCPServersView(model: model, isPresented: $showMCPServers)
    }
    .sheet(isPresented: $showHookSettings) {
      KimiHookSettingsView(model: model, isPresented: $showHookSettings)
    }
    .onAppear {
      // Auto-show setup if no key is configured
      if !model.loadAPIKeyStatus() {
        showAPIKeySetup = true
      }
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
