import SwiftUI
import KimiAgentCore

/// Sheet shown when the user needs to enter or update their Moonshot API key.
/// Writes the key to the macOS Keychain via KimiRuntimeIdentityStore and
/// triggers an engine restart so it takes effect immediately.
struct KimiAPIKeySetupView: View {
  @ObservedObject var model: KimiAppViewModel
  @Binding var isPresented: Bool

  @State private var apiKeyInput = ""
  @State private var isSaving = false
  @State private var errorMessage: String? = nil
  @FocusState private var inputFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      // Header
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Image(systemName: "key.fill")
            .font(.title2)
            .foregroundStyle(KimiDesign.primary)
          Text("配置 API 密钥")
            .font(.title2.weight(.semibold))
        }
        Text("输入你的 Moonshot API 密钥以开始使用 Kimi Code Agent。密钥会安全保存在 macOS Keychain 中，不会上传任何服务器。")
          .font(.subheadline)
          .foregroundStyle(KimiDesign.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      // Input
      VStack(alignment: .leading, spacing: 6) {
        Text("API 密钥")
          .font(.caption.weight(.medium))
          .foregroundStyle(KimiDesign.muted)
        SecureField("sk-...", text: $apiKeyInput)
          .textFieldStyle(.plain)
          .font(.system(.body, design: .monospaced))
          .focused($inputFocused)
          .padding(10)
          .background(KimiDesign.surfaceSecondary)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(errorMessage != nil ? Color.red : KimiDesign.border, lineWidth: 1)
          )
          .onSubmit { save() }

        if let error = errorMessage {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.circle")
            Text(error)
          }
          .font(.caption)
          .foregroundStyle(.red)
        }

        // Link to Moonshot console
        Link(destination: URL(string: "https://platform.moonshot.cn/console/api-keys")!) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.up.right.square")
            Text("从 Moonshot 控制台获取密钥")
          }
          .font(.caption)
          .foregroundStyle(KimiDesign.primary)
        }
      }

      // Actions
      HStack {
        if !model.loadAPIKeyStatus() {
          // First-time setup — can't cancel
          Spacer()
        } else {
          Button("取消") { isPresented = false }
            .buttonStyle(.bordered)
          Spacer()
        }
        Button(action: save) {
          if isSaving {
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("保存中…")
            }
          } else {
            Text("保存并重启引擎")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(KimiDesign.primary)
        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
      }
    }
    .padding(28)
    .frame(width: 440)
    .onAppear { inputFocused = true }
  }

  private func save() {
    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    isSaving = true
    errorMessage = nil
    // saveAPIKey runs synchronously (Keychain) then fires an async restart
    model.saveAPIKey(trimmed)
    // Dismiss after a brief delay so the user sees the saving state
    Task {
      try? await Task.sleep(for: .milliseconds(600))
      await MainActor.run {
        isSaving = false
        isPresented = false
      }
    }
  }
}
