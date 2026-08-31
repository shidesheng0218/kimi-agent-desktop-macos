// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "KimiCodeAgent",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "KimiAgentCore", targets: ["KimiAgentCore"]),
    .executable(name: "KimiCodeAgent", targets: ["KimiCodeAgent"]),
    .executable(name: "KimiNativeBridge", targets: ["KimiNativeBridge"]),
    .executable(name: "BrowserSmokeCheck", targets: ["BrowserSmokeCheck"]),
    .executable(name: "ComputerUseSmokeCheck", targets: ["ComputerUseSmokeCheck"]),
    .executable(name: "RestartRecoveryCheck", targets: ["RestartRecoveryCheck"])
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.5.0")
  ],
  targets: [
    .target(name: "KimiAgentCore", dependencies: []),
    .executableTarget(
      name: "KimiCodeAgent",
      dependencies: [
        "KimiAgentCore",
        .product(name: "Sparkle", package: "Sparkle")
      ],
      linkerSettings: [
        // The packaged app embeds Sparkle.xcframework in Contents/Frameworks,
        // so the executable must resolve it relative to itself once installed.
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]
    ),
    .executableTarget(name: "KimiNativeBridge", dependencies: ["KimiAgentCore"]),
    .executableTarget(name: "KimiAgentCoreChecks", dependencies: ["KimiAgentCore"]),
    .executableTarget(name: "BrowserSmokeCheck", dependencies: ["KimiAgentCore"]),
    .executableTarget(name: "ComputerUseSmokeCheck", dependencies: ["KimiAgentCore"]),
    .executableTarget(name: "RestartRecoveryCheck", dependencies: ["KimiAgentCore"])
  ]
)
