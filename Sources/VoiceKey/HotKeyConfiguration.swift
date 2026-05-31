import AppKit
import Carbon

struct HotKeyConfiguration {
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

    init?(
        keyCode: UInt32,
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard !Self.modifierOnlyKeyCodes.contains(keyCode) else { return nil }

        let menuModifierMask = modifierFlags.intersection([.command, .option, .shift, .control])
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
