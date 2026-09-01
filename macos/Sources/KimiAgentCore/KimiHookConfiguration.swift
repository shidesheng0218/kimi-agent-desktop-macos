import Foundation

/// User-facing permission override for a tool type, mirroring the subset of
/// the engine's own ask/deny/allow vocabulary that makes sense to force from
/// outside a running turn (an always-ask default already exists engine-side).
public enum KimiHookPermissionOverride: String, Codable, CaseIterable, Sendable {
  case allow
  case deny

  public var displayName: String {
    switch self {
    case .allow: return "总是允许"
    case .deny: return "总是拒绝"
    }
  }
}

/// Declarative hook configuration, persisted locally and passed to the engine
/// as the `kimi-code-agent-plugin` plugin's options tuple. This is the entire
/// surface: no field here accepts executable code, only flat, JSON-safe data
/// the plugin's four hook functions consume (see
/// vendor/engine/packages/kimi-code-agent-plugin/src/index.ts).
public struct KimiHookConfiguration: Codable, Equatable, Sendable {
  public var systemPromptRules: [String]
  public var permissionOverrides: [String: KimiHookPermissionOverride]
  public var webFetchAllowedDomains: [String]
  public var toolOutputCharLimits: [String: Int]

  public init(
    systemPromptRules: [String] = [],
    permissionOverrides: [String: KimiHookPermissionOverride] = [:],
    webFetchAllowedDomains: [String] = [],
    toolOutputCharLimits: [String: Int] = [:]
  ) {
    self.systemPromptRules = systemPromptRules
    self.permissionOverrides = permissionOverrides
    self.webFetchAllowedDomains = webFetchAllowedDomains
    self.toolOutputCharLimits = toolOutputCharLimits
  }

  public var isEmpty: Bool {
    systemPromptRules.isEmpty && permissionOverrides.isEmpty
      && webFetchAllowedDomains.isEmpty && toolOutputCharLimits.isEmpty
  }

  /// Converts to the plugin options object the engine passes as the second
  /// argument of the plugin factory (`config.plugin = [[spec, options]]`).
  /// Field names must match `KimiHookOptions` in the plugin source exactly.
  public func toEngineOptions() -> [String: Any] {
    var options: [String: Any] = [:]
    if !systemPromptRules.isEmpty { options["systemPromptRules"] = systemPromptRules }
    if !permissionOverrides.isEmpty {
      options["permissionOverrides"] = permissionOverrides.mapValues { $0.rawValue }
    }
    if !webFetchAllowedDomains.isEmpty { options["webFetchAllowedDomains"] = webFetchAllowedDomains }
    if !toolOutputCharLimits.isEmpty { options["toolOutputCharLimits"] = toolOutputCharLimits }
    return options
  }
}
