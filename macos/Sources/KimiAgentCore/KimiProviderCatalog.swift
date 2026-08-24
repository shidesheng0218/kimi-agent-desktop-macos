import Foundation

/// Declarative metadata for a model provider the engine can route to. This is
/// configuration data only — it contains no HTTP request code. The engine's
/// own provider layer (Vercel AI SDK + models.dev) handles all actual model
/// communication; these descriptors just tell the config generator what
/// provider entries to emit into OPENCODE_CONFIG_CONTENT.
public struct KimiProviderDescriptor: Sendable, Equatable, Identifiable {
  /// Engine-side provider key, e.g. "moonshotai-cn". Used as the key in the
  /// `provider` config map and in per-prompt ModelRef strings.
  public let id: String
  /// Display name shown in the provider settings UI.
  public let displayName: String
  /// Default API base URL offered as a prefilled value in the settings form.
  public let defaultBaseURL: String
  /// Value for the engine's `npm` field (Vercel AI SDK package name).
  public let npmPackage: String
  /// Environment variable name that carries this provider's credential into
  /// the engine process. The engine's `options.apiKey` is written as
  /// `{env:<name>}` so the secret never lands in the config blob itself.
  public let apiKeyEnvVar: String
  /// Preset model IDs offered in the model selector for this provider.
  public let modelIDs: [String]

  public init(
    id: String,
    displayName: String,
    defaultBaseURL: String,
    npmPackage: String,
    apiKeyEnvVar: String,
    modelIDs: [String]
  ) {
    self.id = id
    self.displayName = displayName
    self.defaultBaseURL = defaultBaseURL
    self.npmPackage = npmPackage
    self.apiKeyEnvVar = apiKeyEnvVar
    self.modelIDs = modelIDs
  }
}

public enum KimiProviderCatalog {
  public static let descriptors: [KimiProviderDescriptor] = [
    KimiProviderDescriptor(
      id: "moonshotai-cn",
      displayName: "Moonshot AI (Kimi)",
      defaultBaseURL: "https://api.moonshot.cn/v1",
      npmPackage: "@ai-sdk/openai-compatible",
      apiKeyEnvVar: "KIMI_API_KEY",
      modelIDs: ["kimi-k2.7-code", "kimi-k3", "kimi-k2.7-code-highspeed", "kimi-k2-thinking"]
    ),
    KimiProviderDescriptor(
      id: "openai",
      displayName: "OpenAI",
      defaultBaseURL: "https://api.openai.com/v1",
      npmPackage: "@ai-sdk/openai",
      apiKeyEnvVar: "OPENAI_API_KEY",
      modelIDs: ["gpt-5.2", "gpt-5.1", "gpt-5-mini", "o3", "o4-mini"]
    ),
    KimiProviderDescriptor(
      id: "anthropic",
      displayName: "Anthropic",
      defaultBaseURL: "https://api.anthropic.com/v1",
      npmPackage: "@ai-sdk/anthropic",
      apiKeyEnvVar: "ANTHROPIC_API_KEY",
      modelIDs: ["claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
    ),
    KimiProviderDescriptor(
      id: "ollama",
      displayName: "Ollama (Local)",
      defaultBaseURL: "http://localhost:11434/v1",
      npmPackage: "@ai-sdk/ollama",
      apiKeyEnvVar: "OLLAMA_API_KEY",
      modelIDs: ["llama3.3", "qwen3", "deepseek-r1", "codellama"]
    )
  ]

  /// Looks up a descriptor by its engine-side provider ID, or nil if unknown.
  public static func descriptor(for id: String) -> KimiProviderDescriptor? {
    descriptors.first { $0.id == id }
  }
}
