import SwiftUI
import KimiAgentCore

/// Root of the settings window (SwiftUI `Settings` scene, bound to ⌘, and
/// the app's "Settings…" menu item). Replaces four independent sheets
/// (API key setup, provider credentials, MCP servers, hook config) with one
/// window split into categories, with a single "待生效更改" staging area
/// shared by the two categories that require an engine restart to take
/// effect (account/model and hooks) — so editing several settings in one
/// visit still only restarts the engine once.
struct KimiSettingsView: View {
  @ObservedObject var model: KimiAppViewModel
  @StateObject private var pending = PendingSettingsChanges()

  @State private var selectedCategory: KimiSettingsCategory = .account
  @State private var isApplying = false
  @State private var applyResult: ApplyResult? = nil
  @State private var showBusyConfirmation = false

  private enum ApplyResult: Equatable {
    case success
    case failure(String)
  }

  private let identityStore = KimiRuntimeIdentityStore(vault: MacKeychainCredentialVault())
  private let hookStore: KimiHookConfigStore

  init(model: KimiAppViewModel) {
    self.model = model
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Kimi Code Agent", isDirectory: true)
    self.hookStore = KimiHookConfigStore(fileURL: support.appendingPathComponent("settings/hook-config.json"))
  }

  var body: some View {
    HStack(spacing: 0) {
      // Hand-rolled sidebar instead of NavigationSplitView + List: the
      // latter's row layout collapsed to a bogus intrinsic height inside
      // this Settings scene (rows rendered off-canvas above the visible
      // area), a rendering bug specific to List inside .sheet-less Settings
      // windows. A plain VStack of buttons is what the rest of this app's
      // sidebar (KimiSidebarView) already uses, so it's a known-good pattern
      // here too.
      VStack(alignment: .leading, spacing: 4) {
        ForEach(KimiSettingsCategory.allCases) { category in
          categoryRow(category)
        }
        Spacer()
      }
      .padding(12)
      .frame(width: KimiSettingsLayout.sidebarWidth)
      .background(KimiDesign.surfaceSecondary)

      Divider()

      VStack(alignment: .leading, spacing: 0) {
        Text(selectedCategory.title)
          .font(.title2.weight(.semibold))
          .padding(.horizontal, KimiSettingsLayout.contentPadding)
          .padding(.top, KimiSettingsLayout.contentPadding)
          .padding(.bottom, 12)

        Group {
          switch selectedCategory {
          case .account:
            KimiAccountSettingsPane(model: model, pending: pending)
          case .mcp:
            KimiMCPSettingsPane(model: model)
          case .hooks:
            KimiHookSettingsPane(pending: pending)
          }
        }
        .padding(.horizontal, KimiSettingsLayout.contentPadding)
        .disabled(isApplying)

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: KimiSettingsLayout.windowWidth, height: KimiSettingsLayout.windowHeight)
    .safeAreaInset(edge: .bottom) {
      if pending.isDirty || applyResult != nil {
        pendingChangesBar
      }
    }
    .alert("会话正在运行", isPresented: $showBusyConfirmation) {
      Button("取消", role: .cancel) {}
      Button("继续应用", role: .destructive) {
        Task { await performApply(force: true) }
      }
    } message: {
      Text("应用更改将重启引擎并中断当前正在运行的任务，确定继续？")
    }
  }

  private func categoryRow(_ category: KimiSettingsCategory) -> some View {
    Button {
      selectedCategory = category
    } label: {
      HStack(spacing: 8) {
        Image(systemName: category.icon)
          .frame(width: 18)
        Text(category.title)
          .font(.subheadline)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selectedCategory == category ? KimiDesign.surface : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(selectedCategory == category ? KimiDesign.text : KimiDesign.muted)
  }

  private var pendingChangesBar: some View {
    HStack(spacing: 12) {
      switch applyResult {
      case .success:
        Label("设置已应用", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .font(.subheadline)
      case .failure(let message):
        Label(message, systemImage: "exclamationmark.circle.fill")
          .foregroundStyle(.red)
          .font(.caption)
          .lineLimit(2)
      case nil:
        Text("有 \(pending.pendingCount) 项更改待生效")
          .font(.subheadline)
          .foregroundStyle(KimiDesign.muted)
      }

      Spacer()

      if pending.isDirty {
        Button("放弃更改") {
          pending.discard()
          applyResult = nil
        }
        .buttonStyle(.bordered)
        .disabled(isApplying)

        Button {
          Task { await requestApply() }
        } label: {
          if isApplying {
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("应用中…")
            }
          } else {
            Text("应用更改")
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(KimiDesign.primary)
        .disabled(isApplying)
      }
    }
    .padding(.horizontal, KimiSettingsLayout.contentPadding)
    .padding(.vertical, 14)
    .background(KimiDesign.surfaceSecondary)
  }

  private func requestApply() async {
    applyResult = nil
    if model.isActiveSessionBusy {
      showBusyConfirmation = true
      return
    }
    await performApply(force: false)
  }

  private func performApply(force: Bool) async {
    isApplying = true
    defer { isApplying = false }
    do {
      try await pending.apply(model: model, identityStore: identityStore, hookStore: hookStore)
      applyResult = .success
      Task {
        try? await Task.sleep(for: .seconds(2))
        if applyResult == .success { applyResult = nil }
      }
    } catch {
      applyResult = .failure("应用失败: \(error.localizedDescription)")
    }
  }
}
