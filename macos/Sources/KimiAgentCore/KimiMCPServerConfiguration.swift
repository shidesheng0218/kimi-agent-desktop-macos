import Foundation

/// Transport type for an MCP server, matching the engine's `mcp` config
/// schema (vendor/engine/packages/core/src/v1/config/mcp.ts).
public enum KimiMCPTransport: String, Codable, CaseIterable, Sendable {
  case local
  case remote

  public var displayName: String {
    switch self {
    case .local: return "本地命令 (stdio)"
    case .remote: return "远程服务 (HTTP/SSE)"
    }
  }
}

/// One MCP server entry as configured by the user. This is Swift-side
/// configuration data only — the engine's own MCP client handles all actual
/// protocol communication. Written into OPENCODE_CONFIG_CONTENT's `mcp` map
/// at engine launch, and also addable at runtime via POST /mcp without restart.
public struct KimiMCPServerEntry: Codable, Equatable, Identifiable, Sendable {
  /// Server name (the key in the engine's `mcp` config map).
  public var id: String
  public var transport: KimiMCPTransport
  public var enabled: Bool

  // Local transport fields
  public var command: [String]?
  public var cwd: String?
  public var environment: [String: String]?
  public var timeout: Int?

  // Remote transport fields
  public var url: String?
  public var headers: [String: String]?

  public init(
    id: String,
    transport: KimiMCPTransport,
    enabled: Bool = true,
    command: [String]? = nil,
    cwd: String? = nil,
    environment: [String: String]? = nil,
    timeout: Int? = nil,
    url: String? = nil,
    headers: [String: String]? = nil
  ) {
    self.id = id
    self.transport = transport
    self.enabled = enabled
    self.command = command
    self.cwd = cwd
    self.environment = environment
    self.timeout = timeout
    self.url = url
    self.headers = headers
  }

  /// Converts this entry into the engine's `mcp` config map schema.
  /// Field names must match exactly: `command` (not `cmd`), `environment` (not
  /// `env`), `type` with values `local`/`remote` (not `stdio`/`sse`/`http`).
  public func toEngineConfig() -> [String: Any] {
    switch transport {
    case .local:
      var config: [String: Any] = ["type": "local"]
      if let command { config["command"] = command }
      if let cwd { config["cwd"] = cwd }
      if let environment { config["environment"] = environment }
      if let timeout { config["timeout"] = timeout }
      config["enabled"] = enabled
      return config
    case .remote:
      var config: [String: Any] = ["type": "remote"]
      if let url { config["url"] = url }
      if let headers { config["headers"] = headers }
      if let timeout { config["timeout"] = timeout }
      config["enabled"] = enabled
      return config
    }
  }
}
