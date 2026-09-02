import SwiftUI
import KimiAgentCore

/// Merges what used to be two separate sheets (first-run API key setup, and
/// the per-provider credentials list) into one pane. Both edited the same
/// Keychain bucket for KimiRuntimeIdentityStore.providerID without knowing
/// about each other; this pane always pins that provider's row first and
/// gives it the first-run guidance copy when it has no credential yet.
///
/// Edits here are staged into PendingSettingsChanges rather than written to
/// Keychain immediately — the engine only reads credentials at process
/// launch, so nothing takes effect until the settings window's "应用更改"
/// commits the draft and restarts once.
struct KimiAccountSettingsPane: View {
  @ObservedObject var model: KimiAppViewModel
  @ObservedObject var pending: PendingSettingsChanges

  @State private var apiKeyInputs: [String: String] = [:]
  @State private var baselineKeys: [String: String] = [:]
  @State private var configuredProviders: Set<String> = []

  private let identityStore = KimiRuntimeIdentityStore(vault: MacKeychainCredentialVault())

  private var defaultProviderID: String { KimiRuntimeIdentityStore.providerID }

  private var orderedDescriptors: [KimiProviderDescriptor] {
    guard let defaultDescriptor = KimiProviderCatalog.descriptor(for: defaultProviderID) else {
      return KimiProviderCatalog.descriptors
    }
    let rest = KimiProviderCatalog.descriptors.filter { $0.id != defaultProviderID }
    return [defaultDescriptor] + rest
  }

  var body: some View {
    VStack(alignment: .leading, spacing: KimiSettingsLayout.sectionSpacing) {
      Text("为每个模型提供商配置 API 密钥。密钥安全保存在 macOS Keychain 中，不会上传任何服务器。更改需要点击底部“应用更改”才会生效。")
        .font(.subheadline)
        .foregroundStyle(KimiDesign.muted)
        .fixedSize(horizontal: false, vertical: true)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(orderedDescriptors) { descriptor in
            providerRow(descriptor)
          }
        }
      }
      .frame(maxHeight: KimiSettingsLayout.maxScrollHeight)
    }
    .task {
      await loadConfiguredProviders()
    }
  }

  private func providerRow(_ descriptor: KimiProviderDescriptor) -> some View {
    let isDefault = descriptor.id == defaultProviderID
    let isConfigured = configuredProviders.contains(descriptor.id)
    let needsFirstRunGuidance = isDefault && !isConfigured

    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(descriptor.displayName)
              .font(.subheadline.weight(.semibold))
            if isDefault {
              Text("当前默认")
                .font(.caption2.weight(.medium))
                .foregroundStyle(KimiDesign.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(KimiDesign.primary.opacity(0.12))
                .clipShape(Capsule())
            }
          }
          Text(descriptor.defaultBaseURL)
            .font(.caption)
            .foregroundStyle(KimiDesign.muted)
        }
        Spacer()
        if isConfigured {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          Text("已配置")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }

      if needsFirstRunGuidance {
        Text("输入你的 Moonshot API 密钥以开始使用 Kimi Code Agent。")
          .font(.caption)
          .foregroundStyle(KimiDesign.muted)
        Link(destination: URL(string: "https://platform.moonshot.cn/console/api-keys")!) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.up.right.square")
            Text("从 Moonshot 控制台获取密钥")
          }
          .font(.caption)
          .foregroundStyle(KimiDesign.primary)
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

        if isConfigured {
          Button("删除") { stageDeletion(for: descriptor.id) }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .font(.caption)
        }

        if pending.accountDraft.apiKeys[descriptor.id] != nil {
          Text("待应用")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }

      Text("可用模型: \(descriptor.modelIDs.joined(separator: ", "))")
        .font(.caption2)
        .foregroundStyle(KimiDesign.muted)
        .lineLimit(1)
    }
    .padding(12)
    .background(needsFirstRunGuidance ? KimiDesign.primary.opacity(0.06) : KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
    .overlay(
      RoundedRectangle(cornerRadius: KimiDesign.radius)
        .stroke(needsFirstRunGuidance ? KimiDesign.primary.opacity(0.4) : KimiDesign.border, lineWidth: 1)
    )
  }

  private func binding(for providerID: String) -> Binding<String> {
    Binding(
      get: { apiKeyInputs[providerID] ?? "" },
      set: { newValue in
        apiKeyInputs[providerID] = newValue
        pending.setAccountKey(newValue, for: providerID, baseline: baselineKeys[providerID] ?? "")
      }
    )
  }

  private func stageDeletion(for providerID: String) {
    apiKeyInputs[providerID] = ""
    pending.setAccountKey("", for: providerID, baseline: baselineKeys[providerID] ?? "")
  }

  private func loadConfiguredProviders() async {
    let ids = (try? identityStore.configuredProviderIDs()) ?? []
    configuredProviders = Set(ids)
    for id in ids {
      if let key = try? identityStore.apiKey(for: id) {
        apiKeyInputs[id] = key
        baselineKeys[id] = key
      }
    }
  }
}
