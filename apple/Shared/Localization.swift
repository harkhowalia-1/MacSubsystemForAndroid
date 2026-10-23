// Mac Android Subsystem - localized strings for text held in String values.
// SwiftUI string literals localize themselves; model, status, notice and AppKit
// strings go through here so the English text is the lookup key.
// Licensed under the GNU General Public License v3 or later.

import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: String...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments.map { $0 as CVarArg })
    }
}
