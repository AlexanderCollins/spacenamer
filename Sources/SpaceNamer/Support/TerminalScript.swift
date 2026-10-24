import AppKit

/// Runs a few shell commands in a new Terminal window, where the user can watch them (and
/// where their shell's PATH finds tools like `git` and `claude`).
enum TerminalScript {
    @discardableResult
    static func run(_ name: String, lines: [String]) -> Bool {
        let script = (["#!/bin/zsh -l"] + lines).joined(separator: "\n") + "\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
            return false
        }
    }

    /// `text` in single quotes, for the shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
