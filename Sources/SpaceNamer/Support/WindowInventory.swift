import AppKit
import SpaceNamerCore

/// Works out which apps have windows on which Space, so the switcher can show icons.
/// Window owners are readable without Screen Recording; titles are never touched.
@MainActor
final class WindowInventory {
    private let reader: SpaceReader
    private let queue = DispatchQueue(label: "SpaceNamer.WindowInventory", qos: .userInitiated)
    private var isRefreshing = false

    init(reader: SpaceReader) {
        self.reader = reader
    }

    /// Managed Space ID → regular apps with a window there, frontmost first.
    func refresh(completion: @escaping ([UInt64: [NSRunningApplication]]) -> Void) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let reader = reader
        queue.async {
            let pidsBySpace = Self.collect(using: reader)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRefreshing = false
                    completion(Self.resolve(pidsBySpace))
                }
            }
        }
    }

    nonisolated private static func collect(using reader: SpaceReader) -> [UInt64: [pid_t]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        let ownPID = getpid()
        var result: [UInt64: [pid_t]] = [:]

        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 64, bounds.height >= 64,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
            else { continue }

            // Windows pinned to every Space say nothing about any one of them.
            let spaces = reader.spaces(forWindow: number)
            guard spaces.count == 1, let space = spaces.first else { continue }
            if result[space, default: []].contains(pid) == false {
                result[space, default: []].append(pid)
            }
        }
        return result
    }

    private static func resolve(_ pidsBySpace: [UInt64: [pid_t]]) -> [UInt64: [NSRunningApplication]] {
        var cache: [pid_t: NSRunningApplication?] = [:]
        return pidsBySpace.mapValues { pids in
            pids.compactMap { pid in
                if let cached = cache[pid] { return cached }
                let app = NSRunningApplication(processIdentifier: pid).flatMap { $0.activationPolicy == .regular ? $0 : nil }
                cache[pid] = app
                return app
            }
        }
    }
}
