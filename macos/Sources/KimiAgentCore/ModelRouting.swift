import Foundation

public struct TaskBudget: Codable, Equatable, Sendable {
  public let maxCost: Decimal
  public let maxInputTokens: Int
  public let maxOutputTokens: Int
  public let maxWallTimeSeconds: Int
  public let maxRepairRounds: Int

  public init(maxCost: Decimal, maxInputTokens: Int, maxOutputTokens: Int, maxWallTimeSeconds: Int, maxRepairRounds: Int) {
    self.maxCost = max(0, maxCost)
    self.maxInputTokens = max(1, maxInputTokens)
    self.maxOutputTokens = max(1, maxOutputTokens)
    self.maxWallTimeSeconds = max(1, maxWallTimeSeconds)
    self.maxRepairRounds = max(0, maxRepairRounds)
  }

  public static let standard = TaskBudget(maxCost: 1, maxInputTokens: 12_000, maxOutputTokens: 4_000, maxWallTimeSeconds: 600, maxRepairRounds: 3)
}

public enum ModelTier: String, Codable, Sendable {
  case fast
  case balanced
  case reasoning
}

public struct ModelRoute: Codable, Equatable, Sendable {
  public let tier: ModelTier
  public let maximumOutputTokens: Int
  public let reason: String

  public init(tier: ModelTier, maximumOutputTokens: Int, reason: String) {
    self.tier = tier
    self.maximumOutputTokens = max(1, maximumOutputTokens)
    self.reason = reason
  }
}

public enum ModelRouteSource: String, Codable, Equatable, Sendable {
  case preferred
  case tierOverride
}

public struct ResolvedModelRoute: Codable, Equatable, Sendable {
  public let modelID: String
  public let tier: ModelTier
  public let source: ModelRouteSource

  public init(modelID: String, tier: ModelTier, source: ModelRouteSource) {
    self.modelID = modelID
    self.tier = tier
    self.source = source
  }
}

/// Resolves a logical route to an actual configured Kimi model. Routing is
/// opt-in through environment/profile settings; without an override the
/// user's selected model remains authoritative instead of silently switching
/// to a model that may not exist on their account.
public enum ModelRouteResolver {
  public static func resolve(
    preferredModelID: String,
    route: ModelRoute,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ResolvedModelRoute {
    let preferred = preferredModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = "KIMI_AGENT_MODEL_\(route.tier.rawValue.uppercased())"
    let override = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resolved = override.isEmpty ? preferred : override
    return ResolvedModelRoute(
      modelID: resolved.isEmpty ? "kimi-k2.7-code" : resolved,
      tier: route.tier,
      source: override.isEmpty ? .preferred : .tierOverride
    )
  }
}

public extension AgentKind {
  var modelRoutingIntent: TaskIntent {
    switch self {
    case .explore: .explore
    case .plan: .plan
    case .implement: .implement
    case .test: .test
    case .review: .review
    case .webResearch: .webResearch
    case .browser, .browserVerification: .browserVerification
    case .computerUse: .computerUse
    case .debug: .debug
    }
  }
}

/// Deterministic first-pass routing keeps simple requests off the expensive
/// path. A provider-specific selector may map a tier to a configured model.
public enum ModelRouter {
  public static func route(intent: TaskIntent, promptLength: Int, budget: TaskBudget) -> ModelRoute {
    let tier: ModelTier
    switch intent {
    case .conversation, .explanation:
      tier = promptLength < 2_000 ? .fast : .balanced
    case .explore, .webResearch, .review, .test:
      tier = .balanced
    case .plan, .implement, .debug, .browserVerification, .computerUse, .externalCollaboration:
      tier = .reasoning
    }
    let cap: Int
    switch tier {
    case .fast: cap = min(budget.maxOutputTokens, 900)
    case .balanced: cap = min(budget.maxOutputTokens, 2_000)
    case .reasoning: cap = budget.maxOutputTokens
    }
    return ModelRoute(tier: tier, maximumOutputTokens: cap, reason: "intent=\(intent.rawValue); promptLength=\(promptLength)")
  }
}

public struct ModelPriceCard: Codable, Equatable, Sendable {
  public let inputPerMillion: Decimal
  public let outputPerMillion: Decimal
  public let cachedInputPerMillion: Decimal

  public init(inputPerMillion: Decimal, outputPerMillion: Decimal, cachedInputPerMillion: Decimal = 0) {
    self.inputPerMillion = max(0, inputPerMillion)
    self.outputPerMillion = max(0, outputPerMillion)
    self.cachedInputPerMillion = max(0, cachedInputPerMillion)
  }

  public func estimate(inputTokens: Int, outputTokens: Int, cachedTokens: Int = 0) -> Decimal {
    let input = Decimal(max(0, inputTokens))
    let output = Decimal(max(0, outputTokens))
    let cached = Decimal(min(max(0, cachedTokens), max(0, inputTokens)))
    let uncached = input - cached
    return (uncached * inputPerMillion + cached * cachedInputPerMillion + output * outputPerMillion) / Decimal(1_000_000)
  }
}

public enum UsageCostStatus: String, Codable, Equatable, Sendable {
  case calculated
  case estimated
  case unconfigured
}

public enum ModelPriceCatalog {
  public static func price(
    provider: String,
    model: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ModelPriceCard? {
    let prefix = "KIMI_AGENT_PRICE_"
    let key = model.uppercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: ".", with: "_")
    let input = environment[prefix + key + "_INPUT"] ?? environment[prefix + "INPUT"]
    let output = environment[prefix + key + "_OUTPUT"] ?? environment[prefix + "OUTPUT"]
    guard let input,
          let output,
          let inputPrice = Decimal(string: input),
          let outputPrice = Decimal(string: output) else {
      return nil
    }
    let cached = environment[prefix + key + "_CACHED"] ?? environment[prefix + "CACHED"]
    return ModelPriceCard(
      inputPerMillion: inputPrice,
      outputPerMillion: outputPrice,
      cachedInputPerMillion: Decimal(string: cached ?? "0") ?? 0
    )
  }

  public static func cost(
    provider: String,
    model: String,
    inputTokens: Int,
    outputTokens: Int,
    cachedTokens: Int = 0,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> (value: Decimal, status: UsageCostStatus) {
    guard let card = price(provider: provider, model: model, environment: environment) else {
      return (0, .unconfigured)
    }
    return (card.estimate(inputTokens: inputTokens, outputTokens: outputTokens, cachedTokens: cachedTokens), .calculated)
  }
}

public enum CostBudgetDecision: String, Codable, Equatable, Sendable {
  case allowed
  case warning
  case exceeded
}

public enum CostBudgetGate {
  public static func decision(spent: Decimal, budget: Decimal) -> CostBudgetDecision {
    let safeBudget = max(0, budget)
    guard safeBudget > 0 else { return .exceeded }
    if spent > safeBudget { return .exceeded }
    if spent >= safeBudget * Decimal(string: "0.8")! { return .warning }
    return .allowed
  }
}

public struct UsageLedgerEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let operationID: UUID
  public let stage: AgentKind
  public let provider: String
  public let model: String
  public let inputTokens: Int
  public let outputTokens: Int
  public let cachedTokens: Int
  public let latencyMS: Int
  public let estimatedCost: Decimal
  public let pricingStatus: UsageCostStatus
  public let qualityScore: Double?
  /// Runtime session ID (`ses_...`) the turn ran in. Optional and absent in
  /// entries written before this field existed — those simply don't
  /// attribute to any session in per-session rollups.
  public let sessionID: String?
  public let createdAt: Date

  public init(
    id: UUID = UUID(), operationID: UUID, stage: AgentKind, provider: String, model: String,
    inputTokens: Int, outputTokens: Int, cachedTokens: Int = 0, latencyMS: Int,
    estimatedCost: Decimal, qualityScore: Double?, pricingStatus: UsageCostStatus = .calculated,
    sessionID: String? = nil, createdAt: Date = .now
  ) {
    self.id = id
    self.operationID = operationID
    self.stage = stage
    self.provider = provider
    self.model = model
    self.inputTokens = max(0, inputTokens)
    self.outputTokens = max(0, outputTokens)
    self.cachedTokens = max(0, cachedTokens)
    self.latencyMS = max(0, latencyMS)
    self.estimatedCost = max(0, estimatedCost)
    self.pricingStatus = pricingStatus
    self.qualityScore = qualityScore.map { min(max($0, 0), 1) }
    self.sessionID = sessionID
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, operationID, stage, provider, model, inputTokens, outputTokens, cachedTokens, latencyMS, estimatedCost, pricingStatus, qualityScore, sessionID, createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      operationID: try container.decode(UUID.self, forKey: .operationID),
      stage: try container.decode(AgentKind.self, forKey: .stage),
      provider: try container.decode(String.self, forKey: .provider),
      model: try container.decode(String.self, forKey: .model),
      inputTokens: try container.decode(Int.self, forKey: .inputTokens),
      outputTokens: try container.decode(Int.self, forKey: .outputTokens),
      cachedTokens: try container.decodeIfPresent(Int.self, forKey: .cachedTokens) ?? 0,
      latencyMS: try container.decodeIfPresent(Int.self, forKey: .latencyMS) ?? 0,
      estimatedCost: try container.decodeIfPresent(Decimal.self, forKey: .estimatedCost) ?? 0,
      qualityScore: try container.decodeIfPresent(Double.self, forKey: .qualityScore),
      pricingStatus: try container.decodeIfPresent(UsageCostStatus.self, forKey: .pricingStatus) ?? .calculated,
      sessionID: try container.decodeIfPresent(String.self, forKey: .sessionID),
      createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    )
  }
}

public final class UsageLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [UsageLedgerEntry] = []
  private let fileURL: URL?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    if let fileURL, let data = try? Data(contentsOf: fileURL), let restored = try? JSONDecoder().decode([UsageLedgerEntry].self, from: data) {
      entries = restored
    }
  }

  public func append(_ entry: UsageLedgerEntry) throws {
    lock.lock()
    if entries.contains(where: { $0.id == entry.id }) {
      lock.unlock()
      return
    }
    entries.append(entry)
    let snapshot = entries
    lock.unlock()
    if let fileURL {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
  }

  public func snapshot() -> [UsageLedgerEntry] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  public func totalCost(operationID: UUID? = nil) -> Decimal {
    lock.lock()
    defer { lock.unlock() }
    return entries.lazy.filter { operationID == nil || $0.operationID == operationID }.reduce(Decimal.zero) { $0 + $1.estimatedCost }
  }

  /// Per-session rollup for the conversation header. Entries written before
  /// the sessionID field existed are simply not attributed to any session.
  public func sessionUsage(sessionID: String) -> (tokens: Int, cost: Decimal)? {
    lock.lock()
    defer { lock.unlock() }
    let matched = entries.filter { $0.sessionID == sessionID }
    guard !matched.isEmpty else { return nil }
    let tokens = matched.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    let cost = matched.reduce(Decimal.zero) { $0 + $1.estimatedCost }
    return (tokens, cost)
  }

  public func contains(operationID: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return entries.contains { $0.operationID == operationID }
  }
}
