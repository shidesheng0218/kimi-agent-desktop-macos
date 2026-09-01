import SwiftUI
import KimiAgentCore

/// Declarative hook configuration panel. Every control here maps to one of
/// the four flat JSON knobs the engine's kimi-code-agent-plugin reads from
/// its plugin options tuple (KimiHookConfiguration.toEngineOptions()) — no
/// field accepts code, only text/toggles. Mirrors KimiMCPServersView's
/// load/edit/save-and-restart shape.
struct KimiHookSettingsView: View {
  @ObservedObject var model: KimiAppViewModel
  @Binding var isPresented: Bool

  @State private var systemPromptRules: [String] = []
  @State private var newRuleText = ""
  @State private var permissionOverrides: [String: KimiHookPermissionOverride] = [:]
  @State private var webFetchAllowedDomainsText = ""
  @State private var toolOutputCharLimits: [String: Int] = [:]
  @State private var bashOutputLimitText = ""
  @State private var errorMessage: String? = nil
  @State private var isSaving = false

  private let store: KimiHookConfigStore
  private static let presetRules = ["总是用简体中文回复", "回复保持简洁，避免不必要的重复", "优先给出可执行的代码而不是纯文字建议"]
  private static let overridableTools = ["bash", "edit", "webfetch", "external_directory"]

  init(model: KimiAppViewModel, isPresented: Binding<Bool>) {
    self.model = model
    self._isPresented = isPresented
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Kimi Code Agent", isDirectory: true)
    self.store = KimiHookConfigStore(fileURL: support.appendingPathComponent("settings/hook-config.json"))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          systemPromptSection
          permissionSection
          webFetchSection
          toolOutputSection
        }
      }
      .frame(maxHeight: 440)
      if let errorMessage {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.circle")
          Text(errorMessage)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      HStack {
        Button("关闭") { isPresented = false }
          .buttonStyle(.bordered)
        Spacer()
        Button("保存并重启引擎") { saveAndRestart() }
          .buttonStyle(.borderedProminent)
          .tint(KimiDesign.primary)
          .disabled(isSaving)
      }
    }
    .padding(24)
    .frame(width: 560)
    .task { load() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "slider.horizontal.below.rectangle")
          .font(.title2)
          .foregroundStyle(KimiDesign.primary)
        Text("高级行为规则")
          .font(.title2.weight(.semibold))
      }
      Text("配置引擎的系统提示词追加、权限覆盖、网页访问范围与工具输出上限。这里不能上传代码，只能勾选和填参数。")
        .font(.subheadline)
        .foregroundStyle(KimiDesign.muted)
    }
  }

  // MARK: - System prompt rules

  private var systemPromptSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("系统提示词追加规则", systemImage: "text.bubble")
      Text("追加到每轮对话的系统提示词末尾，用于约束语言、语气或格式偏好。")
        .font(.caption)
        .foregroundStyle(KimiDesign.muted)

      ForEach(Self.presetRules, id: \.self) { preset in
        Toggle(preset, isOn: presetBinding(for: preset))
          .toggleStyle(.checkbox)
          .font(.subheadline)
      }

      ForEach(customRules, id: \.self) { rule in
        HStack {
          Text(rule).font(.caption.monospaced())
          Spacer()
          Button {
            systemPromptRules.removeAll { $0 == rule }
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(KimiDesign.muted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(KimiDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }

      HStack {
        TextField("自定义规则，例如：回答时标注置信度", text: $newRuleText)
          .textFieldStyle(.roundedBorder)
        Button("添加") {
          let trimmed = newRuleText.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty, !systemPromptRules.contains(trimmed) else { return }
          systemPromptRules.append(trimmed)
          newRuleText = ""
        }
        .disabled(newRuleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private var customRules: [String] {
    systemPromptRules.filter { !Self.presetRules.contains($0) }
  }

  private func presetBinding(for preset: String) -> Binding<Bool> {
    Binding(
      get: { systemPromptRules.contains(preset) },
      set: { isOn in
        if isOn {
          if !systemPromptRules.contains(preset) { systemPromptRules.append(preset) }
        } else {
          systemPromptRules.removeAll { $0 == preset }
        }
      }
    )
  }

  private func sectionTitle(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage).font(.caption)
      Text(title).font(.subheadline.weight(.semibold))
    }
  }

  // MARK: - Permission overrides

  private var permissionSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("工具权限覆盖", systemImage: "hand.raised")
      Text("命中的工具会跳过审批卡片，直接按此处的设定执行。未设置的工具保持引擎默认策略。")
        .font(.caption)
        .foregroundStyle(KimiDesign.muted)

      ForEach(Self.overridableTools, id: \.self) { toolID in
        HStack {
          Text(toolID).font(.caption.monospaced())
          Spacer()
          Picker("", selection: overrideBinding(for: toolID)) {
            Text("默认（询问）").tag(Optional<KimiHookPermissionOverride>.none)
            ForEach(KimiHookPermissionOverride.allCases, id: \.self) { override in
              Text(override.displayName).tag(Optional(override))
            }
          }
          .pickerStyle(.menu)
          .frame(width: 140)
        }
      }
    }
  }

  private func overrideBinding(for toolID: String) -> Binding<KimiHookPermissionOverride?> {
    Binding(
      get: { permissionOverrides[toolID] },
      set: { newValue in
        if let newValue { permissionOverrides[toolID] = newValue } else { permissionOverrides.removeValue(forKey: toolID) }
      }
    )
  }

  // MARK: - Webfetch domain allowlist

  private var webFetchSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("网页访问域名白名单", systemImage: "globe")
      Text("每行一个域名（含子域名自动放行），留空表示不限制。webfetch 工具访问不在名单内的域名会被引擎拒绝。")
        .font(.caption)
        .foregroundStyle(KimiDesign.muted)
      TextEditor(text: $webFetchAllowedDomainsText)
        .font(.caption.monospaced())
        .frame(height: 70)
        .padding(6)
        .background(KimiDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  // MARK: - Tool output limits

  private var toolOutputSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionTitle("工具输出字符数上限", systemImage: "text.alignleft")
      Text("超出上限的 bash 工具输出会被截断并附加提示，避免超长输出占满上下文。留空表示不限制。")
        .font(.caption)
        .foregroundStyle(KimiDesign.muted)
      HStack {
        Text("bash").font(.caption.monospaced())
        Spacer()
        TextField("例如 4000", text: $bashOutputLimitText)
          .textFieldStyle(.roundedBorder)
          .frame(width: 140)
      }
    }
  }

  // MARK: - Load / Save

  private func load() {
    guard let configuration = try? store.load() else { return }
    systemPromptRules = configuration.systemPromptRules
    permissionOverrides = configuration.permissionOverrides
    webFetchAllowedDomainsText = configuration.webFetchAllowedDomains.joined(separator: "\n")
    toolOutputCharLimits = configuration.toolOutputCharLimits
    bashOutputLimitText = configuration.toolOutputCharLimits["bash"].map(String.init) ?? ""
  }

  private func saveAndRestart() {
    isSaving = true
    errorMessage = nil
    let domains = webFetchAllowedDomainsText
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    var limits = toolOutputCharLimits
    if let bashLimit = Int(bashOutputLimitText.trimmingCharacters(in: .whitespaces)), bashLimit > 0 {
      limits["bash"] = bashLimit
    } else {
      limits.removeValue(forKey: "bash")
    }
    let configuration = KimiHookConfiguration(
      systemPromptRules: systemPromptRules,
      permissionOverrides: permissionOverrides,
      webFetchAllowedDomains: domains,
      toolOutputCharLimits: limits
    )
    do {
      try store.save(configuration)
      Task {
        try? await model.kernel.send(.restartRuntime)
        await model.refresh()
        await MainActor.run { isSaving = false }
      }
    } catch {
      errorMessage = "保存失败：\(error.localizedDescription)"
      isSaving = false
    }
  }
}
