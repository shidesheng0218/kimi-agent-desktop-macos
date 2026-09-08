import SwiftUI
import WebKit
import KimiAgentCore

/// 预览浏览器控制器:常驻 WKWebView(跨面板切换/槽位移动保活,页面状态不丢),
/// 与引擎验证用的 off-screen WKWebView(KimiNativeBridge / BrowserVerificationController)
/// 完全分离——只响应用户在地址栏/面板内的导航,引擎无法驱动它。
@MainActor
final class KimiBrowserPreviewController: NSObject, ObservableObject {
  /// 面板分段:交互预览 / 引擎验证截图产物。
  enum Section: String, CaseIterable, Identifiable {
    case preview
    case artifacts

    var id: String { rawValue }
    var title: String { self == .preview ? "预览" : "验证截图" }
  }

  @Published var section: Section = .preview
  @Published var addressText = ""
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  @Published private(set) var isLoading = false
  @Published private(set) var pageTitle: String?

  /// 本地文件预览允许读取的目录(会话 workingPath),记录下来供界面提示。
  @Published private(set) var fileAccessRoot: URL?

  private var observations: [NSKeyValueObservation] = []

  lazy var webView: WKWebView = {
    let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    view.allowsBackForwardNavigationGestures = true
    view.navigationDelegate = self
    observations = [
      view.observe(\.canGoBack) { [weak self] _, _ in
        Task { @MainActor in self?.syncState() }
      },
      view.observe(\.canGoForward) { [weak self] _, _ in
        Task { @MainActor in self?.syncState() }
      },
    ]
    return view
  }()

  /// 地址栏回车:无 scheme 的输入按 https 网站处理。
  func submitAddress() {
    let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let url: URL?
    if let parsed = URL(string: text), let scheme = parsed.scheme, !scheme.isEmpty {
      url = parsed
    } else {
      url = URL(string: "https://\(text)")
    }
    guard let url else { return }
    navigate(to: url)
  }

  func navigate(to url: URL) {
    section = .preview
    if url.isFileURL {
      openFile(url, readAccessRoot: nil)
    } else {
      fileAccessRoot = nil
      webView.load(URLRequest(url: url))
      addressText = url.absoluteString
      syncState()
    }
  }

  /// 本地文件预览:allowingReadAccessTo 给项目根,HTML 里的相对资源
  /// (CSS/JS/图片)与 sibling 文件才能加载;无项目时退化为文件所在目录。
  func openFile(_ fileURL: URL, readAccessRoot: URL?) {
    section = .preview
    let root = readAccessRoot ?? fileURL.deletingLastPathComponent()
    fileAccessRoot = root
    webView.loadFileURL(fileURL, allowingReadAccessTo: root)
    addressText = fileURL.path
    syncState()
  }

  func goBack() { webView.goBack() }
  func goForward() { webView.goForward() }
  func reload() { webView.reload() }
  func stopLoading() { webView.stopLoading() }

  func openExternally() {
    if let url = webView.url {
      NSWorkspace.shared.open(url)
    } else {
      let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
      if let url = URL(string: text), url.scheme != nil {
        NSWorkspace.shared.open(url)
      }
    }
  }

  fileprivate func syncState() {
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    isLoading = webView.isLoading
    pageTitle = webView.title?.isEmpty == false ? webView.title : nil
    if let url = webView.url {
      addressText = url.isFileURL ? url.path : url.absoluteString
    }
  }
}

extension KimiBrowserPreviewController: WKNavigationDelegate {
  nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    Task { @MainActor in self.syncState() }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { @MainActor in self.syncState() }
  }

  nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    Task { @MainActor in self.syncState() }
  }

  nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    Task { @MainActor in self.syncState() }
  }
}

/// 常驻 WKWebView 的 SwiftUI 桥接:webview 实例归控制器所有,
/// 面板关闭再打开只是重新挂载视图,浏览状态保留。
struct KimiWebPreviewView: NSViewRepresentable {
  let webView: WKWebView

  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 会话级开发服务器:每个会话最多一个,切换会话不杀进程(面板只显示
/// 当前会话的状态);应用退出时经 KimiEngineTerminationRegistry 统一 SIGTERM。
@MainActor
final class KimiDevServerManager: ObservableObject {
  struct SessionServer: Equatable {
    var running = false
    var pid: Int32?
    var command = ""
    var detectedURL: URL?
    /// 进程输出尾部(最近 50 行),排障用。
    var tailLines: [String] = []
    var lastError: String?
  }

  @Published private(set) var servers: [UUID: SessionServer] = [:]
  private var handles: [UUID: KimiProcessHandle] = [:]
  /// 首次从输出提取到本地地址时的回调,由 ViewModel 装配为自动导航。
  var onURLDetected: ((UUID, URL) -> Void)?

  func state(for sessionID: UUID?) -> SessionServer? {
    sessionID.flatMap { servers[$0] }
  }

  func start(sessionID: UUID, workingPath: String, plan: KimiDevServerPlan) {
    if handles[sessionID] != nil { stop(sessionID: sessionID) }
    var server = SessionServer()
    server.command = plan.displayCommand
    server.running = true
    servers[sessionID] = server
    do {
      let handle = try KimiProcessRunner.start(
        plan.command,
        workingDirectory: URL(fileURLWithPath: workingPath, isDirectory: true)
      ) { [weak self] output in
        Task { [weak self] in
          await self?.appendOutput(sessionID: sessionID, text: output.text)
        }
      }
      handles[sessionID] = handle
      // 复用引擎进程登记表:applicationWillTerminate 时随引擎一起 SIGTERM。
      KimiEngineTerminationRegistry.shared.register(handle)
      let pid = handle.processIdentifier
      handle.onTermination { [weak self] _ in
        Task { [weak self] in
          await self?.didTerminate(sessionID: sessionID, pid: pid)
        }
      }
      servers[sessionID]?.pid = pid
    } catch {
      servers[sessionID]?.running = false
      servers[sessionID]?.lastError = error.localizedDescription
    }
  }

  func stop(sessionID: UUID) {
    guard let handle = handles[sessionID] else { return }
    KimiEngineTerminationRegistry.shared.unregister(processIdentifier: handle.processIdentifier)
    handle.terminate()
    // 状态清理由 onTermination 回调完成。
  }

  private func appendOutput(sessionID: UUID, text: String) {
    guard var server = servers[sessionID] else { return }
    server.tailLines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
    if server.tailLines.count > 50 {
      server.tailLines = Array(server.tailLines.suffix(50))
    }
    if server.detectedURL == nil, let url = KimiBrowserPreviewSupport.extractLocalURL(from: text) {
      server.detectedURL = url
      onURLDetected?(sessionID, url)
    }
    servers[sessionID] = server
  }

  private func didTerminate(sessionID: UUID, pid: Int32) {
    handles[sessionID] = nil
    KimiEngineTerminationRegistry.shared.unregister(processIdentifier: pid)
    servers[sessionID]?.running = false
  }
}
