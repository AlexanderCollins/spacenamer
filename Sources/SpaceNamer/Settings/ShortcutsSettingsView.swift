import SpaceNamerCore
import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Global") {
                row("Open switcher", $preferences.switcherHotKey)
                row("Back to previous Space", $preferences.backHotKey)
                row("Next Space", $preferences.nextHotKey)
                row("Previous Space", $preferences.previousHotKey)
                row("Rename current Space", $preferences.renameHotKey)
            }

            Section {
                Toggle("Jump to Desktop 1–10 by number", isOn: $preferences.positionShortcutsEnabled)
                Picker("Modifier keys", selection: $preferences.positionModifiers) {
                    ForEach(Preferences.PositionModifiers.allCases) { modifiers in
                        Text("\(modifiers.symbols)1 … \(modifiers.symbols)0").tag(modifiers)
                    }
                }
                .disabled(!preferences.positionShortcutsEnabled)
            } header: {
                Text("Numbered")
            } footer: {
                Text("Numbers count desktops left to right across all displays, the same way Mission Control does. Full-screen apps aren't numbered. You can also give any Space its own shortcut in the Spaces tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Control SpaceNamer from scripts, Shortcuts, Raycast or Alfred:")
                    Group {
                        Text("open \"spacenamer://go/3\"")
                        Text("open \"spacenamer://go?name=Mail\"")
                        Text("open \"spacenamer://back\"  ·  next  ·  previous  ·  switcher")
                        Text("open \"spacenamer://rename?name=Writing\"")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            } header: {
                Text("Automation")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }

    private func row(_ title: String, _ binding: Binding<HotKey?>) -> some View {
        LabeledContent(title) {
            ShortcutRecorder(hotKey: binding, model: model)
        }
    }
}
