import Foundation
import SpaceNamerCore

// `spacenamer`, the command-line helper inside SpaceNamer.app (Contents/Helpers), used by
// the Claude Code plugin's hooks, as an MCP server, and from scripts. It never fails a
// hook: if the app isn't running, it quietly does nothing.

let usage = """
usage: spacenamer <command>

  status <working|needs_input|done|failed|idle> [--progress 0-1] [--note text]
                 show a status on the desktop this terminal is on
  name <name>    name the desktop this terminal is on ("" to clear it)
  desktop        print which desktop this terminal is on
  mcp            run the MCP server (stdio)
  hook           handle a Claude Code hook (reads its JSON on stdin)

"""

/// The app's version, from the Info.plist two folders up (Contents/Helpers/spacenamer).
var version: String {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let info = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    let plist = NSDictionary(contentsOf: info)
    return plist?["CFBundleShortVersionString"] as? String ?? "dev"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ reply: AgentReply?) -> String {
    guard let reply else { fail("SpaceNamer isn't running.") }
    if let error = reply.error { fail(error) }
    guard let desktop = reply.desktop else { fail("SpaceNamer doesn't know which desktop this terminal is on yet.") }
    return reply.desktopNumber.map { "Desktop \($0): \(desktop)" } ?? desktop
}

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "help" : arguments.removeFirst()

switch command {
case "hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let hook = try? JSONDecoder().decode(ClaudeHook.Input.self, from: input),
          let report = ClaudeHook.report(for: hook, processes: ProcessTree.ancestors())
    else { exit(0) }
    let reply = AgentSocket.send(report, timeout: hook.hookEventName == "SessionStart" ? 1.5 : 2)
    if let output = ClaudeHook.output(for: hook, reply: reply) {
        FileHandle.standardOutput.write(output)
    }

case "mcp":
    MCPServer(version: version, processes: { ProcessTree.ancestors() }, send: { AgentSocket.send($0) }).run()

case "status":
    guard let raw = arguments.first, let state = AgentState(rawValue: raw.replacingOccurrences(of: "-", with: "_")) else {
        fail("Say which status: working, needs_input, done, failed or idle.")
    }
    var report = AgentReport(event: .status, source: "cli", processes: ProcessTree.ancestors(), state: state)
    var rest = arguments.dropFirst()
    while let option = rest.popFirst() {
        switch option {
        case "--progress":
            guard let value = rest.popFirst().flatMap(Double.init) else { fail("--progress takes a number from 0 to 1.") }
            report.progress = value
        case "--note":
            guard let value = rest.popFirst() else { fail("--note takes some text.") }
            report.note = value
        default:
            fail("Unknown option \(option).")
        }
    }
    print(describe(AgentSocket.send(report)))

case "name":
    guard arguments.count == 1 else { fail("usage: spacenamer name <name>") }
    let report = AgentReport(event: .nameDesktop, source: "cli", processes: ProcessTree.ancestors(), name: arguments[0])
    print(describe(AgentSocket.send(report)))

case "desktop":
    print(describe(AgentSocket.send(AgentReport(event: .query, source: "cli", processes: ProcessTree.ancestors()))))

case "help", "-h", "--help":
    print(usage, terminator: "")

default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
