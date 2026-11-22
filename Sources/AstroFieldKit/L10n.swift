import Foundation

/// Both the view models and the camera backends produce text for the monitor.
public enum L10n {
    private static let bundle = languageBundle(for:
        UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
    )

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
        bundle.localizedString(forKey: key, value: key, table: "AstroField")
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
