import Foundation

/// The interface's text. English is written here and is also the key; the system picks the
/// translation for the reader's language from the app's Localizable.strings (only zh-Hans so far),
/// and English where there is none (ADR 0006, 丁).
func L(_ english: String) -> String {
    NSLocalizedString(english, comment: "")
}

/// The same, with values put in: `%@` for text, `%ld` for a number (`%1$@`, `%2$ld` where a
/// translation puts them in another order).
func L(_ english: String, _ values: CVarArg...) -> String {
    String(format: NSLocalizedString(english, comment: ""), arguments: values)
}
