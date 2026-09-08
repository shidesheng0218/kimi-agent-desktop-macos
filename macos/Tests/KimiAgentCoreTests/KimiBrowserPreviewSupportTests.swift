import XCTest
@testable import KimiAgentCore

/// 迁移自 KimiAgentCoreChecks：浏览器预览支撑（dev server 计划、本地地址提取、
/// 可预览文件类型判定）。
final class KimiBrowserPreviewSupportTests: XCTestCase {
  private var fixtureRoot: URL!

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("kimi-devserver-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: fixtureRoot)
    fixtureRoot = nil
  }

  private func writePackageJSON(_ body: String) throws {
    try body.write(to: fixtureRoot.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
  }

  func testDevServerPlanPrefersDevScriptWithNpmByDefault() throws {
    try writePackageJSON(#"{"scripts":{"dev":"vite","build":"vite build"}}"#)
    let plan = try XCTUnwrap(KimiBrowserPreviewSupport.devServerPlan(forProjectRoot: fixtureRoot))
    XCTAssertEqual(plan, KimiDevServerPlan(packageManager: "npm", script: "dev"), "有 dev 脚本且无 lockfile 时必须选择 npm run dev")
    XCTAssertEqual(plan.command.arguments, ["npm", "run", "dev"], "启动计划命令必须经由 /usr/bin/env 运行包管理器")
  }

  func testDevServerPlanInfersPackageManagerFromLockfile() throws {
    try writePackageJSON(#"{"scripts":{"dev":"vite"}}"#)
    try Data().write(to: fixtureRoot.appendingPathComponent("pnpm-lock.yaml"))
    XCTAssertEqual(KimiBrowserPreviewSupport.devServerPlan(forProjectRoot: fixtureRoot)?.packageManager, "pnpm", "存在 pnpm-lock.yaml 时必须使用 pnpm")
    try FileManager.default.removeItem(at: fixtureRoot.appendingPathComponent("pnpm-lock.yaml"))
    try Data().write(to: fixtureRoot.appendingPathComponent("yarn.lock"))
    XCTAssertEqual(KimiBrowserPreviewSupport.devServerPlan(forProjectRoot: fixtureRoot)?.packageManager, "yarn", "存在 yarn.lock 时必须使用 yarn")
  }

  func testDevServerPlanFallsBackToStartScript() throws {
    try writePackageJSON(#"{"scripts":{"start":"next start"}}"#)
    XCTAssertEqual(KimiBrowserPreviewSupport.devServerPlan(forProjectRoot: fixtureRoot)?.script, "start", "无 dev 脚本时必须回退 start 脚本")
  }

  func testDevServerPlanIsNilWithoutDevOrStartScript() throws {
    try writePackageJSON(#"{"scripts":{"build":"tsc"}}"#)
    XCTAssertNil(KimiBrowserPreviewSupport.devServerPlan(forProjectRoot: fixtureRoot), "无 dev/start 脚本时不得生成启动计划")
  }

  func testDevServerPlanIsNilWithoutPackageJSON() {
    XCTAssertNil(KimiBrowserPreviewSupport.devServerPlan(forProjectRoot: fixtureRoot))
  }

  func testExtractLocalURLPicksFirstLoopbackAddress() {
    let viteOutput = "VITE v5.0.0  ready in 321 ms\n\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: http://192.168.1.5:5173/"
    XCTAssertEqual(KimiBrowserPreviewSupport.extractLocalURL(from: viteOutput)?.absoluteString, "http://localhost:5173/", "必须提取首个 localhost 地址而忽略局域网地址")
  }

  func testExtractLocalURLTrimsTrailingPunctuation() {
    XCTAssertEqual(
      KimiBrowserPreviewSupport.extractLocalURL(from: "Server running at http://127.0.0.1:8080/index.html.")?.absoluteString,
      "http://127.0.0.1:8080/index.html",
      "127.0.0.1 地址必须被提取且去掉尾随标点"
    )
  }

  func testExtractLocalURLRejectsNonLoopbackAddress() {
    XCTAssertNil(KimiBrowserPreviewSupport.extractLocalURL(from: "see https://example.com/docs"), "非环回地址不得被当作 dev server 地址")
  }

  func testIsBrowserPreviewableFile() {
    XCTAssertTrue(KimiBrowserPreviewSupport.isBrowserPreviewableFile(URL(fileURLWithPath: "/tmp/a/index.html")), "HTML 必须可在浏览器面板预览")
    XCTAssertTrue(KimiBrowserPreviewSupport.isBrowserPreviewableFile(URL(fileURLWithPath: "/tmp/a/report.PDF")), "PDF（大小写不敏感）必须可在浏览器面板预览")
    XCTAssertTrue(KimiBrowserPreviewSupport.isBrowserPreviewableFile(URL(fileURLWithPath: "/tmp/a/shot.png")), "图片必须可在浏览器面板预览")
    XCTAssertTrue(KimiBrowserPreviewSupport.isBrowserPreviewableFile(URL(fileURLWithPath: "/tmp/a/demo.mp4")), "视频必须可在浏览器面板预览")
    XCTAssertFalse(KimiBrowserPreviewSupport.isBrowserPreviewableFile(URL(fileURLWithPath: "/tmp/a/main.swift")), "源代码文件不得在浏览器面板预览")
    XCTAssertFalse(KimiBrowserPreviewSupport.isBrowserPreviewableFile(URL(fileURLWithPath: "/tmp/a/notes.txt")), "纯文本文件不得在浏览器面板预览")
  }
}
