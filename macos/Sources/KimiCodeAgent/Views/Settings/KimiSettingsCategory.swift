import SwiftUI

enum KimiSettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case account
  case mcp
  case hooks

  var id: String { rawValue }

  var title: String {
    switch self {
    case .account: return "账号与模型"
    case .mcp: return "MCP 服务器"
    case .hooks: return "行为与权限"
    }
  }

  var icon: String {
    switch self {
    case .account: return "key.fill"
    case .mcp: return "server.rack"
    case .hooks: return "slider.horizontal.below.rectangle"
    }
  }
}
