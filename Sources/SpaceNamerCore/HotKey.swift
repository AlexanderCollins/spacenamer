import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut, stored as a virtual key code plus Carbon modifiers so it
/// maps directly onto `RegisterEventHotKey` and stays put across keyboard layouts.
public struct HotKey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & Self.carbonModifierMask
    }

    public init(keyCode: UInt16, cocoaModifiers: UInt) {
        self.init(keyCode: UInt32(keyCode), carbonModifiers: Self.carbonModifiers(fromCocoa: cocoaModifiers))
    }

    public static let carbonModifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    // NSEvent.ModifierFlags raw values, mirrored here so Core stays AppKit-free.
    public static let cocoaShift: UInt = 1 << 17
    public static let cocoaControl: UInt = 1 << 18
    public static let cocoaOption: UInt = 1 << 19
    public static let cocoaCommand: UInt = 1 << 20
    public static let cocoaModifierMask: UInt = cocoaShift | cocoaControl | cocoaOption | cocoaCommand

    public static func carbonModifiers(fromCocoa flags: UInt) -> UInt32 {
        var result: UInt32 = 0
        if flags & cocoaCommand != 0 { result |= UInt32(cmdKey) }
        if flags & cocoaOption != 0 { result |= UInt32(optionKey) }
        if flags & cocoaControl != 0 { result |= UInt32(controlKey) }
        if flags & cocoaShift != 0 { result |= UInt32(shiftKey) }
        return result
    }

    public var cocoaModifiers: UInt {
        var result: UInt = 0
        if carbonModifiers & UInt32(cmdKey) != 0 { result |= Self.cocoaCommand }
        if carbonModifiers & UInt32(optionKey) != 0 { result |= Self.cocoaOption }
        if carbonModifiers & UInt32(controlKey) != 0 { result |= Self.cocoaControl }
        if carbonModifiers & UInt32(shiftKey) != 0 { result |= Self.cocoaShift }
        return result
    }

    /// Modifiers in Apple's canonical order: ⌃ ⌥ ⇧ ⌘.
    public var modifierSymbols: String {
        Self.modifierSymbols(carbon: carbonModifiers)
    }

    public static func modifierSymbols(carbon: UInt32) -> String {
        var symbols = ""
        if carbon & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbon & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbon & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbon & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    public var keyName: String { Self.name(forKeyCode: keyCode) }

    public var displayString: String { modifierSymbols + keyName }

    public var isFunctionKey: Bool { Self.functionKeys[Int(keyCode)] != nil }

    /// Global shortcuts need ⌃, ⌥ or ⌘ so they don't swallow ordinary typing. F-keys may stand alone.
    public var isValidGlobalShortcut: Bool {
        let required = UInt32(cmdKey | optionKey | controlKey)
        return carbonModifiers & required != 0 || isFunctionKey
    }

    // MARK: Key names

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤", kVK_Help: "?⃝",
        kVK_ANSI_KeypadClear: "⌧", kVK_ANSI_KeypadDecimal: ".", kVK_ANSI_KeypadMultiply: "*",
        kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadDivide: "/", kVK_ANSI_KeypadMinus: "-",
        kVK_ANSI_KeypadEquals: "=", kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1",
        kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3", kVK_ANSI_Keypad4: "4",
        kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
        kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9",
    ]

    public static func name(forKeyCode keyCode: UInt32) -> String {
        let code = Int(keyCode)
        if let name = functionKeys[code] ?? specialKeys[code] { return name }
        if let character = layoutCharacter(forKeyCode: keyCode) { return character }
        return "Key \(keyCode)"
    }

    /// The character the current keyboard layout prints for a key, ignoring modifiers.
    private static func layoutCharacter(forKeyCode keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string.uppercased()
    }

    // MARK: Common keys

    /// Virtual key codes for the number row, 1 through 9 then 0.
    public static let numberRowKeyCodes: [UInt32] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
    ].map(UInt32.init)
}
