import SpaceNamerCore
import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchNeedsApproval = LaunchAtLogin.needsApproval
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                PermissionRow(model: model)
            }

            Section("Names") {
                Picker("Menu bar shows", selection: $preferences.menuBarStyle) {
                    ForEach(Preferences.MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Toggle("Show names in Mission Control", isOn: $preferences.showNamesInMissionControl)
                Toggle("Show the name when switching", isOn: $preferences.showSwitchHUD)
                Picker("Position", selection: $preferences.hudPosition) {
                    ForEach(Preferences.HUDPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .disabled(!preferences.showSwitchHUD)
            }

            Section {
                Picker("Switch using", selection: $preferences.switchMethod) {
                    Text("Instant").tag(SpaceNavigator.Method.instant)
                    Text("Mission Control shortcuts").tag(SpaceNavigator.Method.keyboard)
                }
                Toggle("Next and Previous wrap around", isOn: $preferences.wrapAround)
            } header: {
                Text("Switching")
            } footer: {
                Text(methodDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if launchNeedsApproval {
                    HStack {
                        Text("Approve SpaceNamer in Login Items to finish.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 470)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchNeedsApproval = LaunchAtLogin.needsApproval
        }
    }

    private var methodDescription: String {
        switch preferences.switchMethod {
        case .instant:
            return "Switches immediately with no slide animation, works with any number of Spaces and full-screen apps, and needs no system shortcuts."
        case .keyboard:
            return "Presses your Mission Control shortcuts (System Settings › Keyboard › Keyboard Shortcuts › Mission Control). Uses “Switch to Desktop N” where enabled, otherwise moves one Space at a time, with the usual animation."
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
        launchNeedsApproval = LaunchAtLogin.needsApproval
    }
}

private struct PermissionRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.hasAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(model.hasAccess ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.hasAccess ? "Switching is enabled" : "Allow SpaceNamer to switch Spaces")
                    .font(.headline)
                Text("To change Spaces, SpaceNamer sends the same swipe and keyboard events your trackpad and keyboard send, and to show names in Mission Control it reads where the Dock draws its labels. macOS gates both behind Accessibility access. SpaceNamer doesn't record your screen or your typing, and System Integrity Protection stays on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !model.hasAccess {
                Button("Open Settings…") {
                    EventSynth.requestAccess()
                    SystemSettings.openAccessibility()
                }
            }
        }
        .padding(.vertical, 4)
    }
}
