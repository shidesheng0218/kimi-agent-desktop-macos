import Foundation

/// @提及的数据源：项目目录的相对路径索引。异步扫描 + 缓存，排除隐藏项与
/// 常见重目录（与 KimiPanelsView 文件树的"跳过 . 开头项"规则一致），
/// 上限 5000 条防大型仓库卡顿。
public actor KimiFileMentionIndex {
  public static let maxEntries = 5_000

  /// 隐藏目录已被 ". 开头"规则覆盖，这里只列非隐藏的重目录。
  private static let skippedDirectoryNames: Set<String> = [
    "node_modules", "dist", "build", "target", "DerivedData"
  ]

  private var cache: [String: [String]] = [:]

  public init() {}

  /// 项目根目录下的相对路径列表（仅文件，已排序）。首次扫描，之后命中缓存。
  public func paths(root: String) async -> [String] {
    if let cached = cache[root] { return cached }
    let scanned = Self.scan(root: root)
    cache[root] = scanned
    return scanned
  }

  public func invalidate(root: String) {
    cache.removeValue(forKey: root)
  }

  private static func scan(root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    var results: [String] = []
    while let relative = enumerator.nextObject() as? String {
      let name = (relative as NSString).lastPathComponent
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(
        atPath: (root as NSString).appendingPathComponent(relative),
        isDirectory: &isDirectory
      )
      if name.hasPrefix(".") || skippedDirectoryNames.contains(name) {
        if isDirectory.boolValue { enumerator.skipDescendants() }
        continue
      }
      if isDirectory.boolValue { continue }
      results.append(relative)
      if results.count >= maxEntries { break }
    }
    return results.sorted()
  }
}
