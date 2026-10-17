import AppKit

/// Deep links into System Settings.
enum SystemSettings {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openKeyboardShortcuts() {
        open("x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
