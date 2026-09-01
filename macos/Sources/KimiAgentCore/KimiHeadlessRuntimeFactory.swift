import Foundation

public enum KimiHeadlessRuntimeFactory {
  /// Builds the engine launch configuration.
  /// - `modelID` overrides the launch-time default model (persisted user choice);
  /// - `modelCatalog` seeds the provider's models table so per-prompt model
  ///   references validate against the injected configuration;
  /// - `endpointOverride` keeps the loopback port and token stable across an
  ///   in-place reconfigure, so existing session clients never re-handshake.
  public static func makeConfiguration(
    resourcesDirectory: URL,
    applicationSupportDirectory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    modelID: String? = nil,
    modelCatalog: [String] = [],
    endpointOverride: KimiRuntimeEndpoint? = nil
  ) -> KimiRuntimeConfiguration? {
    let nativeRuntimeBinaryURL = configuredRuntimeURL(
      environment["KIMI_RUNTIME_BINARY"],
      fallback: resourcesDirectory.appendingPathComponent("runtime/kimi-agent")
    )
    let bunURL = configuredRuntimeURL(
      environment["KIMI_BUN_PATH"],
      fallback: resourcesDirectory.appendingPathComponent("runtime/bun")
    ) ?? ManagedRuntimeLocator.bunPath(environment: environment).map(URL.init(fileURLWithPath:))
    guard nativeRuntimeBinaryURL != nil || bunURL != nil else { return nil }

    let engineRoot = URL(fileURLWithPath: environment["KIMI_RUNTIME_ROOT"] ?? resourcesDirectory.appendingPathComponent("engine", isDirectory: true).path, isDirectory: true)
    let entrypoint = URL(fileURLWithPath: environment["KIMI_RUNTIME_ENTRY"] ?? engineRoot.appendingPathComponent("src/index.ts").path)
    if nativeRuntimeBinaryURL == nil && !(fileManager.fileExists(atPath: entrypoint.path) || environment["KIMI_RUNTIME_ENTRY"] != nil) {
      return nil
    }

    let port: Int
    let token: String
    if let endpointOverride {
      port = endpointOverride.port
      token = endpointOverride.token
    } else {
      port = Int(environment["KIMI_RUNTIME_PORT"] ?? "") ?? Int.random(in: 20_000...45_000)
      let configuredToken = environment["KIMI_RUNTIME_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      token = configuredToken.isEmpty ? UUID().uuidString : configuredToken
    }
    let endpoint = KimiRuntimeEndpoint(port: port, token: token)
    // Contain every engine-writable location inside the app's own sandbox
    // directory so nothing leaks into ~/.config, ~/.local, or other shared
    // XDG paths.
    let runtimeHome = applicationSupportDirectory.appendingPathComponent("runtime", isDirectory: true)
    let dataHome = runtimeHome.appendingPathComponent("data", isDirectory: true)
    let configHome = runtimeHome.appendingPathComponent("config", isDirectory: true)
    let stateHome = runtimeHome.appendingPathComponent("state", isDirectory: true)
    let pluginPath = environment["KIMI_RUNTIME_PLUGIN"] ?? resourcesDirectory.appendingPathComponent("kimi-native-plugin.mjs").path
    // OPENCODE_CONFIG_CONTENT is a virtual config source. The engine resolves
    // path plugins relative to a config file only when it sees a file URL;
    // passing an absolute filesystem path here makes the loader treat the
    // .mjs file as a directory and silently drops the plugin. Keep the
    // process environment explicit while emitting the canonical file URL.
    let plugin = filePluginSpec(pluginPath)
    let bridge = environment["KIMI_NATIVE_BRIDGE"] ?? resourcesDirectory.appendingPathComponent("native/KimiNativeBridge").path
    let resolvedModelID: String
    if let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      resolvedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    } else if let envModel = environment["KIMI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envModel.isEmpty {
      resolvedModelID = envModel
    } else {
      resolvedModelID = KimiRuntimeIdentityStore.defaultModelID
    }
    let modelID = resolvedModelID
    // Every selectable model must exist in the injected provider table, or
    // per-prompt model references would fail engine-side validation.
    let tableModelIDs = ([modelID] + modelCatalog).reduce(into: [String]()) { result, item in
      let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
    }
    let modelEntries = tableModelIDs.map { id in
      (id, ["name": id, "reasoning": true, "tool_call": true, "interleaved": "reasoning_content", "limit": ["context": 262_144, "output": 16_384], "modalities": ["input": ["text", "image"], "output": ["text"]]] as [String: Any])
    }
    let commandArguments: [String]
    let executableURL: URL
    if let nativeRuntimeBinaryURL {
      executableURL = nativeRuntimeBinaryURL
      commandArguments = ["serve", "--hostname", endpoint.host, "--port", String(endpoint.port)]
    } else {
      executableURL = bunURL!
      commandArguments = ["run", "--conditions=browser", entrypoint.path, "serve", "--hostname", endpoint.host, "--port", String(endpoint.port)]
    }
    var runtimeEnvironment: [String: String] = [
      "OPENCODE_SERVER_PASSWORD": token,
      "OPENCODE_SERVER_USERNAME": "kimi",
      "OPENCODE_CLIENT": "kimi-code-agent",
      "XDG_DATA_HOME": dataHome.path,
      "XDG_CONFIG_HOME": configHome.path,
      "XDG_STATE_HOME": stateHome.path,
      "KIMI_RUNTIME_PLUGIN": plugin,
      "KIMI_NATIVE_BRIDGE": bridge,
      "KIMI_APPLICATION_SUPPORT_DIR": applicationSupportDirectory.path
    ]

    // Build the engine's provider map: one entry per provider. The currently
    // selected provider (KimiRuntimeIdentityStore.providerID) always gets an
    // entry even when no credential is stored yet, because model/small_model
    // references it and the engine would fail validation without it. Other
    // providers only get an entry when they have a credential in Keychain.
    var providerEntries: [String: [String: Any]] = [:]
    for descriptor in KimiProviderCatalog.descriptors {
      let credentialKey = "kimi.runtime.identity.apiKey.\(descriptor.id)"
      let key = (try? MacKeychainCredentialVault().read(key: credentialKey))?.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasCredential = !(key?.isEmpty ?? true)
      let isSelectedProvider = descriptor.id == KimiRuntimeIdentityStore.providerID
      guard hasCredential || isSelectedProvider else { continue }
      if hasCredential, let credential = key {
        runtimeEnvironment[descriptor.apiKeyEnvVar] = credential
      }
      let modelEntries = descriptor.modelIDs.map { id in
        (id, ["name": id, "reasoning": true, "tool_call": true, "interleaved": "reasoning_content", "limit": ["context": 262144, "output": 16384], "modalities": ["input": ["text", "image"], "output": ["text"]]] as [String: Any])
      }
      providerEntries[descriptor.id] = [
        "name": descriptor.displayName,
        "api": descriptor.defaultBaseURL,
        "npm": descriptor.npmPackage,
        "env": [descriptor.apiKeyEnvVar],
        "options": ["apiKey": "{env:\(descriptor.apiKeyEnvVar)}", "baseURL": descriptor.defaultBaseURL, "timeout": 120000, "headerTimeout": 15000, "chunkTimeout": 30000, "setCacheKey": true],
        "models": Dictionary(uniqueKeysWithValues: modelEntries)
      ]
    }

    // The currently selected model must exist in its provider's models table
    // or per-prompt ModelRef validation fails engine-side. Merge the selected
    // model entries (from modelCatalog + modelID) into the matching provider's
    // models, preserving the preset entries already there.
    let selectedProviderID = KimiRuntimeIdentityStore.providerID
    if var selectedProvider = providerEntries[selectedProviderID] {
      var models = selectedProvider["models"] as? [String: [String: Any]] ?? [:]
      for (id, entry) in Dictionary(uniqueKeysWithValues: modelEntries) {
        if models[id] == nil { models[id] = entry }
      }
      selectedProvider["models"] = models
      providerEntries[selectedProviderID] = selectedProvider
    }

    // Load persisted MCP server list and build the engine's `mcp` config
    // block. Only enabled servers are included. Field names match the engine
    // schema exactly (command/environment/type, not cmd/env/stdio).
    var mcpEntries: [String: [String: Any]] = [:]
    let mcpStore = KimiMCPServerStore(fileURL: applicationSupportDirectory.appendingPathComponent("settings/mcp-servers.json"))
    if let mcpServers = try? mcpStore.load() {
      for server in mcpServers where server.enabled {
        mcpEntries[server.id] = server.toEngineConfig()
      }
    }

    // Load the declarative hook configuration and, when non-empty, pass it as
    // the plugin's options tuple ([spec, options]) instead of a bare spec
    // string. The plugin (kimi-code-agent-plugin) reads these as its second
    // factory argument — no code crosses this boundary, only flat JSON.
    let hookStore = KimiHookConfigStore(fileURL: applicationSupportDirectory.appendingPathComponent("settings/hook-config.json"))
    let hookConfiguration = (try? hookStore.load()) ?? KimiHookConfiguration()
    let pluginEntry: [Any] = hookConfiguration.isEmpty
      ? ["{env:KIMI_RUNTIME_PLUGIN}"]
      : [["{env:KIMI_RUNTIME_PLUGIN}", hookConfiguration.toEngineOptions()]]

    var config: [String: Any] = [
      "model": "\(KimiRuntimeIdentityStore.providerID)/\(modelID)",
      "small_model": "\(KimiRuntimeIdentityStore.providerID)/\(modelID)",
      "plugin": pluginEntry,
      "provider": providerEntries,
      "permission": ["read": "allow", "glob": "allow", "grep": "allow", "list": "allow", "websearch": "allow", "webfetch": "allow", "task": "allow", "bash": "ask", "edit": "ask", "external_directory": "ask", "question": "ask", "skill": "ask"],
      "compaction": ["auto": true, "prune": true, "tail_turns": 8, "preserve_recent_tokens": 24000],
      "tool_output": ["max_lines": 2000, "max_bytes": 51200]
    ]
    if !mcpEntries.isEmpty {
      config["mcp"] = mcpEntries
    }
    if let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
      runtimeEnvironment["OPENCODE_CONFIG_CONTENT"] = text
    }

    return KimiRuntimeConfiguration(
      executableURL: executableURL,
      arguments: commandArguments,
      // A packaged app ships only the standalone engine binary, not the
      // engine source tree, so engineRoot may not exist. Spawning a process
      // with a missing working directory throws before exec; fall back to the
      // always-present, contained Application Support directory instead.
      workingDirectory: fileManager.fileExists(atPath: engineRoot.path) ? engineRoot : applicationSupportDirectory,
      environment: runtimeEnvironment,
      endpoint: endpoint
    )
  }

  private static func configuredRuntimeURL(_ raw: String?, fallback: URL) -> URL? {
    if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: raw)
      return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
  }

  private static func filePluginSpec(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("file://") { return value }
    return URL(fileURLWithPath: value).absoluteString
  }
}
