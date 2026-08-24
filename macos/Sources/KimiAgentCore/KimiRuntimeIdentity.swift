import Foundation

public enum KimiRuntimeIdentityMode: String, Codable, CaseIterable, Sendable {
  case kimiCode
  case apiKey
}

public struct KimiRuntimeIdentityRecord: Codable, Equatable, Sendable {
  public var mode: KimiRuntimeIdentityMode
  public var baseURL: String
  public var modelID: String
  public var apiKeyStatus: String
  public var updatedAt: Date?

  public init(
    mode: KimiRuntimeIdentityMode = .kimiCode,
    baseURL: String = KimiRuntimeIdentityStore.defaultBaseURL,
    modelID: String = KimiRuntimeIdentityStore.defaultModelID,
    apiKeyStatus: String = "missing",
    updatedAt: Date? = nil
  ) {
    self.mode = mode
    self.baseURL = baseURL
    self.modelID = modelID
    self.apiKeyStatus = apiKeyStatus
    self.updatedAt = updatedAt
  }

  public var isAPIConfigured: Bool {
    apiKeyStatus == "configured"
  }
}

public final class KimiRuntimeIdentityStore: @unchecked Sendable {
  public static let defaultBaseURL = "https://api.moonshot.cn/v1"
  public static let legacyDefaultBaseURL = "https://api.moonshot.ai/v1"
  public static let defaultModelID = "kimi-k2.7-code"
  /// Provider identifier used in the injected engine configuration and in
  /// per-prompt model references.
  public static let providerID = "moonshotai-cn"

  public static func resolvedModelID(taskModelID: String?, fallbackModelID: String) -> String {
    let taskModel = taskModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !taskModel.isEmpty { return taskModel }
    let fallback = fallbackModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    return fallback.isEmpty ? Self.defaultModelID : fallback
  }

  private let vault: CredentialVault
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(vault: CredentialVault, fileManager: FileManager = .default) {
    self.vault = vault
    self.fileManager = fileManager
    encoder.outputFormatting = [.sortedKeys]
  }

  public func record() throws -> KimiRuntimeIdentityRecord {
    try migrateIfNeeded()
    let stored = try loadMetadata()
    let hasAPIKey = !(try configuredProviderIDs().isEmpty)
    var record = stored ?? KimiRuntimeIdentityRecord(mode: hasAPIKey ? .apiKey : .kimiCode)
    if record.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == Self.legacyDefaultBaseURL {
      record.baseURL = Self.defaultBaseURL
      record.updatedAt = .now
      try writeMetadata(record)
    }
    record.apiKeyStatus = hasAPIKey ? "configured" : "missing"
    return record
  }

  public func connectAPI(
    apiKey: String,
    baseURL: String = defaultBaseURL,
    modelID: String = defaultModelID
  ) throws {
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw NSError(domain: "KimiRuntimeIdentityStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "API Key 不能为空。"])
    }

    let normalizedBaseURL = try normalizeBaseURL(baseURL)
    let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Self.defaultModelID
    try saveAPIKey(trimmedKey, for: Self.providerID)
    try writeMetadata(KimiRuntimeIdentityRecord(
      mode: .apiKey,
      baseURL: normalizedBaseURL,
      modelID: normalizedModelID,
      apiKeyStatus: "configured",
      updatedAt: .now
    ))
  }

  public func useKimiCode() throws {
    var record = try self.record()
    record.mode = .kimiCode
    record.updatedAt = .now
    try writeMetadata(record)
  }

  public func useAPIKey() throws {
    var record = try self.record()
    guard record.isAPIConfigured else {
      throw NSError(domain: "KimiRuntimeIdentityStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先保存 API Key。"])
    }
    record.mode = .apiKey
    record.updatedAt = .now
    try writeMetadata(record)
  }

  public func disconnectAPI(applicationSupportDirectory: URL? = nil) throws {
    var record = try self.record()
    try deleteAPIKey(for: Self.providerID)
    record.mode = .kimiCode
    record.apiKeyStatus = "missing"
    record.updatedAt = .now
    try writeMetadata(record)
    if let applicationSupportDirectory {
      let configURL = shareDirectory(for: .apiKey, applicationSupportDirectory: applicationSupportDirectory)
        .appendingPathComponent("config.toml")
      try? fileManager.removeItem(at: configURL)
    }
  }

  public func apiKey() throws -> String? {
    try apiKey(for: Self.providerID)
  }

  /// Reads the credential for a specific provider, or nil when none is stored.
  public func apiKey(for providerID: String) throws -> String? {
    try vault.read(key: apiKeyKey(for: providerID))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  /// Saves a credential for a specific provider, keyed by that provider's ID.
  public func saveAPIKey(_ apiKey: String, for providerID: String) throws {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError(domain: "KimiRuntimeIdentityStore", code: 6, userInfo: [NSLocalizedDescriptionKey: "API Key 不能为空。"])
    }
    try vault.write(trimmed, key: apiKeyKey(for: providerID))
  }

  /// Deletes the credential for a specific provider.
  public func deleteAPIKey(for providerID: String) throws {
    try vault.delete(key: apiKeyKey(for: providerID))
  }

  /// Returns the IDs of all providers that currently have a credential stored.
  /// Keychain doesn't support enumeration, so this checks a static list of known
  /// provider IDs; unknown providers' keys can't be discovered.
  public func configuredProviderIDs() throws -> [String] {
    var configured: [String] = []
    for descriptor in KimiProviderCatalog.descriptors {
      if try apiKey(for: descriptor.id) != nil {
        configured.append(descriptor.id)
      }
    }
    return configured
  }

  /// One-time migration: copy the legacy single credential (written before
  /// multi-provider support) into the default provider's bucket, then delete
  /// the legacy key. Idempotent — running it twice has no additional effect,
  /// and if the target bucket already has a credential the legacy key is left
  /// alone so nothing is ever silently lost.
  public func migrateIfNeeded() throws {
    guard let legacyValue = try vault.read(key: legacyAPIKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !legacyValue.isEmpty else {
      return
    }
    let defaultBucketKey = apiKeyKey(for: Self.providerID)
    let existing = try vault.read(key: defaultBucketKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if existing == nil || existing!.isEmpty {
      try vault.write(legacyValue, key: defaultBucketKey)
    }
    try vault.delete(key: legacyAPIKeyKey)
  }

  public func runtimeEnvironment(
    applicationSupportDirectory: URL,
    additionalModelIDs: [String] = []
  ) throws -> [String: String] {
    let record = try self.record()
    let shareDirectory = shareDirectory(for: record.mode, applicationSupportDirectory: applicationSupportDirectory)
    try fileManager.createDirectory(at: shareDirectory, withIntermediateDirectories: true)

    var environment = [
      "KIMI_SHARE_DIR": shareDirectory.path,
      "KIMI_CODE_HOME": shareDirectory.path
    ]

    if record.mode == .apiKey {
      guard let apiKey = try apiKey() else {
        throw NSError(domain: "KimiRuntimeIdentityStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "API 模式已启用，但还没有保存 API Key。"])
      }
      try writeAPIConfig(
        shareDirectory: shareDirectory,
        apiKey: apiKey,
        baseURL: record.baseURL,
        modelID: record.modelID,
        additionalModelIDs: additionalModelIDs
      )
      environment["KIMI_API_KEY"] = apiKey
      environment["KIMI_BASE_URL"] = record.baseURL
    }

    return environment
  }

  public func shareDirectory(for mode: KimiRuntimeIdentityMode, applicationSupportDirectory: URL) -> URL {
    switch mode {
    case .kimiCode:
      applicationSupportDirectory.appendingPathComponent("kimi-code", isDirectory: true)
    case .apiKey:
      applicationSupportDirectory.appendingPathComponent("kimi-api", isDirectory: true)
    }
  }

  private func writeAPIConfig(
    shareDirectory: URL,
    apiKey: String,
    baseURL: String,
    modelID: String,
    additionalModelIDs: [String] = []
  ) throws {
    let modelIDs = uniqueModelIDs([modelID] + additionalModelIDs)
    let modelDefinitions = modelIDs.map { id in
      """
      [models.\"\(tomlEscape(id))\"]
      provider = "kimi"
      model = "\(tomlEscape(id))"
      max_context_size = 262144
      capabilities = ["always_thinking"]
      """
    }.joined(separator: "\n\n")
    let config = """
    default_model = "\(tomlEscape(modelID))"

    [thinking]
    enabled = true

    [providers.kimi]
    type = "kimi"
    base_url = "\(tomlEscape(baseURL))"
    api_key = "\(tomlEscape(apiKey))"

    \(modelDefinitions)

    [[permission.rules]]
    decision = "ask"
    scope = "user"
    pattern = "WebSearch"

    [[permission.rules]]
    decision = "ask"
    scope = "user"
    pattern = "FetchURL"

    """
    let configURL = shareDirectory.appendingPathComponent("config.toml")
    try fileManager.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
    // Create the secret-bearing file with 0600 before the atomic rename, so
    // there is no window where the key is world-readable under the umask.
    let temporaryURL = shareDirectory.appendingPathComponent(".config.toml.tmp-\(UUID().uuidString)")
    let data = Data(config.utf8)
    guard fileManager.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw NSError(domain: "KimiRuntimeIdentityStore", code: 5, userInfo: [NSLocalizedDescriptionKey: "无法写入 Kimi Runtime 配置。"])
    }
    defer { try? fileManager.removeItem(at: temporaryURL) }
    _ = try fileManager.replaceItemAt(configURL, withItemAt: temporaryURL)
  }

  private func loadMetadata() throws -> KimiRuntimeIdentityRecord? {
    guard let text = try vault.read(key: metadataKey),
          let data = text.data(using: .utf8) else {
      return nil
    }
    return try decoder.decode(KimiRuntimeIdentityRecord.self, from: data)
  }

  private func writeMetadata(_ record: KimiRuntimeIdentityRecord) throws {
    let data = try encoder.encode(record)
    try vault.write(String(data: data, encoding: .utf8) ?? "{}", key: metadataKey)
  }

  private func normalizeBaseURL(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Self.defaultBaseURL
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          url.host(percentEncoded: false) != nil else {
      throw NSError(domain: "KimiRuntimeIdentityStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "Base URL 必须是合法的 HTTP(S) 地址。"])
    }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func tomlEscape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
  }

  private func uniqueModelIDs(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { rawValue in
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, seen.insert(value).inserted else { return nil }
      return value
    }
  }

  private var metadataKey: String {
    "kimi.runtime.identity.metadata"
  }

  /// Legacy single-credential key kept for one-time migration only. New code
  /// always writes via `apiKeyKey(for:)`.
  private var legacyAPIKeyKey: String {
    "kimi.runtime.identity.apiKey"
  }

  private func apiKeyKey(for providerID: String) -> String {
    "kimi.runtime.identity.apiKey.\(providerID)"
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
