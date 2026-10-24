import AppKit
import SpaceNamerCore
import SwiftUI

/// SpaceNamer's Claude Code plugin: its hooks and MCP server report each session to the app.
enum ClaudePlugin {
    static let id = "spacenamer@spacenamer"
    static let installCommands = [
        "claude plugin marketplace add AlexanderCollins/spacenamer",
        "claude plugin install spacenamer@spacenamer",
    ]

    static var isInstalled: Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any]
        else { return false }
        return plugins[id] != nil
    }

    static func install() {
        TerminalScript.run("Install SpaceNamer for Claude Code", lines: [
            "echo 'Installing the SpaceNamer plugin for Claude Code…'",
            installCommands.joined(separator: " && \\\n  "),
            "echo 'Done. Sessions already running pick it up after /reload-plugins.'",
        ])
    }

    static func remove() {
        TerminalScript.run("Remove SpaceNamer from Claude Code", lines: [
            "claude plugin uninstall spacenamer@spacenamer",
            "claude plugin marketplace remove spacenamer",
        ])
    }
}

struct AgentsSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var agents: AgentCenter
    @State private var pluginInstalled = ClaudePlugin.isInstalled

    private var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spacenamer").path
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show agents' status on their desktops", isOn: $preferences.showAgentStatus)
                Toggle("Name desktops after their agent's chat", isOn: $preferences.nameDesktopsFromChats)
                Toggle("Name new chats after their desktop", isOn: $preferences.nameChatsFromDesktops)
            } header: {
                Text("Desktops")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        ForEach([AgentState.working, .needsInput, .done, .failed], id: \.self) { state in
                            HStack(spacing: 4) {
                                Circle().fill(Color(nsColor: AgentStyle.color(state))).frame(width: 8, height: 8)
                                Text(state.title)
                            }
                        }
                    }
                    Text("A desktop shows its most urgent agent in Mission Control, the menu and the switcher, and the menu bar gets a dot when one needs you, failed or finished. Done and failed clear once you've been to that desktop. Names you give desktops are never replaced by a chat's.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: pluginInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension")
                        .font(.title2)
                        .foregroundStyle(pluginInstalled ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pluginInstalled ? "The SpaceNamer plugin is installed" : "Install the SpaceNamer plugin")
                            .font(.headline)
                        Text("Its hooks tell SpaceNamer when each session is working, needs you, is done or failed, and its MCP server lets Claude report progress. Installing runs the two `claude plugin` commands in Terminal; sessions already running pick it up after /reload-plugins.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(pluginInstalled ? "Remove…" : "Install…") {
                        pluginInstalled ? ClaudePlugin.remove() : ClaudePlugin.install()
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Claude Code")
            }

            Section {
                CommandRow(label: "MCP server", command: "\(helperPath) mcp")
                CommandRow(label: "From a script", command: "spacenamer status working --progress 0.5 --note \"Tests 3/5\"")
            } header: {
                Text("Other agents")
            } footer: {
                Text("Any agent that speaks MCP can run SpaceNamer's server (stdio). Scripts can run `spacenamer` (in SpaceNamer.app/Contents/Helpers) with status, name or desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !agents.sessions.isEmpty {
                Section("Running now") {
                    ForEach(agents.sessions.values.sorted { $0.updated > $1.updated }, id: \.pid) { session in
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: AgentStyle.color(session.state))).frame(width: 8, height: 8)
                            Text(session.chat?.title ?? Self.label(for: session.source))
                                .lineLimit(1)
                            Spacer()
                            Text(desktop(of: session))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .onAppear { pluginInstalled = ClaudePlugin.isInstalled }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pluginInstalled = ClaudePlugin.isInstalled
        }
    }

    private static func label(for source: String) -> String {
        switch source {
        case "claude-code": return "Claude Code"
        case "mcp": return "MCP agent"
        default: return "Script"
        }
    }

    private func desktop(of session: AgentSession) -> String {
        guard let key = session.space, let space = model.snapshot.space(forKey: key) else { return "Desktop unknown" }
        let title = model.title(for: space)
        return space.position.map { "\($0) · \(title)" } ?? title
    }
}

private struct CommandRow: View {
    let label: String
    let command: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}
