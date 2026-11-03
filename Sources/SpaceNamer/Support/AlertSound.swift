import AudioToolbox
import Foundation

/// The alert sounds macOS offers (and any the user has added), by name. They play as sound
/// effects do: at the alert volume, through the output chosen for sound effects.
@MainActor
enum AlertSound {
    static let defaultName = "Glass"

    private static let folders = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true),
        URL(fileURLWithPath: "/Library/Sounds", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
    ]
    private static let kinds: Set<String> = ["aiff", "aif", "caf", "wav", "m4a", "mp3"]
    private static var loaded: [String: SystemSoundID] = [:]

    /// Every sound there is, by name, sorted.
    static var names: [String] {
        Set(files.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func play(_ name: String) {
        if let id = loaded[name] {
            AudioServicesPlaySystemSound(id)
            return
        }
        guard let url = files[name] ?? files[defaultName] else { return }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return }
        loaded[name] = id
        AudioServicesPlaySystemSound(id)
    }

    /// The first of each name, the user's own over the system's.
    private static var files: [String: URL] {
        var found: [String: URL] = [:]
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in urls where kinds.contains(url.pathExtension.lowercased()) {
                let name = url.deletingPathExtension().lastPathComponent
                if found[name] == nil { found[name] = url }
            }
        }
        return found
    }
}
