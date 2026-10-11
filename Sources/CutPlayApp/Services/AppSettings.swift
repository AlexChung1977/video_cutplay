#if os(macOS)
import Foundation
import Observation
import Security
import CutPlayCore

/// App-wide preferences (not per project).
@Observable
final class AppSettings {
    enum AIMode: String, CaseIterable, Identifiable {
        /// Built-in offline rules only.
        case rulesOnly
        /// An OpenAI-compatible server on this Mac (Ollama, LM Studio, llama-server).
        case localServer
        /// A cloud API. Only text (transcript/index) is sent, never media.
        case cloud

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .rulesOnly: return "只用內建規則（完全離線）"
            case .localServer: return "這台 Mac 上的模型伺服器"
            case .cloud: return "雲端模型（只傳文字，不傳影片）"
            }
        }
    }

    private let defaults = UserDefaults.standard

    var autoApplyHighConfidence: Bool { didSet { defaults.set(autoApplyHighConfidence, forKey: "autoApplyHighConfidence") } }
    var aiMode: AIMode { didSet { defaults.set(aiMode.rawValue, forKey: "aiMode") } }
    var localServerURL: String { didSet { defaults.set(localServerURL, forKey: "localServerURL") } }
    var localModel: String { didSet { defaults.set(localModel, forKey: "localModel") } }
    var cloudURL: String { didSet { defaults.set(cloudURL, forKey: "cloudURL") } }
    var cloudModel: String { didSet { defaults.set(cloudModel, forKey: "cloudModel") } }
    var cloudConsentGiven: Bool { didSet { defaults.set(cloudConsentGiven, forKey: "cloudConsentGiven") } }
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var lastProjectPath: String? { didSet { defaults.set(lastProjectPath, forKey: "lastProjectPath") } }

    var cloudAPIKey: String {
        get { Keychain.read("cloudAPIKey") ?? "" }
        set { Keychain.write("cloudAPIKey", newValue) }
    }

    init() {
        autoApplyHighConfidence = defaults.bool(forKey: "autoApplyHighConfidence")
        aiMode = AIMode(rawValue: defaults.string(forKey: "aiMode") ?? "") ?? .rulesOnly
        localServerURL = defaults.string(forKey: "localServerURL") ?? "http://localhost:11434/v1"
        localModel = defaults.string(forKey: "localModel") ?? "qwen2.5:7b-instruct"
        cloudURL = defaults.string(forKey: "cloudURL") ?? "https://api.openai.com/v1"
        cloudModel = defaults.string(forKey: "cloudModel") ?? "gpt-4o-mini"
        cloudConsentGiven = defaults.bool(forKey: "cloudConsentGiven")
        language = defaults.string(forKey: "language") ?? "zh"
        lastProjectPath = defaults.string(forKey: "lastProjectPath")
    }

    var isCloud: Bool { aiMode == .cloud }

    func makePlanner() -> EditPlanner {
        switch aiMode {
        case .rulesOnly:
            return HybridPlanner()
        case .localServer:
            guard let url = URL(string: localServerURL) else { return HybridPlanner() }
            return HybridPlanner(llm: LLMPlanner(transport: OpenAICompatibleTransport(baseURL: url, model: localModel)))
        case .cloud:
            guard cloudConsentGiven, let url = URL(string: cloudURL) else { return HybridPlanner() }
            return HybridPlanner(llm: LLMPlanner(transport: OpenAICompatibleTransport(baseURL: url, apiKey: cloudAPIKey, model: cloudModel)))
        }
    }
}

enum Keychain {
    static let service = "app.cutplay"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
