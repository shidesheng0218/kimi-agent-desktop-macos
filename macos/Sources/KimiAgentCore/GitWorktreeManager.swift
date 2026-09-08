import Foundation

public struct GitWorktree: Codable, Equatable, Sendable {
  public let repositoryPath: String
  public let path: URL
  public let branch: String
  public let baseCommit: String

  public init(repositoryPath: String, path: URL, branch: String, baseCommit: String) {
    self.repositoryPath = repositoryPath
    self.path = path
    self.branch = branch
    self.baseCommit = baseCommit
  }
}

public enum GitWorktreeManager {
  /// 会话级 worktree 的固定布局（参照 Claude 的 .claude/worktrees 惯例，
  /// 用 .kimi 前缀）：<repo>/.kimi/worktrees/<session-id 前 8 位>，
  /// 分支 kimi/session-<id>。纯函数，便于自检覆盖。
  public static func sessionWorktreeLocation(repositoryRoot: URL, sessionID: UUID) -> (directory: URL, branch: String) {
    let shortID = String(sessionID.uuidString.prefix(8)).lowercased()
    return (
      repositoryRoot.appendingPathComponent(".kimi/worktrees/\(shortID)", isDirectory: true),
      "kimi/session-\(shortID)"
    )
  }

  /// 为会话创建独立工作区。调用方需先确认 hasUsableHEAD；任何 git 失败
  /// 都会抛错，由调用方静默回退到项目根。git 子进程在 detached 任务里
  /// 同步等待（参照 KimiPullRequestMonitor 的 KimiProcessRunner 用法），
  /// 不阻塞调用方 actor。
  public static func createSessionWorktree(projectRoot: URL, sessionID: UUID) async throws -> GitWorktree {
    try await Task.detached(priority: .userInitiated) {
      let repositoryRoot = URL(
        fileURLWithPath: try runGit(["rev-parse", "--show-toplevel"], in: projectRoot).trimmingCharacters(in: .whitespacesAndNewlines),
        isDirectory: true
      )
      let baseCommit = try runGit(["rev-parse", "HEAD"], in: repositoryRoot).trimmingCharacters(in: .whitespacesAndNewlines)
      let location = sessionWorktreeLocation(repositoryRoot: repositoryRoot, sessionID: sessionID)
      try FileManager.default.createDirectory(
        at: location.directory.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try runGit(["worktree", "add", "-b", location.branch, location.directory.path, baseCommit], in: repositoryRoot)
      // worktree 目录位于主仓库工作树内，把它写进 repo 级 info/exclude
      // （不动用户的 .gitignore），否则项目根的 git status 会多出一条
      // 未跟踪的 .kimi/ 条目，污染其他会话的 Diff 面板。
      excludeWorktreesFromStatus(repositoryRoot: repositoryRoot)
      return GitWorktree(repositoryPath: repositoryRoot.path, path: location.directory, branch: location.branch, baseCommit: baseCommit)
    }.value
  }

  /// worktree 是否有未提交改动（含未跟踪文件），删除前提示用。
  public static func hasUncommittedChanges(_ worktree: GitWorktree) async -> Bool {
    await Task.detached(priority: .utility) {
      let status = try? runGit(["status", "--porcelain"], in: worktree.path)
      return !(status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }.value
  }

  /// 删除会话 worktree 及其分支。--force 丢弃未提交改动，是否接受该风险
  /// 由调用方（删除会话确认框）决定。
  public static func removeSessionWorktree(_ worktree: GitWorktree) async throws {
    try await Task.detached(priority: .utility) {
      let repository = URL(fileURLWithPath: worktree.repositoryPath, isDirectory: true)
      try runGit(["worktree", "remove", "--force", worktree.path.path], in: repository)
      try? runGit(["branch", "-D", worktree.branch], in: repository)
    }.value
  }

  /// 基于 HEAD 判断是否能为项目创建 worktree：非 git 仓库或尚无提交的
  /// 空仓库都返回 false（git worktree add 需要 HEAD 作为基准）。
  public static func canCreateSessionWorktree(_ directory: URL) async -> Bool {
    await Task.detached(priority: .utility) { hasUsableHEAD(directory) }.value
  }

  private static func excludeWorktreesFromStatus(repositoryRoot: URL) {
    guard let rawGitDir = try? runGit(["rev-parse", "--git-common-dir"], in: repositoryRoot)
      .trimmingCharacters(in: .whitespacesAndNewlines), !rawGitDir.isEmpty else { return }
    // --git-common-dir 可能返回相对路径（如 .git），按仓库根解析。
    let gitCommonDir = rawGitDir.hasPrefix("/")
      ? rawGitDir
      : repositoryRoot.appendingPathComponent(rawGitDir).standardizedFileURL.path
    let infoDirectory = URL(fileURLWithPath: gitCommonDir, isDirectory: true).appendingPathComponent("info", isDirectory: true)
    let excludeFile = infoDirectory.appendingPathComponent("exclude")
    try? FileManager.default.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
    let entry = ".kimi/worktrees/"
    let existing = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? ""
    guard !existing.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == entry }) else { return }
    let prefix = existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n"
    try? (prefix + entry + "\n").write(to: excludeFile, atomically: true, encoding: .utf8)
  }

  public static func isRepository(_ directory: URL) -> Bool {
    (try? runGit(["rev-parse", "--show-toplevel"], in: directory)) != nil
  }

  /// Returns whether the repository has a commit that can be used as a Worktree base.
  /// Empty repositories are valid Git repositories, but `git worktree add ... HEAD` cannot run in them.
  public static func hasUsableHEAD(_ directory: URL) -> Bool {
    guard isRepository(directory) else { return false }
    return (try? runGit(["rev-parse", "--verify", "HEAD"], in: directory)) != nil
  }

  public static func create(
    for repository: URL,
    taskID: UUID,
    rootDirectory: URL? = nil
  ) throws -> GitWorktree {
    let repositoryRoot = URL(fileURLWithPath: try runGit(["rev-parse", "--show-toplevel"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    let baseCommit = try runGit(["rev-parse", "HEAD"], in: repositoryRoot).trimmingCharacters(in: .whitespacesAndNewlines)
    let root = rootDirectory ?? repositoryRoot.appendingPathComponent(".kimi-worktrees", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let shortID = String(taskID.uuidString.prefix(8)).lowercased()
    let branch = "kimi/task-\(shortID)/main"
    let worktreePath = root.appendingPathComponent("task-\(shortID)", isDirectory: true)
    try runGit(["worktree", "add", "-b", branch, worktreePath.path, baseCommit], in: repositoryRoot)
    return GitWorktree(repositoryPath: repositoryRoot.path, path: worktreePath, branch: branch, baseCommit: baseCommit)
  }

  public static func remove(_ worktree: GitWorktree) throws {
    let repository = URL(fileURLWithPath: worktree.repositoryPath, isDirectory: true)
    try runGit(["worktree", "remove", "--force", worktree.path.path], in: repository)
  }

  public static func merge(_ worktree: GitWorktree, into repository: URL, message: String) throws {
    try runGit(["add", "-A"], in: worktree.path)
    try runGit([
      "-c", "user.email=kimi-agent@localhost",
      "-c", "user.name=Kimi Code Agent",
      "commit", "-m", message
    ], in: worktree.path)
    try runGit(["merge", "--no-ff", worktree.branch, "-m", message], in: repository)
  }

  public static func restoreFile(_ relativePath: String, in worktree: GitWorktree, baseCommit: String? = nil) throws {
    let base = baseCommit ?? worktree.baseCommit
    try runGit(["checkout", base, "--", relativePath], in: worktree.path)
  }

  @discardableResult
  private static func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "KimiAgentCore.Git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
  }
}
