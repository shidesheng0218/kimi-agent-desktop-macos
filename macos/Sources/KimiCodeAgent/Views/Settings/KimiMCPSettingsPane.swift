import SwiftUI
import KimiAgentCore

/// MCP server management pane. Every add/edit/remove takes effect
/// immediately at runtime (POST /mcp, POST /mcp/{name}/disconnect) and is
/// also persisted to disk so it survives the next engine relaunch — there is
/// nothing here that needs the "pending changes, apply once" flow the
/// account and hooks panes use, so this pane has no draft state and no
/// restart button.
struct KimiMCPSettingsPane: View {
  @ObservedObject var model: KimiAppViewModel

  @State private var servers: [KimiMCPServerEntry] = []
  @State private var mcpStatuses: [KimiMcpServerStatus] = []
  @State private var editingServer: KimiMCPServerEntry? = nil
  @State private var showEditor = false
  @State private var errorMessage: String? = nil
  @State private var serverPendingDeletion: KimiMCPServerEntry? = nil

  private let mcpStore: KimiMCPServerStore

  init(model: KimiAppViewModel) {
    self.model = model
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Kimi Code Agent", isDirectory: true)
    self.mcpStore = KimiMCPServerStore(fileURL: support.appendingPathComponent("settings/mcp-servers.json"))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: KimiSettingsLayout.sectionSpacing) {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Text("管理 Model Context Protocol 服务器。本地命令通过 stdio 连接，远程服务通过 HTTP/SSE 连接。改动立即生效，无需重启引擎。")
            .font(.subheadline)
            .foregroundStyle(KimiDesign.muted)
        }
        Spacer()
        Button(action: { addNewServer() }) {
          Label("添加服务器", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(KimiDesign.primary)
      }

      ScrollView {
        if servers.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "server.rack")
              .font(.system(size: 40))
              .foregroundStyle(KimiDesign.muted.opacity(0.4))
            Text("还没有配置 MCP 服务器")
              .font(.subheadline)
              .foregroundStyle(KimiDesign.muted)
            Text("点击\"添加服务器\"开始配置")
              .font(.caption)
              .foregroundStyle(KimiDesign.muted)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 60)
        } else {
          LazyVStack(spacing: KimiSettingsLayout.itemSpacing) {
            ForEach(servers) { server in
              serverRow(server)
            }
          }
        }
      }
      .frame(maxHeight: KimiSettingsLayout.maxScrollHeight)

      if let error = errorMessage {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.circle")
          Text(error)
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: KimiSettingsLayout.cornerRadius))
      }
    }
    .task {
      await loadServers()
      await loadStatuses()
    }
    .sheet(isPresented: $showEditor) {
      if let editing = editingServer {
        KimiMCPServerEditorView(
          server: editing,
          onSave: { updated in
            saveServer(updated)
            showEditor = false
          },
          onCancel: { showEditor = false }
        )
      }
    }
    .alert(
      "删除 MCP 服务器？",
      isPresented: Binding(
        get: { serverPendingDeletion != nil },
        set: { if !$0 { serverPendingDeletion = nil } }
      ),
      presenting: serverPendingDeletion
    ) { server in
      Button("删除", role: .destructive) { confirmDelete(server) }
      Button("取消", role: .cancel) { serverPendingDeletion = nil }
    } message: { server in
      Text("将立即断开并删除“\(server.id)”，此操作无法撤销。")
    }
  }

  private func serverRow(_ server: KimiMCPServerEntry) -> some View {
    let status = mcpStatuses.first { $0.name == server.id }
    return HStack(spacing: 12) {
      Circle()
        .fill(statusColor(status?.status))
        .frame(width: 10, height: 10)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(server.id)
            .font(.subheadline.weight(.semibold))
          if !server.enabled {
            Text("已禁用")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.15))
              .clipShape(Capsule())
          }
        }
        Text(serverDescription(server))
          .font(.caption)
          .foregroundStyle(KimiDesign.muted)
          .lineLimit(1)
        if let status = status {
          Text(status.status)
            .font(.caption2)
            .foregroundStyle(statusColor(status.status))
        }
      }

      Spacer()

      HStack(spacing: 8) {
        Button("编辑") { editServer(server) }
          .buttonStyle(.borderless)
          .font(.caption)
        Button("删除") { serverPendingDeletion = server }
          .buttonStyle(.borderless)
          .foregroundStyle(.red)
          .font(.caption)
      }
    }
    .padding(12)
    .background(KimiDesign.surface)
    .clipShape(RoundedRectangle(cornerRadius: KimiDesign.radius))
    .overlay(
      RoundedRectangle(cornerRadius: KimiDesign.radius)
        .stroke(KimiDesign.border, lineWidth: 1)
    )
  }

  private func serverDescription(_ server: KimiMCPServerEntry) -> String {
    switch server.transport {
    case .local:
      return "本地命令: \(server.command?.joined(separator: " ") ?? "未设置")"
    case .remote:
      return "远程服务: \(server.url ?? "未设置")"
    }
  }

  private func statusColor(_ status: String?) -> Color {
    switch status {
    case "running", "connected", "healthy": return .green
    case "starting", "connecting": return .orange
    case "failed", "error": return .red
    default: return .secondary
    }
  }

  private func loadServers() async {
    servers = (try? mcpStore.load()) ?? []
  }

  private func loadStatuses() async {
    mcpStatuses = await model.kernel.loadIntegrationStatus().mcpServers
  }

  private func addNewServer() {
    editingServer = KimiMCPServerEntry(
      id: "server-\(servers.count + 1)",
      transport: .local,
      enabled: true,
      command: []
    )
    showEditor = true
  }

  private func editServer(_ server: KimiMCPServerEntry) {
    editingServer = server
    showEditor = true
  }

  /// Persists to the on-disk config (so it survives the next engine
  /// relaunch) and, if the server is enabled, also tries the engine's live
  /// `POST /mcp` endpoint so it connects immediately without a restart. The
  /// runtime add is best-effort: if the engine rejects it, the entry is
  /// still saved to disk and will be picked up on the next restart.
  private func saveServer(_ server: KimiMCPServerEntry) {
    do {
      try mcpStore.add(server)
      servers = (try? mcpStore.load()) ?? []
      errorMessage = nil
    } catch {
      errorMessage = "保存失败: \(error.localizedDescription)"
      return
    }
    guard server.enabled else { return }
    Task {
      do {
        try await model.kernel.addMCPServerAtRuntime(server)
        await loadStatuses()
      } catch {
        await MainActor.run {
          errorMessage = "已保存，但立即连接失败（将在下次重启引擎时生效）: \(error.localizedDescription)"
        }
      }
    }
  }

  private func confirmDelete(_ server: KimiMCPServerEntry) {
    serverPendingDeletion = nil
    deleteServer(server)
  }

  /// Removes from the on-disk config and, best-effort, disconnects it from
  /// the running engine immediately via `POST /mcp/{name}/disconnect` so it
  /// stops appearing as connected without requiring a restart.
  private func deleteServer(_ server: KimiMCPServerEntry) {
    do {
      try mcpStore.remove(id: server.id)
      servers = (try? mcpStore.load()) ?? []
      errorMessage = nil
    } catch {
      errorMessage = "删除失败: \(error.localizedDescription)"
      return
    }
    Task {
      do {
        try await model.kernel.removeMCPServerAtRuntime(name: server.id)
        await loadStatuses()
      } catch {
        await MainActor.run {
          errorMessage = "已删除配置，但断开运行中的连接失败: \(error.localizedDescription)"
        }
      }
    }
  }
}

/// Editor form for a single MCP server entry.
struct KimiMCPServerEditorView: View {
  @State private var server: KimiMCPServerEntry
  let onSave: (KimiMCPServerEntry) -> Void
  let onCancel: () -> Void

  @State private var commandText: String = ""
  @State private var environmentText: String = ""
  @State private var headersText: String = ""

  init(server: KimiMCPServerEntry, onSave: @escaping (KimiMCPServerEntry) -> Void, onCancel: @escaping () -> Void) {
    self._server = State(initialValue: server)
    self.onSave = onSave
    self.onCancel = onCancel
    self._commandText = State(initialValue: server.command?.joined(separator: " ") ?? "")
    self._environmentText = State(initialValue: server.environment?.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") ?? "")
    self._headersText = State(initialValue: server.headers?.map { "\($0.key): \($0.value)" }.joined(separator: "\n") ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("编辑 MCP 服务器")
        .font(.title3.weight(.semibold))

      Form {
        TextField("服务器名称", text: $server.id)
          .textFieldStyle(.roundedBorder)

        Picker("传输类型", selection: $server.transport) {
          ForEach(KimiMCPTransport.allCases, id: \.self) { transport in
            Text(transport.displayName).tag(transport)
          }
        }
        .pickerStyle(.segmented)

        Toggle("启用", isOn: $server.enabled)

        if server.transport == .local {
          TextField("命令 (空格分隔)", text: $commandText)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
          TextField("工作目录 (可选)", text: Binding(
            get: { server.cwd ?? "" },
            set: { server.cwd = $0.isEmpty ? nil : $0 }
          ))
          .textFieldStyle(.roundedBorder)
          Text("环境变量 (每行 KEY=VALUE)")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: $environmentText)
            .font(.system(.caption, design: .monospaced))
            .frame(height: 60)
        } else {
          TextField("URL", text: Binding(
            get: { server.url ?? "" },
            set: { server.url = $0.isEmpty ? nil : $0 }
          ))
          .textFieldStyle(.roundedBorder)
          Text("HTTP 头 (每行 Key: Value)")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: $headersText)
            .font(.system(.caption, design: .monospaced))
            .frame(height: 60)
        }
      }

      HStack {
        Button("取消", action: onCancel)
          .buttonStyle(.bordered)
        Spacer()
        Button("保存") { save() }
          .buttonStyle(.borderedProminent)
          .tint(KimiDesign.primary)
          .disabled(server.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 480)
  }

  private func save() {
    if server.transport == .local {
      server.command = commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? nil
        : commandText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
      var env: [String: String] = [:]
      for line in environmentText.components(separatedBy: .newlines) {
        let parts = line.components(separatedBy: "=")
        if parts.count >= 2 {
          env[parts[0].trimmingCharacters(in: .whitespaces)] = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        }
      }
      server.environment = env.isEmpty ? nil : env
    } else {
      var headers: [String: String] = [:]
      for line in headersText.components(separatedBy: .newlines) {
        let parts = line.components(separatedBy: ":")
        if parts.count >= 2 {
          headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        }
      }
      server.headers = headers.isEmpty ? nil : headers
    }
    onSave(server)
  }
}
