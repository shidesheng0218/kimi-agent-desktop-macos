import SwiftUI
import KimiAgentCore

/// Draft state shared by the settings panes that require an engine restart
/// to take effect (account/model and hooks). Each pane writes its draft here
/// as the user edits, instead of writing to Keychain/disk and restarting
/// immediately — this is what lets "改三处设置" collapse into one restart
/// instead of three. MCP server changes are intentionally excluded: adding
/// or removing a server already takes effect at runtime without a restart,
/// so it has nothing to stage here.
@MainActor
final class PendingSettingsChanges: ObservableObject {
  struct AccountDraft: Equatable {
    /// providerID -> new key value. A provider present here with an empty
    /// string means "delete this credential" (mirrors the old delete button).
    var apiKeys: [String: String] = [:]

    var isEmpty: Bool { apiKeys.isEmpty }
  }

  @Published var accountDraft = AccountDraft()
  @Published var hookDraft: KimiHookConfiguration?
  private var hookBaseline: KimiHookConfiguration?

  var isDirty: Bool {
    !accountDraft.isEmpty || (hookDraft != nil && hookDraft != hookBaseline)
  }

  var pendingCount: Int {
    accountDraft.apiKeys.count + ((hookDraft != nil && hookDraft != hookBaseline) ? 1 : 0)
  }

  func setHookBaseline(_ configuration: KimiHookConfiguration) {
    hookBaseline = configuration
    hookDraft = configuration
  }

  func updateHookDraft(_ configuration: KimiHookConfiguration) {
    hookDraft = configuration
  }

  func setAccountKey(_ value: String, for providerID: String, baseline: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == baseline.trimmingCharacters(in: .whitespacesAndNewlines) {
      accountDraft.apiKeys.removeValue(forKey: providerID)
    } else {
      accountDraft.apiKeys[providerID] = trimmed
    }
  }

  func discard() {
    accountDraft = AccountDraft()
    hookDraft = hookBaseline
  }

  /// Writes every staged draft to its store, then triggers exactly one
  /// engine restart if anything actually changed. Returns without restarting
  /// when there is nothing dirty (callers still show the "applied" state).
  func apply(model: KimiAppViewModel, identityStore: KimiRuntimeIdentityStore, hookStore: KimiHookConfigStore) async throws {
    var needsRestart = false

    for (providerID, value) in accountDraft.apiKeys {
      if value.isEmpty {
        try identityStore.deleteAPIKey(for: providerID)
      } else {
        try identityStore.saveAPIKey(value, for: providerID)
      }
      needsRestart = true
    }

    if let hookDraft, hookDraft != hookBaseline {
      try hookStore.save(hookDraft)
      hookBaseline = hookDraft
      needsRestart = true
    }

    accountDraft = AccountDraft()

    guard needsRestart else { return }
    try await model.kernel.send(.restartRuntime)
    await model.refresh()
  }
}
