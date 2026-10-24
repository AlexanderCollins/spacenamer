import AppKit
import SpaceNamerCore

enum Badges {
    /// A rounded number badge as a template image, so it tints with the menu bar.
    /// Filled with the number knocked out when `filled`, outlined otherwise.
    static func number(_ text: String, filled: Bool, height: CGFloat = 16, fontSize: CGFloat = 11) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = max(height, ceil(textSize.width) + 8)
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.75, dy: 0.75)
            let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
            let textRect = NSRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2 + 0.5,
                width: textSize.width,
                height: textSize.height
            )
            NSColor.black.set()
            if filled {
                path.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                (text as NSString).draw(in: textRect, withAttributes: attributes)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                path.lineWidth = 1.25
                path.stroke()
                (text as NSString).draw(in: textRect, withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func fullscreen(height: CGFloat = 16) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: height - 4, weight: .semibold)
        let image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Full screen")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }

    static func badge(for space: Space, filled: Bool) -> NSImage {
        if let position = space.position { return number(String(position), filled: filled) }
        return fullscreen()
    }

    /// The green mark for an available update, in full colour (not a template).
    static func update(pointSize: CGFloat = 12) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemGreen]))
        return NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Update available")?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }
}

extension HotKey {
    /// The key-equivalent string a menu item needs to display this shortcut.
    var menuKeyEquivalent: String? {
        func special(_ value: Int) -> String { String(Character(UnicodeScalar(UInt16(value))!)) }
        switch Int(keyCode) {
        case 0x31: return " "
        case 0x24: return "\r"
        case 0x30: return "\t"
        case 0x33: return special(NSBackspaceCharacter)
        case 0x75: return special(NSDeleteFunctionKey)
        case 0x7B: return special(NSLeftArrowFunctionKey)
        case 0x7C: return special(NSRightArrowFunctionKey)
        case 0x7E: return special(NSUpArrowFunctionKey)
        case 0x7D: return special(NSDownArrowFunctionKey)
        default:
            let name = keyName
            if name.count == 1 { return name.lowercased() }
            if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...20).contains(number) {
                return special(NSF1FunctionKey + number - 1)
            }
            return nil
        }
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: cocoaModifiers)
    }
}

extension NSMenuItem {
    func showShortcut(_ hotKey: HotKey?) {
        guard let hotKey, let equivalent = hotKey.menuKeyEquivalent else { return }
        keyEquivalent = equivalent
        keyEquivalentModifierMask = hotKey.menuModifierMask
    }
}
