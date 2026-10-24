import AppKit
import os
import SpaceNamerCore

/// Finds the window a process's terminal (its tty) is shown in, by asking the terminal
/// apps that can say: iTerm2 and Terminal list each tab's tty and window, and their window
/// IDs are the window server's, which say which desktop a window is on.
///
/// The answers are cached and refreshed in the background (macOS asks the user once
/// before SpaceNamer may ask a terminal app).
@MainActor
final class TerminalLocator {
    /// Called when a refresh changed what's known.
    var onChange: (() -> Void)?

    private var windowByTerminal: [String: CGWindowID] = [:]
    private var refreshedAt: Date?
    private var refreshing = false
    private static let maximumAge: TimeInterval = 10
    private let queue = DispatchQueue(label: "SpaceNamer.TerminalLocator", qos: .utility)
    private let log = Logger(subsystem: "com.alexandercollins.SpaceNamer", category: "agents")

    // The separator is set outside `tell`: inside it, `tab` means the terminal's tabs.
    private static let scripts: [String: String] = [
        "com.googlecode.iterm2": """
        set separator to character id 9
        tell application id "com.googlecode.iterm2"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (id of w) & separator & (tty of s) & linefeed
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """,
        "com.apple.Terminal": """
        set separator to character id 9
        tell application id "com.apple.Terminal"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (id of w) & separator & (tty of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """,
    ]

    /// The window showing `terminal` (e.g. "/dev/ttys001"), as last seen.
    func window(showing terminal: String) -> CGWindowID? {
        let known = windowByTerminal[terminal]
        if known == nil || refreshedAt.map({ Date().timeIntervalSince($0) > Self.maximumAge }) ?? true {
            refresh()
        }
        return known
    }

    func refresh() {
        guard !refreshing else { return }
        // Only ask apps that are running: asking would launch the others.
        let running = Self.scripts.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.key).isEmpty }
        guard !running.isEmpty else { return }
        refreshing = true
        queue.async {
            var found: [String: CGWindowID] = [:]
            for script in running.values {
                for line in (Self.run(script) ?? "").split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    guard parts.count == 2, let window = CGWindowID(parts[0]) else { continue }
                    found[String(parts[1])] = window
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshing = false
                    self.refreshedAt = Date()
                    self.log.debug("terminal windows: \(found.count) ttys")
                    guard found != self.windowByTerminal else { return }
                    self.windowByTerminal = found
                    self.onChange?()
                }
            }
        }
    }

    /// Runs AppleScript through osascript, so a slow or unanswered terminal can't hold up
    /// the app; nil if it fails (e.g. the user said no).
    nonisolated private static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Logger(subsystem: "com.alexandercollins.SpaceNamer", category: "agents").debug("osascript failed: \(process.terminationStatus)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
