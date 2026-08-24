import Foundation

/// Persists the user's MCP server list to a JSON file under Application
/// Support, so configured servers survive app restarts. Not sensitive data
/// (no credentials), so a plain JSON file is sufficient — no Keychain needed.
public final class KimiMCPServerStore: @unchecked Sendable {
  private let fileURL: URL
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(fileURL: URL) {
    self.fileURL = fileURL
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  public func load() throws -> [KimiMCPServerEntry] {
    lock.lock()
    defer { lock.unlock() }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return [] }
    return try decoder.decode([KimiMCPServerEntry].self, from: data)
  }

  public func save(_ entries: [KimiMCPServerEntry]) throws {
    lock.lock()
    defer { lock.unlock() }
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(entries)
    // Create the temporary file with 0600 before the atomic rename so there
    // is no window where the file is world-readable under the umask.
    let temporaryURL = directory.appendingPathComponent(".mcp-servers.tmp-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw NSError(domain: "KimiMCPServerStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入 MCP 服务器配置。"])
    }
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
  }

  public func add(_ entry: KimiMCPServerEntry) throws {
    var entries = try load()
    // Replace existing entry with the same ID, or append
    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
      entries[index] = entry
    } else {
      entries.append(entry)
    }
    try save(entries)
  }

  public func remove(id: String) throws {
    var entries = try load()
    entries.removeAll { $0.id == id }
    try save(entries)
  }
}
