import SwiftUI
import KimiAgentCore

/// 会话设置:worktree 隔离等会话级行为开关。立即生效(写入 UserDefaults
/// 并同步到 kernel),不影响已存在的会话,无需重启引擎。
struct KimiSessionSettingsPane: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: KimiSettingsLayout.sectionSpacing) {
      Text("控制新建会话的工作目录隔离方式,立即生效,无需重启引擎。")
        .font(.subheadline)
        .foregroundStyle(KimiDesign.muted)
      Toggle("新会话使用独立工作区（git worktree）", isOn: $model.worktreeIsolationEnabled)
      Text("开启后,git 仓库项目的新会话会在 <项目>/.kimi/worktrees/ 下创建独立工作区,改动不直接影响项目目录;侧栏会话条目显示分支徽标,删除会话时可一并清理。非 git 项目或创建失败时自动回退到项目目录。")
        .font(.caption)
        .foregroundStyle(KimiDesign.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
