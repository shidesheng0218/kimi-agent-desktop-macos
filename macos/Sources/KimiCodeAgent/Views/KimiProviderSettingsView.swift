import SwiftUI
import KimiAgentCore

/// Settings view for managing model provider credentials. Each provider reads
/// and writes its API key into the macOS Keychain via KimiRuntimeIdentityStore,
/// keyed by provider ID (e.g. "kimi.runtime.identity.apiKey.openai").
/// Changing provider configuration requires an engine restart to take effect,
/// since OPENCODE_CONFIG_CONTENT is only read at process launch.
struct KimiProviderSettingsView: View {
  @ObservedObject var model: KimiAppViewModel
  @Binding var isPresented: Bool

  @State private var apiKeyInputs: [String: String] = [:]
  @State private var configuredProviders: Set<String> = []
  @State private var errorMessage: String? = nil
  @State private var isSaving = false

  private let identityStore = KimiRuntimeIdentityStore(vault: MacKeychainCredentialVault())

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      // Header
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: "cpu")
            .font(.title2)
            .foregroundStyle(KimiDesign.primary)
          Text("模型提供商")
            .font(.title2.weight(.semibold))
        }
        Text("为每个模型提供商配置 API 密钥。密钥安全保存在 macOS Keychain 中，不会上传任何服务器。")
          .font(.subheadline)
          .foregroundStyle(KimiDesign.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      // Provider list
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(KimiProviderCatalog.descriptors) { descriptor in
            providerRow(descriptor)
          }
        }
      }
      .frame(maxHeight: 400)

      // Restart notice
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text("更改提供商配置需要重启引擎才能生效")
          .font(.caption)
          .foregroundStyle(KimiDesign.muted)
      }
      .padding(10)
      .background(Color.orange.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      // Actions
      HStack {
        Button("取消") { isPresented = false }
          .buttonStyle(.bordered)
        Spacer()
        Button("保存并重启引擎") { saveAndRestart() }
          .buttonStyle(.borderedProminent)
          .tint(KimiDesign.primary)
          .disabled(isSaving)
      }
    }
    .padding(28)
    .frame(width: 520)
    .task {
      await loadConfiguredProviders()
    }
  }

  private func providerRow(_ descriptor: KimiProviderDescriptor) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(descriptor.displayName)
            .font(.subheadline.weight(.semibold))
          Text(descriptor.defaultBaseURL)
            .font(.caption)
            .foregroundStyle(KimiDesign.muted)
        }
        Spacer()
        if configuredProviders.contains(descriptor.id) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("已配置")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }

      HStack(spacing: 8) {
        SecureField("sk-...", text: binding(for: descriptor.id))
          .textFieldStyle(.plain)
          .font(.system(.body, design: .monospaced))
          .padding(8)
          .background(KimiDesign.surfaceSecondary)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(KimiDesign.border, lineWidth: 1)
          )

        if configuredProviders.contains(descriptor.id) {
          Button("删除") { deleteKey(for: descriptor.id) }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .font(.caption)
        }
      }

      // Model list preview
      Text("可用模型: \(descriptor.modelIDs.joined(separator: ", "))")
        .font(.caption2)
        .foregroundStyle(KimiDesign.muted)
        .lineLimit(1)
    }
    .padding(12)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
    .overlay(
      RoundedRectangle(cornerRadius: KimiDesign.radius)
        .stroke(KimiDesign.border, lineWidth: 1)
    )
  }

  private func binding(for providerID: String) -> Binding<String> {
    Binding(
      get: { apiKeyInputs[providerID] ?? "" },
      set: { apiKeyInputs[providerID] = $0 }
    )
  }

  private func loadConfiguredProviders() async {
    let ids = (try? identityStore.configuredProviderIDs()) ?? []
    configuredProviders = Set(ids)
    // Pre-fill inputs with existing keys (masked)
    for id in ids {
      if let key = try? identityStore.apiKey(for: id) {
        apiKeyInputs[id] = key
      }
    }
  }

  private func deleteKey(for providerID: String) {
    do {
      try identityStore.deleteAPIKey(for: providerID)
      configuredProviders.remove(providerID)
      apiKeyInputs[providerID] = ""
    } catch {
      errorMessage = "删除失败: \(error.localizedDescription)"
    }
  }

  private func saveAndRestart() {
    isSaving = true
    errorMessage = nil
    Task {
      do {
        // Save all non-empty keys
        for (providerID, key) in apiKeyInputs {
          let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            try identityStore.saveAPIKey(trimmed, for: providerID)
          }
        }
        // Restart the engine to pick up the new config
        try? await model.kernel.send(.restartRuntime)
        await MainActor.run {
          isSaving = false
          isPresented = false
        }
      } catch {
        await MainActor.run {
          isSaving = false
          errorMessage = "保存失败: \(error.localizedDescription)"
        }
      }
    }
  }
}
