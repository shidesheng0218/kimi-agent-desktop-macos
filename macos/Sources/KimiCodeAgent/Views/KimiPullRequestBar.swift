import SwiftUI
import AppKit
import KimiAgentCore

/// 会话头部下方的 PR/CI 状态条：显示当前分支关联的 PR（点击打开网页）
/// 与检查状态汇总；非 GitHub 项目、无 PR 等场景隐藏或降级为轻提示。
struct KimiPullRequestBar: View {
  @ObservedObject var monitor: KimiPullRequestMonitor

  var body: some View {
    switch monitor.status {
    case .hidden, .loading:
      EmptyView()
    case .needsGH:
      bar {
        Image(systemName: "exclamationmark.circle")
          .foregroundStyle(KimiDesign.muted)
        Text("安装 gh 以监控 PR 状态")
          .foregroundStyle(KimiDesign.muted)
      }
    case .noPullRequest(let branch):
      bar {
        Image(systemName: "arrow.triangle.pull")
          .foregroundStyle(KimiDesign.muted)
        Text("分支 \(branch) 暂无关联 PR")
          .foregroundStyle(KimiDesign.muted)
      }
    case .loaded(let info):
      bar {
        Image(systemName: "arrow.triangle.pull")
          .foregroundStyle(KimiDesign.primary)
        Button {
          if let url = URL(string: info.url) {
            NSWorkspace.shared.open(url)
          }
        } label: {
          Text("PR #\(info.number) · \(info.title)")
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(KimiDesign.primary)
        if info.state != "OPEN" {
          Text(info.state == "MERGED" ? "已合并" : "已关闭")
            .foregroundStyle(KimiDesign.muted)
        }
        Spacer(minLength: 8)
        if let checks = info.checks {
          checksView(checks)
        }
      }
    }
  }

  private func bar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 6) {
      content()
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(KimiDesign.surfaceSecondary.opacity(0.6))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(KimiDesign.border, lineWidth: 1))
  }

  private func checksView(_ checks: KimiPullRequestMonitor.ChecksSummary) -> some View {
    HStack(spacing: 8) {
      if checks.pending > 0 {
        checkDot(count: checks.pending, label: "进行中", color: .yellow)
      }
      if checks.failed > 0 {
        checkDot(count: checks.failed, label: "失败", color: .red)
      }
      if checks.passed > 0 {
        checkDot(count: checks.passed, label: "通过", color: .green)
      }
      if checks.passed == 0 && checks.failed == 0 && checks.pending == 0 {
        Text("暂无检查").foregroundStyle(KimiDesign.muted)
      }
    }
  }

  private func checkDot(count: Int, label: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text("\(count) \(label)")
        .foregroundStyle(KimiDesign.text)
    }
  }
}
