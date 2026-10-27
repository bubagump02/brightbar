import Foundation

/// Looks `key` up in the app's Localizable.strings and fills in the format
/// arguments. The English text is the key, so a missing translation falls back
/// to English. SwiftUI views with a literal (`Text("Retry")`) are localized by
/// SwiftUI itself; use this for strings built in code.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
