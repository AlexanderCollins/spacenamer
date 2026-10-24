import Foundation

/// A small MCP server (JSON-RPC over stdio, one message per line) that lets any agent
/// show its progress on the desktop its terminal is on, name that desktop, or ask which
/// desktop it is. Each call becomes a report to the app.
public final class MCPServer {
    public typealias Send = (AgentReport) -> AgentReply?

    private let version: String
    private let processes: () -> [AgentProcess]
    private let send: Send

    public init(version: String, processes: @escaping () -> [AgentProcess], send: @escaping Send) {
        self.version = version
        self.processes = processes
        self.send = send
    }

    static let instructions = """
    SpaceNamer names macOS desktops (Spaces) and shows each coding agent's status on the \
    desktop its terminal is on: working, needs you, done or failed. With SpaceNamer's \
    Claude Code hooks those states are tracked automatically; use set_status for what \
    only you know: progress through a long, multi-step task (progress 0–1 and a short \
    note like "Tests 3/5"), or that a task failed. Use name_desktop only when the user \
    asks to name their desktop.
    """

    static let tools: [[String: Any]] = [
        [
            "name": "set_status",
            "description": "Show this session's status on the desktop its terminal is on. Use during long, multi-step work to report progress (0 to 1) and a short note, or to mark a task as failed.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "state": ["type": "string", "enum": ["working", "needs_input", "done", "failed", "idle"], "description": "Overall state. Omit to keep the current one."],
                    "progress": ["type": "number", "minimum": 0, "maximum": 1, "description": "How far through the task, from 0 to 1."],
                    "note": ["type": "string", "description": "A few words on what's happening, e.g. \"Tests 3/5\"."],
                ],
            ],
        ],
        [
            "name": "name_desktop",
            "description": "Name the macOS desktop this session's terminal is on. Only when the user asks for it.",
            "inputSchema": [
                "type": "object",
                "properties": ["name": ["type": "string", "description": "The new name; empty to clear it."]],
                "required": ["name"],
            ],
        ],
        [
            "name": "get_desktop",
            "description": "Which macOS desktop this session's terminal is on, and its name.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    /// Reads messages from stdin until it closes, answering on stdout.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(Data(line.utf8)) else { continue }
            FileHandle.standardOutput.write(response + Data([0x0A]))
        }
    }

    /// The response to one message, or nil for notifications.
    public func handle(_ message: Data) -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let method = request["method"] as? String
        else { return respond(id: NSNull(), error: (-32700, "Parse error")) }
        guard let id = request["id"] else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return respond(id: id, result: [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "spacenamer", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return respond(id: id, result: [:])
        case "tools/list":
            return respond(id: id, result: ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return respond(id: id, result: call(name, arguments))
        default:
            return respond(id: id, error: (-32601, "Method not found: \(method)"))
        }
    }

    private func call(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
        var report = AgentReport(event: .query, source: "mcp", processes: processes())
        switch tool {
        case "set_status":
            report.event = .status
            if let state = arguments["state"] as? String {
                guard let parsed = AgentState(rawValue: state) else { return text("Unknown state \"\(state)\".", error: true) }
                report.state = parsed
            }
            report.progress = (arguments["progress"] as? NSNumber)?.doubleValue
            report.note = arguments["note"] as? String
        case "name_desktop":
            report.event = .nameDesktop
            report.name = arguments["name"] as? String ?? ""
        case "get_desktop":
            break
        default:
            return text("Unknown tool \"\(tool)\".", error: true)
        }

        guard let reply = send(report) else { return text("SpaceNamer isn't running.", error: true) }
        if let error = reply.error { return text(error, error: true) }
        guard let desktop = reply.desktop else { return text("SpaceNamer doesn't know which desktop this terminal is on yet.", error: tool != "set_status") }
        let number = reply.desktopNumber.map { "desktop \($0)" } ?? "a desktop"
        switch tool {
        case "set_status": return text("Shown on \(number) (\(desktop)).")
        case "name_desktop": return text("Named \(number) \"\(desktop)\".")
        default: return text("This terminal is on \(number), \"\(desktop)\"\(reply.desktopNamed == true ? "" : " (not named yet)").")
        }
    }

    private func text(_ message: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": error]
    }

    private func respond(id: Any, result: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func respond(id: Any, error: (code: Int, message: String)) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
    }
}
