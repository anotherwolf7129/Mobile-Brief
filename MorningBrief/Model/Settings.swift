import Foundation
import Combine
import Security

/// User-facing configuration, persisted in `UserDefaults`.
/// The Claude API key is the one exception — it lives in the Keychain.
///
/// Every property declares an inline default so the `@Published` wrapper is
/// fully initialized from its declaration; `init` then overwrites from stored
/// values, and each `didSet` writes back.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Key {
        static let hour = "brief.hour"
        static let minute = "brief.minute"
        static let weekdaysOnly = "brief.weekdaysOnly"
        static let handsFree = "brief.handsFree"
        static let voiceLanguage = "brief.voiceLanguage"
        static let voiceIdentifier = "brief.voiceIdentifier"
        static let speechRate = "brief.speechRate"
        static let useClaude = "brief.useClaude"
        static let enabled = "brief.enabled"
        static let displayName = "brief.displayName"
    }

    private let defaults: UserDefaults

    /// Hour of the daily readout, 0...23.
    @Published var hour: Int = 7 {
        didSet { defaults.set(hour, forKey: Key.hour) }
    }

    @Published var minute: Int = 0 {
        didSet { defaults.set(minute, forKey: Key.minute) }
    }

    @Published var weekdaysOnly: Bool = true {
        didSet { defaults.set(weekdaysOnly, forKey: Key.weekdaysOnly) }
    }

    /// Keeps an audio session alive so the *whole* brief can be spoken at the set
    /// time with no interaction. Costs battery; survives backgrounding and lock,
    /// but not a force-quit or a reboot.
    @Published var handsFree: Bool = false {
        didSet { defaults.set(handsFree, forKey: Key.handsFree) }
    }

    /// BCP-47 tag of the language the brief is read in, e.g. `en-GB`.
    /// Nil means let `BriefNarrator` resolve it — see `narrationLanguage()`.
    @Published var voiceLanguage: String? {
        didSet {
            if let voiceLanguage {
                defaults.set(voiceLanguage, forKey: Key.voiceLanguage)
            } else {
                defaults.removeObject(forKey: Key.voiceLanguage)
            }
        }
    }

    @Published var voiceIdentifier: String? {
        didSet {
            if let voiceIdentifier {
                defaults.set(voiceIdentifier, forKey: Key.voiceIdentifier)
            } else {
                defaults.removeObject(forKey: Key.voiceIdentifier)
            }
        }
    }

    @Published var speechRate: Double = 0.5 {
        didSet { defaults.set(speechRate, forKey: Key.speechRate) }
    }

    /// When on (and an API key is stored), Claude rewrites the headline, the act
    /// sentences, and the item sentences. Off, the on-device writer does it and
    /// nothing leaves the phone.
    @Published var useClaude: Bool = false {
        didSet { defaults.set(useClaude, forKey: Key.useClaude) }
    }

    @Published var enabled: Bool = true {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    /// Optional first name, used in the headline the way a friend would.
    @Published var displayName: String = "" {
        didSet { defaults.set(displayName, forKey: Key.displayName) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hour: 7,
            Key.minute: 0,
            Key.weekdaysOnly: true,
            Key.handsFree: false,
            Key.speechRate: 0.5,
            Key.useClaude: false,
            Key.enabled: true,
            Key.displayName: "",
        ])
        hour = defaults.integer(forKey: Key.hour)
        minute = defaults.integer(forKey: Key.minute)
        weekdaysOnly = defaults.bool(forKey: Key.weekdaysOnly)
        handsFree = defaults.bool(forKey: Key.handsFree)
        voiceLanguage = defaults.string(forKey: Key.voiceLanguage)
        voiceIdentifier = defaults.string(forKey: Key.voiceIdentifier)
        speechRate = defaults.double(forKey: Key.speechRate)
        useClaude = defaults.bool(forKey: Key.useClaude)
        enabled = defaults.bool(forKey: Key.enabled)
        displayName = defaults.string(forKey: Key.displayName) ?? ""
    }

    /// The next moment the brief should be read out, respecting `weekdaysOnly`.
    func nextFireDate(after reference: Date = Date()) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let calendar = Calendar.current

        var candidate = calendar.nextDate(
            after: reference,
            matching: components,
            matchingPolicy: .nextTime
        )
        guard weekdaysOnly else { return candidate }

        // Walk forward past Saturday and Sunday.
        for _ in 0..<8 {
            guard let current = candidate else { return nil }
            let weekday = calendar.component(.weekday, from: current)
            if weekday != 1 && weekday != 7 { return current }
            candidate = calendar.nextDate(
                after: current,
                matching: components,
                matchingPolicy: .nextTime
            )
        }
        return candidate
    }
}

/// Minimal Keychain wrapper for the optional Claude API key.
enum KeychainStore {
    private static let service = "com.morningbrief.credentials"
    private static let account = "anthropic-api-key"

    static func saveAPIKey(_ key: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let key, !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func apiKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }
}
