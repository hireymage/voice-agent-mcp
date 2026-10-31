import Foundation

/// The language of the app. System follows the phone; the others are the setting in the app.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, english = "en", czech = "cs"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: tr("System language")
        case .english: "English"
        case .czech: "Čeština"
        }
    }
}

enum Localizer {
    private static let available = ["en", "cs"]
    private static let lock = NSLock()
    private static var language = AppLanguage.system

    static func use(_ new: AppLanguage) { lock.withLock { language = new } }

    /// Also what iOS itself uses for this app from the next launch: permission prompts and system buttons.
    static func remember(_ new: AppLanguage) {
        use(new)
        if new == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([new.rawValue], forKey: "AppleLanguages")
        }
    }

    /// The language the screens are in.
    static var code: String {
        let current = lock.withLock { language }
        if current != .system { return current.rawValue }
        let preferred = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: available, forPreferences: preferred).first ?? "en"
    }

    /// The language the user is expected to speak, for the phone's own speech services and for the greeting.
    static var speechLanguage: String {
        switch lock.withLock({ language }) {
        case .system: Locale.preferredLanguages.first ?? "en-US"
        case .english: "en-US"
        case .czech: "cs-CZ"
        }
    }

    /// The speech language by its English name, for text sent to the model.
    static var speechLanguageName: String {
        let code = Locale(identifier: speechLanguage).language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    static var bundle: Bundle {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

/// A text in the language of the app. The key is the English text.
func tr(_ key: String) -> String {
    Localizer.bundle.localizedString(forKey: key, value: key, table: nil)
}

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: tr(key), arguments: arguments)
}
