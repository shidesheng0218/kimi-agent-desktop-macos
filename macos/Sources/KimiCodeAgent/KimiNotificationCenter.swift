import AppKit
import UserNotifications

/// 系统通知：会话由忙转闲（完成）或出现新的待审批权限卡时提醒。
/// 只在该会话不是当前查看会话、或应用窗口不在前台时发出；点击通知激活
/// 应用并跳转到对应会话。开关在「设置 → 行为与权限」，默认开。
@MainActor
final class KimiNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
  static let shared = KimiNotificationCenter()
  static let enabledDefaultsKey = "kimi.notifications.enabled"

  /// 点击通知的回调，参数为本地会话 UUID；由根视图装配到 ViewModel.select。
  var onSelectSession: ((UUID) -> Void)?

  private var authorizationRequested = false

  /// UNUserNotificationCenter 只在接受 .app 包的进程里可用;
  /// 直接运行裸可执行文件(swift run / .build/debug)时 current() 会直接抛异常崩溃。
  private var isBundledApp: Bool {
    Bundle.main.bundleURL.pathExtension == "app"
  }

  /// 默认开：在用户从未动过开关时也视为开启。
  func registerDefaults() {
    UserDefaults.standard.register(defaults: [Self.enabledDefaultsKey: true])
  }

  var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
  }

  /// 首次使用前请求授权；未打包成 .app 的调试进程里通知不可用,由 isBundledApp 跳过。
  func requestAuthorizationIfNeeded() {
    guard isBundledApp, !authorizationRequested else { return }
    authorizationRequested = true
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func post(title: String, body: String, sessionID: UUID) {
    guard isBundledApp, isEnabled else { return }
    requestAuthorizationIfNeeded()
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.userInfo = ["sessionID": sessionID.uuidString]
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    // 触发条件已排除「当前会话 + 前台」，到达这里的通知直接展示横幅。
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let raw = response.notification.request.content.userInfo["sessionID"] as? String
    await MainActor.run {
      NSApplication.shared.activate(ignoringOtherApps: true)
      if let raw, let sessionID = UUID(uuidString: raw) {
        self.onSelectSession?(sessionID)
      }
    }
  }
}
