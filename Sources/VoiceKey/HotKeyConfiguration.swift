import AppKit
import Carbon

struct HotKeyConfiguration: Equatable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let menuKeyEquivalent: String
    let menuModifierMask: NSEvent.ModifierFlags
    let displayName: String
    let mainKeyDisplayName: String

    init(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        menuKeyEquivalent: String,
        menuModifierMask: NSEvent.ModifierFlags,
        displayName: String,
        mainKeyDisplayName: String
    ) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.menuKeyEquivalent = menuKeyEquivalent
        self.menuModifierMask = menuModifierMask
        self.displayName = displayName
        self.mainKeyDisplayName = mainKeyDisplayName
    }

    /// Carbon virtual key code → function-key number, for every F-key.
    /// Codes are not ordered (F16=106, F17=64, F18=79), so this table is
    /// the only trustworthy mapping.
    private static let functionKeyNumbersByKeyCode: [UInt32: Int] = [
        UInt32(kVK_F1): 1, UInt32(kVK_F2): 2, UInt32(kVK_F3): 3,
        UInt32(kVK_F4): 4, UInt32(kVK_F5): 5, UInt32(kVK_F6): 6,
        UInt32(kVK_F7): 7, UInt32(kVK_F8): 8, UInt32(kVK_F9): 9,
        UInt32(kVK_F10): 10, UInt32(kVK_F11): 11, UInt32(kVK_F12): 12,
        UInt32(kVK_F13): 13, UInt32(kVK_F14): 14, UInt32(kVK_F15): 15,
        UInt32(kVK_F16): 16, UInt32(kVK_F17): 17, UInt32(kVK_F18): 18,
        UInt32(kVK_F19): 19, UInt32(kVK_F20): 20
    ]

    /// Menu glyph derived from the key code — the value Carbon actually
    /// registers — rather than the persisted menuKeyEquivalent, which has
    /// carried stale glyphs (a legacy F16 profile stored the F18 character,
    /// so the menu displayed the wrong shortcut while the binding was
    /// correct; observed live 2026-07-24). Non-function keys fall back to
    /// the stored equivalent.
    var effectiveMenuKeyEquivalent: String {
        if let number = Self.functionKeyNumbersByKeyCode[keyCode],
           let scalar = UnicodeScalar(NSF1FunctionKey + (number - 1)) {
            return String(scalar)
        }
        return menuKeyEquivalent
    }

    /// Sort key for hotkey-ordered channel lists: function keys in numeric
    /// order first, other keys after (by display name), unassigned last.
    var sortRank: (Int, Int, String) {
        if let number = Self.functionKeyNumbersByKeyCode[keyCode] {
            return (0, number, displayName)
        }
        return (1, 0, displayName)
    }

    static let defaultVoiceToggle = HotKeyConfiguration(
        keyCode: UInt32(kVK_F16),
        carbonModifiers: 0,
        menuKeyEquivalent: String(UnicodeScalar(NSF16FunctionKey)!),
        menuModifierMask: [],
        displayName: "F16",
        mainKeyDisplayName: "F16"
    )

    static var voiceToggle: HotKeyConfiguration {
        loadVoiceToggle()
    }

    static func loadVoiceToggle(defaults: UserDefaults = .standard) -> HotKeyConfiguration {
        guard defaults.object(forKey: DefaultsKeys.keyCode) != nil else {
            return defaultVoiceToggle
        }

        let keyCode = UInt32(defaults.integer(forKey: DefaultsKeys.keyCode))
        let carbonModifiers = UInt32(defaults.integer(forKey: DefaultsKeys.carbonModifiers))
        let menuModifierRawValue = UInt(defaults.integer(forKey: DefaultsKeys.menuModifierMask))
        let menuKeyEquivalent = defaults.string(forKey: DefaultsKeys.menuKeyEquivalent) ?? ""
        let displayName = defaults.string(forKey: DefaultsKeys.displayName) ?? ""
        let mainKeyDisplayName = defaults.string(forKey: DefaultsKeys.mainKeyDisplayName) ?? ""

        guard !menuKeyEquivalent.isEmpty, !displayName.isEmpty, !mainKeyDisplayName.isEmpty else {
            return defaultVoiceToggle
        }

        return HotKeyConfiguration(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers,
            menuKeyEquivalent: menuKeyEquivalent,
            menuModifierMask: NSEvent.ModifierFlags(rawValue: menuModifierRawValue),
            displayName: displayName,
            mainKeyDisplayName: mainKeyDisplayName
        )
    }

    func saveAsVoiceToggle(defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: DefaultsKeys.keyCode)
        defaults.set(Int(carbonModifiers), forKey: DefaultsKeys.carbonModifiers)
        defaults.set(Int(menuModifierMask.rawValue), forKey: DefaultsKeys.menuModifierMask)
        defaults.set(menuKeyEquivalent, forKey: DefaultsKeys.menuKeyEquivalent)
        defaults.set(displayName, forKey: DefaultsKeys.displayName)
        defaults.set(mainKeyDisplayName, forKey: DefaultsKeys.mainKeyDisplayName)
    }

    func matches(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard UInt32(keyCode) == self.keyCode else { return false }
        return modifierFlags.intersection(Self.shortcutModifierFlags) == menuModifierMask
    }

    init?(
        keyCode: UInt32,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard !Self.modifierOnlyKeyCodes.contains(keyCode) else { return nil }

        let menuModifierMask = modifierFlags.intersection(Self.shortcutModifierFlags)
        let carbonModifiers = Self.carbonModifiers(from: menuModifierMask)
        let modifierDisplayName = Self.modifierDisplayName(from: menuModifierMask)

        let keyDescription = Self.keyDescription(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )

        guard let keyDescription else { return nil }

        self.init(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers,
            menuKeyEquivalent: keyDescription.menuKeyEquivalent,
            menuModifierMask: menuModifierMask,
            displayName: "\(modifierDisplayName)\(keyDescription.mainKeyDisplayName)",
            mainKeyDisplayName: keyDescription.mainKeyDisplayName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case carbonModifiers
        case menuKeyEquivalent
        case menuModifierMask
        case displayName
        case mainKeyDisplayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyCode: try container.decode(UInt32.self, forKey: .keyCode),
            carbonModifiers: try container.decode(UInt32.self, forKey: .carbonModifiers),
            menuKeyEquivalent: try container.decode(String.self, forKey: .menuKeyEquivalent),
            menuModifierMask: NSEvent.ModifierFlags(rawValue: try container.decode(UInt.self, forKey: .menuModifierMask)),
            displayName: try container.decode(String.self, forKey: .displayName),
            mainKeyDisplayName: try container.decode(String.self, forKey: .mainKeyDisplayName)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(carbonModifiers, forKey: .carbonModifiers)
        try container.encode(menuKeyEquivalent, forKey: .menuKeyEquivalent)
        try container.encode(menuModifierMask.rawValue, forKey: .menuModifierMask)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(mainKeyDisplayName, forKey: .mainKeyDisplayName)
    }

    var iconDisplayName: String {
        let modifier = iconModifierDisplayName
        guard let modifier else { return mainKeyDisplayName }
        return "\(modifier)\(mainKeyDisplayName)"
    }

    private var iconModifierDisplayName: String? {
        let candidates: [(NSEvent.ModifierFlags, String)] = [
            (.command, "⌘"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.control, "⌃")
        ]
        let active = candidates.filter { menuModifierMask.contains($0.0) }
        return active.count == 1 ? active[0].1 : nil
    }

    private static func keyDescription(
        keyCode: UInt32,
        charactersIgnoringModifiers: String?
    ) -> KeyDescription? {
        if let functionDescription = functionKeyDescription(keyCode: keyCode) {
            return functionDescription
        }

        if let specialDescription = specialKeyDescriptions[keyCode] {
            return specialDescription
        }

        let rawCharacters = charactersIgnoringModifiers ?? ""
        let trimmedCharacters = rawCharacters.trimmingCharacters(in: .newlines)
        guard let firstCharacter = trimmedCharacters.first else { return nil }

        let menuKeyEquivalent = String(firstCharacter).lowercased()
        let mainKeyDisplayName = String(firstCharacter).uppercased()
        return KeyDescription(
            menuKeyEquivalent: menuKeyEquivalent,
            mainKeyDisplayName: mainKeyDisplayName
        )
    }

    private static func functionKeyDescription(keyCode: UInt32) -> KeyDescription? {
        let functionKeys: [(Int, Int, UInt32)] = [
            (1, NSF1FunctionKey, UInt32(kVK_F1)),
            (2, NSF2FunctionKey, UInt32(kVK_F2)),
            (3, NSF3FunctionKey, UInt32(kVK_F3)),
            (4, NSF4FunctionKey, UInt32(kVK_F4)),
            (5, NSF5FunctionKey, UInt32(kVK_F5)),
            (6, NSF6FunctionKey, UInt32(kVK_F6)),
            (7, NSF7FunctionKey, UInt32(kVK_F7)),
            (8, NSF8FunctionKey, UInt32(kVK_F8)),
            (9, NSF9FunctionKey, UInt32(kVK_F9)),
            (10, NSF10FunctionKey, UInt32(kVK_F10)),
            (11, NSF11FunctionKey, UInt32(kVK_F11)),
            (12, NSF12FunctionKey, UInt32(kVK_F12)),
            (13, NSF13FunctionKey, UInt32(kVK_F13)),
            (14, NSF14FunctionKey, UInt32(kVK_F14)),
            (15, NSF15FunctionKey, UInt32(kVK_F15)),
            (16, NSF16FunctionKey, UInt32(kVK_F16)),
            (17, NSF17FunctionKey, UInt32(kVK_F17)),
            (18, NSF18FunctionKey, UInt32(kVK_F18)),
            (19, NSF19FunctionKey, UInt32(kVK_F19)),
            (20, NSF20FunctionKey, UInt32(kVK_F20))
        ]

        guard let match = functionKeys.first(where: { $0.2 == keyCode }) else {
            return nil
        }

        return KeyDescription(
            menuKeyEquivalent: String(UnicodeScalar(match.1)!),
            mainKeyDisplayName: "F\(match.0)"
        )
    }

    private static let specialKeyDescriptions: [UInt32: KeyDescription] = [
        UInt32(kVK_Escape): KeyDescription(
            menuKeyEquivalent: "\u{1B}",
            mainKeyDisplayName: "Esc"
        ),
        UInt32(kVK_Return): KeyDescription(
            menuKeyEquivalent: "\r",
            mainKeyDisplayName: "↵"
        ),
        UInt32(kVK_Space): KeyDescription(
            menuKeyEquivalent: " ",
            mainKeyDisplayName: "Space"
        ),
        UInt32(kVK_Delete): KeyDescription(
            menuKeyEquivalent: String(UnicodeScalar(NSDeleteFunctionKey)!),
            mainKeyDisplayName: "Del"
        ),
        UInt32(kVK_Tab): KeyDescription(
            menuKeyEquivalent: "\t",
            mainKeyDisplayName: "Tab"
        )
    ]

    private static let modifierOnlyKeyCodes: Set<UInt32> = [
        UInt32(kVK_Command),
        UInt32(kVK_RightCommand),
        UInt32(kVK_Shift),
        UInt32(kVK_RightShift),
        UInt32(kVK_Option),
        UInt32(kVK_RightOption),
        UInt32(kVK_Control),
        UInt32(kVK_RightControl),
        UInt32(kVK_Function)
    ]

    private static func carbonModifiers(from modifierFlags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if modifierFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if modifierFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if modifierFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        return modifiers
    }

    private static func modifierDisplayName(from modifierFlags: NSEvent.ModifierFlags) -> String {
        var displayName = ""
        if modifierFlags.contains(.control) {
            displayName += "⌃"
        }
        if modifierFlags.contains(.option) {
            displayName += "⌥"
        }
        if modifierFlags.contains(.shift) {
            displayName += "⇧"
        }
        if modifierFlags.contains(.command) {
            displayName += "⌘"
        }
        return displayName
    }

    private static let shortcutModifierFlags: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
}

private enum DefaultsKeys {
    static let keyCode = "VoiceHotKey.keyCode"
    static let carbonModifiers = "VoiceHotKey.carbonModifiers"
    static let menuKeyEquivalent = "VoiceHotKey.menuKeyEquivalent"
    static let menuModifierMask = "VoiceHotKey.menuModifierMask"
    static let displayName = "VoiceHotKey.displayName"
    static let mainKeyDisplayName = "VoiceHotKey.mainKeyDisplayName"
}

private struct KeyDescription {
    let menuKeyEquivalent: String
    let mainKeyDisplayName: String
}
