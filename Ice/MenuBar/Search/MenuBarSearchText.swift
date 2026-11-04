//
//  MenuBarSearchText.swift
//  Ice
//

import Foundation

/// The forms of a piece of text that the search panel matches.
///
/// The fuzzy matcher compares characters as they are, apart from case, so
/// "cafe" missed "Café", full-width "ｓｌａｃｋ" typed with a Japanese input
/// method missed "Slack", and an item named in another script could only be
/// found by typing that script. Each text is matched in two forms:
///
/// - the text with accents and character width ignored (the matcher already
///   ignores case, and keeps it for its bonus at each capital letter);
/// - for text in another script, such as Chinese, Japanese, Korean, Cyrillic,
///   Greek or Thai, its Latin transliteration, so "weixin" finds 微信,
///   "kakaotog" finds 카카오톡, and a query in hiragana finds an item written
///   in katakana.
enum MenuBarSearchText {
    private static let foldingOptions: String.CompareOptions = [
        .diacriticInsensitive,
        .widthInsensitive,
    ]

    /// Returns the forms of the given text to match, without duplicates.
    static func forms(of text: String) -> [String] {
        let folded = fold(text)
        guard
            !folded.unicodeScalars.allSatisfy(\.isASCII),
            let latin = text.applyingTransform(.toLatin, reverse: false).map(fold),
            latin != folded,
            !latin.isEmpty
        else {
            return [folded]
        }
        return [folded, latin]
    }

    /// Returns the text with accents and character width ignored.
    private static func fold(_ text: String) -> String {
        text.folding(options: foldingOptions, locale: nil)
    }
}

// MARK: - MenuBarSearchText.Cache

extension MenuBarSearchText {
    /// A cache of the forms of the item names in the search panel.
    ///
    /// A transliteration takes a moment, and the names are matched again on
    /// every keystroke.
    @MainActor
    final class Cache {
        private var forms = [String: [String]]()

        /// Returns the forms of the given text, from the cache if possible.
        func forms(of text: String) -> [String] {
            if let cached = forms[text] {
                return cached
            }
            let computed = MenuBarSearchText.forms(of: text)
            forms[text] = computed
            return computed
        }

        /// Removes the forms of every text not in the given set.
        func removeEntries(notIn texts: Set<String>) {
            forms = forms.filter { texts.contains($0.key) }
        }
    }
}
