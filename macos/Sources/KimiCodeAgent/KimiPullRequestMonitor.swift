import Foundation
import KimiAgentCore

/// PR/CI 状态监控（对标 Claude Code 桌面版会话头部的 PR 状态条）：
/// 会话项目目录是带 GitHub remote 的 git 仓库时，用 gh CLI 查询当前分支的
/// PR 与检查状态，每 30s 轮询一次；会话切换或停止时终止轮询。
/// 未安装 gh、非 git 仓库、非 GitHub remote 时静默降级，不报错。
@MainActor
final class KimiPullRequestMonitor: ObservableObject {
  typealias ChecksSummary = KimiPRChecksSummary

  struct PullRequestInfo: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let url: String
    public let state: String
    public var checks: ChecksSummary?
  }

  enum Status: Equatable {
    /// 非 git 仓库、非 GitHub remote 或无项目目录：状态条整体隐藏。
    case hidden
    case needsGH
    case loading
    case noPullRequest(branch: String)
    case loaded(PullRequestInfo)
  }

  @Published private(set) var status: Status = .hidden

  /// 状态条是否占用布局（隐藏/加载中不占位，避免会话头部下方留空缝）。
  var isBarVisible: Bool {
    switch status {
    case .hidden, .loading: return false
    case .needsGH, .noPullRequest, .loaded: return true
    }
  }

  private let pollInterval: Duration
  private var pollTask: Task<Void, Never>?
  private var sessionID: UUID?
  /// CI 结束通知的去重依据：上一轮仍有 pending，本轮归零才算「结束」。
  private var lastHadPendingChecks = false

  init(pollInterval: Duration = .seconds(30)) {
    self.pollInterval = pollInterval
  }

  deinit {
    pollTask?.cancel()
  }

  /// 切换到指定会话上下文；projectPath 为 nil 时停止并隐藏状态条。
  func start(projectPath: String?, sessionID: UUID?) {
    pollTask?.cancel()
    pollTask = nil
    self.sessionID = sessionID
    lastHadPendingChecks = false
    guard let projectPath, !projectPath.isEmpty else {
      status = .hidden
      return
    }
    status = .loading
    pollTask = Task { [weak self, pollInterval] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.refresh(projectPath: projectPath)
        try? await Task.sleep(for: pollInterval)
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
    status = .hidden
  }

  private func refresh(projectPath: String) async {
    guard let gh = await Self.which("gh") else {
      status = .needsGH
      return
    }
    let remote = await Self.run("/usr/bin/env", ["git", "remote", "get-url", "origin"], in: projectPath)
    guard let remoteURL = remote?.trimmingCharacters(in: .whitespacesAndNewlines),
          remoteURL.contains("github.com") else {
      status = .hidden
      return
    }
    let branch = await Self.run("/usr/bin/env", ["git", "branch", "--show-current"], in: projectPath)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !branch.isEmpty else {
      status = .hidden
      return
    }
    guard let listOutput = await Self.run(gh, ["pr", "list", "--head", branch, "--json", "number,title,url,state", "--limit", "1"], in: projectPath),
          let list = try? JSONSerialization.jsonObject(with: Data(listOutput.utf8)) as? [[String: Any]] else {
      if status == .loading { status = .noPullRequest(branch: branch) }
      return
    }
    guard let entry = list.first,
          let number = entry["number"] as? Int else {
      status = .noPullRequest(branch: branch)
      return
    }
    var info = PullRequestInfo(
      number: number,
      title: entry["title"] as? String ?? "",
      url: entry["url"] as? String ?? "",
      state: (entry["state"] as? String ?? "").uppercased()
    )
    info.checks = await fetchChecks(gh: gh, number: number, projectPath: projectPath)
    notifyIfChecksSettled(info)
    status = .loaded(info)
  }

  private func fetchChecks(gh: String, number: Int, projectPath: String) async -> ChecksSummary? {
    guard let output = await Self.run(gh, ["pr", "view", "\(number)", "--json", "statusCheckRollup"], in: projectPath),
          let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
          let rollup = object["statusCheckRollup"] as? [[String: Any]] else { return nil }
    return KimiPRChecksSummary.summarize(rollup: rollup)
  }

  /// 从「有 pending」变为「无 pending」时发系统通知：全过或有失败各一条。
  private func notifyIfChecksSettled(_ info: PullRequestInfo) {
    guard let checks = info.checks else { return }
    let settled = lastHadPendingChecks && checks.pending == 0
    lastHadPendingChecks = checks.pending > 0
    guard settled, let sessionID else { return }
    if checks.failed > 0 {
      KimiNotificationCenter.shared.post(
        title: "PR #\(info.number) 检查失败",
        body: "\(checks.failed) 项失败 · \(checks.passed) 项通过",
        sessionID: sessionID
      )
    } else {
      KimiNotificationCenter.shared.post(
        title: "PR #\(info.number) 检查全部通过",
        body: "\(checks.passed) 项检查通过",
        sessionID: sessionID
      )
    }
  }

  /// 查找可执行文件路径（which 语义）；未找到返回 nil。
  nonisolated static func which(_ tool: String) async -> String? {
    guard let output = await run("/usr/bin/env", ["which", tool], in: nil) else { return nil }
    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  /// 子进程异步执行并收集 stdout；非零退出码或启动失败返回 nil（静默降级）。
  /// KimiProcessRunner.wait() 会同步等待进程退出，因此放到 detached 任务里，
  /// 绝不阻塞主线程。
  nonisolated static func run(_ executable: String, _ arguments: [String], in directory: String?) async -> String? {
    await Task.detached(priority: .utility) {
      let command = KimiCommand(executableURL: URL(fileURLWithPath: executable), arguments: arguments)
      guard let result = try? KimiProcessRunner.run(
        command,
        workingDirectory: directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ), result.exitCode == 0 else { return nil }
      return result.standardOutput
    }.value
  }
}
