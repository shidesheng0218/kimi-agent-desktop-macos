import Foundation

public enum KimiProcessStream: Sendable {
  case standardOutput
  case standardError
}

public struct KimiProcessOutput: Sendable {
  public let stream: KimiProcessStream
  public let text: String

  public init(stream: KimiProcessStream, text: String) {
    self.stream = stream
    self.text = text
  }
}

public struct KimiProcessResult: Sendable {
  public let standardOutput: String
  public let standardError: String
  public let exitCode: Int32

  public init(standardOutput: String, standardError: String, exitCode: Int32) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitCode = exitCode
  }
}

public final class KimiProcessHandle: @unchecked Sendable {
  private let process: Process
  private let stdoutPipe: Pipe
  private let stderrPipe: Pipe
  private let onOutput: ((KimiProcessOutput) -> Void)?
  private let lock = NSLock()
  private let outputCondition = NSCondition()
  private var standardOutput = ""
  private var standardError = ""

  init(
    process: Process,
    stdoutPipe: Pipe,
    stderrPipe: Pipe,
    onOutput: ((KimiProcessOutput) -> Void)?
  ) {
    self.process = process
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
    self.onOutput = onOutput
    observe(stdoutPipe.fileHandleForReading, stream: .standardOutput)
    observe(stderrPipe.fileHandleForReading, stream: .standardError)
  }

  public var isRunning: Bool {
    process.isRunning
  }

  public var processIdentifier: Int32 {
    process.processIdentifier
  }

  public var standardOutputSnapshot: String {
    lock.lock()
    defer { lock.unlock() }
    return standardOutput
  }

  public func terminate() {
    if process.isRunning {
      process.terminate()
    }
  }

  /// Registers a callback fired exactly once when the underlying process
  /// exits, for any reason (intentional terminate() or an unexpected crash).
  /// `Process.terminationHandler` runs on an arbitrary background thread
  /// (not necessarily the thread that called `run()`), so callers that need
  /// actor isolation must hop back onto their own executor from inside the
  /// handler — this method only guarantees the callback fires once, exactly
  /// when the process dies, in place of a polling loop.
  public func onTermination(_ handler: @escaping @Sendable (Int32) -> Void) {
    process.terminationHandler = { finishedProcess in
      handler(finishedProcess.terminationStatus)
    }
  }

  public func wait() -> KimiProcessResult {
    process.waitUntilExit()
    drain(stdoutPipe.fileHandleForReading, stream: .standardOutput)
    drain(stderrPipe.fileHandleForReading, stream: .standardError)
    lock.lock()
    let result = KimiProcessResult(
      standardOutput: standardOutput,
      standardError: standardError,
      exitCode: process.terminationStatus
    )
    lock.unlock()
    return result
  }

  public func waitForStandardOutput(containing text: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    outputCondition.lock()
    defer { outputCondition.unlock() }
    while !currentStandardOutput.contains(text) {
      if !process.isRunning { return currentStandardOutput.contains(text) }
      if !outputCondition.wait(until: deadline) { return currentStandardOutput.contains(text) }
    }
    return true
  }

  private var currentStandardOutput: String {
    lock.lock()
    defer { lock.unlock() }
    return standardOutput
  }

  private func observe(_ fileHandle: FileHandle, stream: KimiProcessStream) {
    fileHandle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.append(data, stream: stream)
    }
  }

  private func drain(_ fileHandle: FileHandle, stream: KimiProcessStream) {
    fileHandle.readabilityHandler = nil
    let remainingData = fileHandle.readDataToEndOfFile()
    if !remainingData.isEmpty {
      append(remainingData, stream: stream)
    }
  }

  private func append(_ data: Data, stream: KimiProcessStream) {
    let text = String(data: data, encoding: .utf8) ?? ""
    guard !text.isEmpty else { return }
    lock.lock()
    switch stream {
    case .standardOutput:
      standardOutput += text
    case .standardError:
      standardError += text
    }
    lock.unlock()
    outputCondition.lock()
    outputCondition.broadcast()
    outputCondition.unlock()
    onOutput?(KimiProcessOutput(stream: stream, text: text))
  }
}

public enum KimiProcessRunner {
  public static func start(
    _ command: KimiCommand,
    workingDirectory: URL? = nil,
    environment: [String: String] = [:],
    onOutput: ((KimiProcessOutput) -> Void)? = nil
  ) throws -> KimiProcessHandle {
    let process = Process()
    process.executableURL = command.executableURL
    process.arguments = command.arguments
    process.currentDirectoryURL = workingDirectory
    if !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new })
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    return KimiProcessHandle(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, onOutput: onOutput)
  }

  public static func run(_ command: KimiCommand, workingDirectory: URL? = nil, environment: [String: String] = [:]) throws -> KimiProcessResult {
    try start(command, workingDirectory: workingDirectory, environment: environment).wait()
  }
}
