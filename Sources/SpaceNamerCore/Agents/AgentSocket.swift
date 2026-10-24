import Darwin
import Foundation

/// How agent integrations reach the app: a Unix socket in the user's Application Support
/// folder (so only the user can use it), one JSON report in and one JSON reply out per
/// connection.
public enum AgentSocket {
    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpaceNamer", isDirectory: true)
    }

    public static var path: String { folder.appendingPathComponent("agent.sock").path }

    // MARK: Client

    /// Sends a report and waits briefly for the reply. Nil when the app isn't running or
    /// doesn't answer in time; callers carry on regardless.
    public static func send(_ report: AgentReport, timeout: TimeInterval = 2) -> AgentReply? {
        guard let body = try? JSONEncoder().encode(report) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        setTimeout(fd, timeout)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard var address = address(), connect(fd, &address) else { return nil }
        guard writeAll(fd, body + Data([0x0A])) else { return nil }
        return readLine(fd).flatMap { try? JSONDecoder().decode(AgentReply.self, from: $0) }
    }

    // MARK: Server

    /// Listens for reports, answering each with `handle` (called on `queue`). Returns nil
    /// if the socket can't be set up, e.g. another copy of the app already listens.
    public final class Server {
        private let fd: Int32
        private let source: DispatchSourceRead
        private let workers: DispatchQueue

        public init?(queue: DispatchQueue, handle: @escaping (AgentReport) -> AgentReply) {
            try? FileManager.default.createDirectory(at: AgentSocket.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            unlink(AgentSocket.path)
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0, var address = AgentSocket.address() else { return nil }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(listener, 16) == 0 else {
                close(listener)
                return nil
            }
            chmod(AgentSocket.path, 0o600)
            _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
            fd = listener
            let workers = DispatchQueue(label: "SpaceNamer.AgentSocket", qos: .userInitiated, attributes: .concurrent)
            self.workers = workers
            source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: workers)
            source.setEventHandler {
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    workers.async { Server.serve(client, queue: queue, handle: handle) }
                }
            }
            source.setCancelHandler { close(listener) }
            source.resume()
        }

        deinit {
            source.cancel()
            unlink(AgentSocket.path)
        }

        private static func serve(_ client: Int32, queue: DispatchQueue, handle: @escaping (AgentReport) -> AgentReply) {
            defer { close(client) }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            AgentSocket.setTimeout(client, 2)
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            guard let line = AgentSocket.readLine(client),
                  let report = try? JSONDecoder().decode(AgentReport.self, from: line)
            else { return }
            let reply = queue.sync { handle(report) }
            if let body = try? JSONEncoder().encode(reply) {
                _ = AgentSocket.writeAll(client, body + Data([0x0A]))
            }
        }
    }

    // MARK: Plumbing

    private static func address() -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    private static func connect(_ fd: Int32, _ address: inout sockaddr_un) -> Bool {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    fileprivate static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    fileprivate static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Reads up to the first newline (or the end), at most 1 MB.
    fileprivate static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            if let newline = buffer.prefix(count).firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer.prefix(newline))
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.isEmpty ? nil : data
    }
}
