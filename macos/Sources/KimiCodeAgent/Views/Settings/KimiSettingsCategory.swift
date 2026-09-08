import SwiftUI

enum KimiSettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case account
  case appearance
  case session
  case mcp
  case hooks

  var id: String { rawValue }

  var title: String {
    switch self {
    case .account: return "账号与模型"
    case .appearance: return "外观"
    case .session: return "会话"
    case .mcp: return "MCP 服务器"
    case .hooks: return "行为与权限"
    }
  }

  var icon: String {
    switch self {
    case .account: return "key.fill"
    case .appearance: return "circle.lefthalf.filled"
    case .session: return "bubble.left.and.bubble.right"
    case .mcp: return "server.rack"
    case .hooks: return "slider.horizontal.below.rectangle"
    }
  }
}
