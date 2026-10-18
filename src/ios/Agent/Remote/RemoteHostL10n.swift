import Foundation

/// The fork's strings live in their own table, `RemoteHost.xcstrings`, so upstream's `Localizable.xcstrings`
/// stays as upstream ships it. Read through `AppBundle.current`, like `AppLocalized`, so the in-app language
/// picker applies.
enum RemoteHostL10n {
    static let table = "RemoteHost"

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, table: table, bundle: AppBundle.current)
    }
}
