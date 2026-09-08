import SwiftUI
import KimiAgentCore

/// 外观设置：跟随系统 / 浅色 / 深色。改动立即生效（写入 UserDefaults 后
/// 由根视图的 .preferredColorScheme 应用），不走底部“应用更改”的重启流程。
struct KimiAppearanceSettingsPane: View {
  @ObservedObject var model: KimiAppViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: KimiSettingsLayout.sectionSpacing) {
      Text("选择应用的外观模式，立即生效，无需重启引擎。")
        .font(.subheadline)
        .foregroundStyle(KimiDesign.muted)
      Picker("外观", selection: $model.appearancePreference) {
        ForEach(KimiAppearancePreference.allCases) { preference in
          Text(preference.title).tag(preference)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 280)
    }
  }
}
