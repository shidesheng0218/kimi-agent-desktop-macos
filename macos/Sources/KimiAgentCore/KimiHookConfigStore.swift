import Foundation

/// Persists the user's declarative hook configuration to a JSON file under
/// Application Support, mirroring KimiMCPServerStore. Not sensitive data (no
/// credentials, no code), so a plain JSON file is sufficient.
public final class KimiHookConfigStore: @unchecked Sendable {
  private let fileURL: URL
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(fileURL: URL) {
    self.fileURL = fileURL
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  public func load() throws -> KimiHookConfiguration {
    lock.lock()
    defer { lock.unlock() }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return KimiHookConfiguration() }
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return KimiHookConfiguration() }
    return try decoder.decode(KimiHookConfiguration.self, from: data)
  }

  public func save(_ configuration: KimiHookConfiguration) throws {
    lock.lock()
    defer { lock.unlock() }
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(configuration)
    // Create the temporary file with 0600 before the atomic rename so there
    // is no window where the file is world-readable under the umask.
    let temporaryURL = directory.appendingPathComponent(".hook-config.tmp-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw NSError(domain: "KimiHookConfigStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入行为规则配置。"])
    }
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
  }
}
