// Mac Android Subsystem - Mac keyboard to Android key events.
//
// Text comes from AppKit's text input (AndroidDisplayView), so every Mac keyboard
// layout, dead key and input method works. Everything else (arrows, Return, Delete,
// shortcuts with Control) is sent as an Android keycode with its meta state.
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import Carbon.HIToolbox

enum AndroidKeys {
    // android.view.KeyEvent codes
    static let back: Int32 = 4
    static let home: Int32 = 3
    static let appSwitch: Int32 = 187
    static let enter: Int32 = 66
    static let delete: Int32 = 67

    // android.view.KeyEvent meta flags
    static let metaShift: Int32 = 0x1
    static let metaAlt: Int32 = 0x2
    static let metaCtrl: Int32 = 0x1000
    static let metaMeta: Int32 = 0x10000
    static let metaCapsLock: Int32 = 0x100000

    /// macOS virtual key code -> Android keycode.
    static let keycodes: [Int: Int32] = {
        var map: [Int: Int32] = [
            kVK_Return: 66, kVK_ANSI_KeypadEnter: 160, kVK_Tab: 61, kVK_Space: 62, kVK_Delete: 67,
            kVK_ForwardDelete: 112, kVK_Escape: 111,
            kVK_LeftArrow: 21, kVK_RightArrow: 22, kVK_UpArrow: 19, kVK_DownArrow: 20,
            kVK_Home: 122, kVK_End: 123, kVK_PageUp: 92, kVK_PageDown: 93,
            kVK_ANSI_Comma: 55, kVK_ANSI_Period: 56, kVK_ANSI_Grave: 68, kVK_ANSI_Minus: 69,
            kVK_ANSI_Equal: 70, kVK_ANSI_LeftBracket: 71, kVK_ANSI_RightBracket: 72,
            kVK_ANSI_Backslash: 73, kVK_ANSI_Semicolon: 74, kVK_ANSI_Quote: 75, kVK_ANSI_Slash: 76,
            kVK_F1: 131, kVK_F2: 132, kVK_F3: 133, kVK_F4: 134, kVK_F5: 135, kVK_F6: 136,
            kVK_F7: 137, kVK_F8: 138, kVK_F9: 139, kVK_F10: 140, kVK_F11: 141, kVK_F12: 142,
            kVK_VolumeUp: 24, kVK_VolumeDown: 25, kVK_Mute: 164,
        ]
        let letters: [(Int, Character)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
        ]
        for (code, letter) in letters {
            map[code] = Int32(29 + Int(letter.asciiValue! - Character("A").asciiValue!)) // KEYCODE_A = 29
        }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (value, code) in digits.enumerated() {
            map[code] = Int32(7 + value) // KEYCODE_0 = 7
        }
        return map
    }()

    static func metaState(_ flags: NSEvent.ModifierFlags) -> Int32 {
        var meta: Int32 = 0
        if flags.contains(.shift) { meta |= metaShift }
        if flags.contains(.option) { meta |= metaAlt }
        if flags.contains(.control) { meta |= metaCtrl }
        if flags.contains(.capsLock) { meta |= metaCapsLock }
        return meta
    }
}
