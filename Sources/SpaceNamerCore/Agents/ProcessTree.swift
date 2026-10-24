import Darwin

/// Reads a process's ancestry, to find the agent behind a report and the app its
/// terminal runs in.
public enum ProcessTree {
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "nu", "env", "nohup", "timeout", "time"]

    public static func isShell(_ name: String) -> Bool {
        shells.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    /// The parent and every ancestor of `pid`, nearest first, up to (not including) launchd.
    public static func ancestors(of pid: pid_t = getpid()) -> [AgentProcess] {
        var result: [AgentProcess] = []
        var current = pid
        while result.count < 64, let info = info(for: current) {
            let parent = info.kp_eproc.e_ppid
            guard parent > 1, let parentInfo = self.info(for: parent) else { break }
            result.append(AgentProcess(pid: parent, name: name(of: parentInfo)))
            current = parent
        }
        return result
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func info(for pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    private static func name(of info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
