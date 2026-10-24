import Foundation

/// What the user attached to a Space.
public struct SpaceRecord: Codable, Equatable, Sendable {
    public var name: String?
    /// The name came from an agent's chat rather than the user, so a newer chat may
    /// replace it.
    public var nameIsAutomatic: Bool?
    public var hotKey: HotKey?
    /// Display the Space was last seen on. Lets us tell a closed Space apart from one
    /// that is only hidden because its display is disconnected.
    public var displayID: String
    public var lastSeen: Date

    public init(name: String? = nil, hotKey: HotKey? = nil, displayID: String, lastSeen: Date) {
        self.name = name
        self.hotKey = hotKey
        self.displayID = displayID
        self.lastSeen = lastSeen
    }

    var isEmpty: Bool { name == nil && hotKey == nil }
}

public protocol RecordPersistence {
    func load() -> Data?
    func save(_ data: Data)
}

public struct UserDefaultsPersistence: RecordPersistence {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "SpaceRecords.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> Data? { defaults.data(forKey: key) }
    public func save(_ data: Data) { defaults.set(data, forKey: key) }
}

/// Names and per-Space shortcuts, keyed by Space UUID so they follow a Space when it is
/// reordered (by hand or by "Automatically rearrange Spaces"), and survive reboots.
///
/// `reconcile(with:)` keeps the store in step with what the window server reports:
/// - a Space that disappears while its display is still connected was closed, so its
///   record is dropped once the absence has lasted `removalGracePeriod`;
/// - a Space whose display is disconnected keeps its record, and gets it back when the
///   display returns. Such orphans are dropped after `orphanRetention`.
public final class NameStore {
    public static let maximumNameLength = 64
    public static let removalGracePeriod: TimeInterval = 6
    public static let reconfigurationQuietPeriod: TimeInterval = 12
    public static let orphanRetention: TimeInterval = 180 * 24 * 60 * 60
    private static let lastSeenRefreshInterval: TimeInterval = 24 * 60 * 60

    public private(set) var records: [SpaceKey: SpaceRecord]
    public var onChange: (() -> Void)?

    private let persistence: RecordPersistence
    private let now: () -> Date
    private var firstMissed: [SpaceKey: Date] = [:]
    private var lastReconfiguration = Date.distantPast

    public init(persistence: RecordPersistence = UserDefaultsPersistence(), now: @escaping () -> Date = Date.init) {
        self.persistence = persistence
        self.now = now
        if let data = persistence.load(), let decoded = try? JSONDecoder().decode([SpaceKey: SpaceRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    // MARK: Reading

    public func name(for key: SpaceKey) -> String? { records[key]?.name }

    /// The Space has a name the user gave it (not one taken from an agent's chat).
    public func hasUserName(_ key: SpaceKey) -> Bool {
        records[key]?.name != nil && records[key]?.nameIsAutomatic != true
    }

    public func hotKey(for key: SpaceKey) -> HotKey? { records[key]?.hotKey }

    public func displayName(for space: Space) -> String {
        name(for: space.key) ?? space.systemName
    }

    /// Records for Spaces on displays that are not connected right now.
    public func orphanedRecords(in snapshot: SpacesSnapshot) -> [(key: SpaceKey, record: SpaceRecord)] {
        let present = Set(snapshot.allSpaces.map(\.key))
        return records
            .filter { !present.contains($0.key) }
            .map { (key: $0.key, record: $0.value) }
            .sorted { ($0.record.name ?? "") < ($1.record.name ?? "") }
    }

    // MARK: Writing

    public static func normalizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let singleLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = singleLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumNameLength))
    }

    /// Sets or clears a name. Passing nil, an empty string, or the system name resets it.
    /// `automatic` names (from an agent's chat) give way to the next chat's; the user's don't.
    public func setName(_ raw: String?, for space: Space, automatic: Bool = false) {
        var name = Self.normalizedName(raw)
        if name == space.systemName { name = nil }
        update(space) { record in
            record.name = name
            record.nameIsAutomatic = name != nil && automatic ? true : nil
        }
    }

    public func setHotKey(_ hotKey: HotKey?, for space: Space) {
        if let hotKey {
            // A shortcut can only belong to one Space.
            for (key, record) in records where key != space.key && record.hotKey == hotKey {
                records[key]?.hotKey = nil
                if records[key]?.isEmpty == true { records[key] = nil }
            }
        }
        update(space) { $0.hotKey = hotKey }
    }

    public func forget(_ key: SpaceKey) {
        guard records.removeValue(forKey: key) != nil else { return }
        firstMissed[key] = nil
        commit()
    }

    public func forgetAll() {
        guard !records.isEmpty else { return }
        records.removeAll()
        firstMissed.removeAll()
        commit()
    }

    /// Call when displays are added, removed or rearranged. Absences seen shortly after are
    /// ignored, because the window server briefly reshuffles Spaces while it settles.
    public func noteDisplayReconfiguration() {
        lastReconfiguration = now()
        firstMissed.removeAll()
    }

    // MARK: Reconciling

    /// Brings records in line with the live layout. Returns the keys that were dropped
    /// because their Space was closed.
    @discardableResult
    public func reconcile(with snapshot: SpacesSnapshot) -> Set<SpaceKey> {
        // An empty layout means the window server is unavailable or mid-restart; trust nothing.
        guard !snapshot.isEmpty else { return [] }

        let date = now()
        let present = Dictionary(snapshot.allSpaces.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let connectedDisplays = Set(snapshot.displays.filter { !$0.spaces.isEmpty }.map(\.id))
        let settled = date.timeIntervalSince(lastReconfiguration) >= Self.reconfigurationQuietPeriod
        var removed = Set<SpaceKey>()
        var changed = false

        for (key, record) in records {
            if let space = present[key] {
                firstMissed[key] = nil
                if record.displayID != space.displayID || date.timeIntervalSince(record.lastSeen) >= Self.lastSeenRefreshInterval {
                    records[key]?.displayID = space.displayID
                    records[key]?.lastSeen = date
                    changed = true
                }
            } else if connectedDisplays.contains(record.displayID) {
                guard settled else {
                    firstMissed[key] = nil
                    continue
                }
                let since = firstMissed[key] ?? date
                firstMissed[key] = since
                if date.timeIntervalSince(since) >= Self.removalGracePeriod {
                    records[key] = nil
                    firstMissed[key] = nil
                    removed.insert(key)
                    changed = true
                }
            } else {
                firstMissed[key] = nil
                if date.timeIntervalSince(record.lastSeen) >= Self.orphanRetention {
                    records[key] = nil
                    removed.insert(key)
                    changed = true
                }
            }
        }

        if changed { commit() }
        return removed
    }

    // MARK: Private

    private func update(_ space: Space, _ change: (inout SpaceRecord) -> Void) {
        var record = records[space.key] ?? SpaceRecord(displayID: space.displayID, lastSeen: now())
        let before = records[space.key]
        change(&record)
        record.displayID = space.displayID
        record.lastSeen = now()
        let after: SpaceRecord? = record.isEmpty ? nil : record
        guard after?.name != before?.name || after?.nameIsAutomatic != before?.nameIsAutomatic
            || after?.hotKey != before?.hotKey || (after == nil) != (before == nil)
        else { return }
        records[space.key] = after
        commit()
    }

    private func commit() {
        if let data = try? JSONEncoder().encode(records) {
            persistence.save(data)
        }
        onChange?()
    }
}
