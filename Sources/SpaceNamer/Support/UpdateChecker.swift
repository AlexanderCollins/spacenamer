import AppKit
import Combine
import SpaceNamerCore

/// Checks GitHub now and then for commits newer than the one this build was made from
/// (written into Info.plist by scripts/build-app.sh), and installs them by running the
/// usual `git pull && make install` in Terminal, in the folder the app was built from.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        /// This build's commit isn't on GitHub (made from local changes).
        case unpublished
        case failed
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date?

    var available: AvailableUpdate? {
        if case .available(let update) = status { return update }
        return nil
    }

    /// The commit this build was made from; nil for builds made outside the build script.
    let commit: String? = {
        #if DEBUG
        // Lets a development build pose as an older one, to try the update flow.
        if let commit = UserDefaults.standard.string(forKey: "UpdateCheckCommit") { return commit }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "SpaceNamerCommit") as? String
    }()
    /// The folder this build was made from, if it's still a checkout of the repository.
    var sourceFolder: URL? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "SpaceNamerSource") as? String else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let isCheckout = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("Makefile").path)
        return isCheckout ? folder : nil
    }

    var canCheck: Bool { commit.flatMap(UpdateCheck.request(since:)) != nil }

    private static let interval: TimeInterval = 6 * 60 * 60
    /// How many changes the menu and the update prompt list before "and N more".
    static let listedChanges = 3
    private let preferences: Preferences
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start() {
        preferences.$checkForUpdates
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    // Not straight away: launching at login is busy enough.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
                } else if available != nil {
                    status = .idle
                }
            }
            .store(in: &cancellables)

        // Hourly, so a Mac that slept through a check catches up soon after it wakes.
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        guard preferences.checkForUpdates else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        check()
    }

    func check() {
        guard task == nil, let request = commit.flatMap(UpdateCheck.request(since:)) else { return }
        if available == nil { status = .checking }
        task = Task { [weak self] in
            let result: Status
            do {
                let session = URLSession(configuration: .ephemeral)
                let (data, response) = try await session.data(for: request)
                switch (response as? HTTPURLResponse)?.statusCode {
                case 200:
                    result = try UpdateCheck.update(fromComparison: data).map(Status.available) ?? .upToDate
                case 404:
                    result = .unpublished
                default:
                    result = .failed
                }
            } catch {
                result = .failed
            }
            guard let self else { return }
            task = nil
            lastChecked = Date()
            // A failed check keeps an update already found.
            if result != .failed || available == nil { status = result }
        }
    }

    // MARK: Installing

    /// Asks first, then updates in Terminal; without the source folder, says how instead.
    func offerUpdate() {
        guard let update = available else { return }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        var lines = update.changes.prefix(Self.listedChanges).map { "• " + $0.summary }
        if update.changes.count > Self.listedChanges { lines.append("• and \(update.changes.count - Self.listedChanges) more") }
        let changes = lines.joined(separator: "\n")
        if let folder = sourceFolder {
            alert.messageText = "Update SpaceNamer?"
            alert.informativeText = "\(changes)\n\nTerminal will pull the latest changes into \(folder.path) and rebuild SpaceNamer, which takes a minute or two. SpaceNamer restarts when it's done."
            alert.addButton(withTitle: "Update")
        } else {
            alert.messageText = "A new version of SpaceNamer is available"
            alert.informativeText = "\(changes)\n\nTo update, run “git pull && make install” in your copy of SpaceNamer."
            alert.addButton(withTitle: "OK")
        }
        alert.addButton(withTitle: "View Changes")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let folder = sourceFolder { runUpdate(in: folder) }
        case .alertSecondButtonReturn:
            if let page = update.page { NSWorkspace.shared.open(page) }
        default:
            break
        }
    }

    private func runUpdate(in folder: URL) {
        let quoted = "'" + folder.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/zsh
        cd \(quoted) || exit 1
        echo "Updating SpaceNamer in $PWD"
        git pull --ff-only && make install
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Update SpaceNamer.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }
}
