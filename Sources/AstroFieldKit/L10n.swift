import Foundation
import Observation
import os

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var title: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

// Background camera tasks read the bundle under the lock. Only the main actor changes it.
@Observable
public final class LanguageSettings: @unchecked Sendable {
    public static let shared = LanguageSettings()
    static let preferenceKey = "AstroFieldLanguage"

    private struct State: Sendable {
        let choice: AppLanguage
        let bundle: Bundle
        let locale: Locale
    }

    private let defaults: UserDefaults
    private let state: OSAllocatedUnfairLock<State>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let choice = defaults.string(forKey: Self.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        state = OSAllocatedUnfairLock(initialState: Self.resolve(choice, defaults: defaults))
    }

    private static func resolve(_ choice: AppLanguage, defaults: UserDefaults) -> State {
        let preferences = choice == .system
            ? defaults.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
            : [choice.rawValue]
        let bundle = L10n.languageBundle(for: preferences)
        let identifier = bundle.bundleURL.deletingPathExtension().lastPathComponent
        return State(choice: choice, bundle: bundle, locale: Locale(identifier: identifier))
    }

    public var choice: AppLanguage {
        access(keyPath: \.choice)
        return state.withLock { $0.choice }
    }

    public var locale: Locale {
        access(keyPath: \.choice)
        return state.withLock { $0.locale }
    }

    fileprivate var bundle: Bundle {
        access(keyPath: \.choice)
        return state.withLock { $0.bundle }
    }

    @MainActor
    public func select(_ choice: AppLanguage) {
        guard choice != self.choice else { return }
        let next = Self.resolve(choice, defaults: defaults)
        withMutation(keyPath: \.choice) {
            state.withLock { $0 = next }
            defaults.set(choice.rawValue, forKey: Self.preferenceKey)
        }
    }
}

/// Both the view models and the camera backends produce text for the monitor.
public enum L10n {
    static func languageBundle(for preferences: [String]) -> Bundle {
        // The standalone app carries translations in Contents/Resources.
        // SwiftPM executables and tests load them from the module bundle.
        let main = Bundle.main
        let resources = main.url(forResource: "AstroField", withExtension: "strings",
                                 subdirectory: nil, localization: "en") == nil ? Bundle.module : main
        let available = ["zh-Hans", "en"]
        let language = Bundle.preferredLocalizations(from: available, forPreferences: preferences).first
            ?? "zh-Hans"
        let directory = resources.localizations.first { $0.lowercased() == language.lowercased() }
            ?? language
        guard let url = resources.url(forResource: directory, withExtension: "lproj"),
              let localized = Bundle(url: url) else { return resources }
        return localized
    }

    public static func text(_ key: String) -> String {
        LanguageSettings.shared.bundle.localizedString(forKey: key, value: key, table: "AstroField")
    }

    public static func text(_ key: String, _ first: Any, _ rest: Any...) -> String {
        let values = ([first] + rest).map { value in
            if let error = value as? LocalizedError, let message = error.errorDescription {
                return message
            }
            return String(describing: value)
        }
        return String(format: text(key), arguments: values)
    }
}
