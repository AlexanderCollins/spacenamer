// Kept apart from the tests: with only the Command Line Tools installed, a file can't
// import both Foundation and Testing.
import Foundation
@testable import SpaceNamerCore

// MARK: Fixtures

func rawSpace(_ managedID: UInt64, uuid: String, type: UInt64 = 0) -> [String: Any] {
    ["ManagedSpaceID": managedID, "id64": managedID, "type": type, "uuid": uuid]
}

func rawDisplay(_ id: String, current: UInt64, spaces: [[String: Any]]) -> [String: Any] {
    ["Display Identifier": id, "Current Space": ["ManagedSpaceID": current], "Spaces": spaces]
}

func snapshot(_ spaces: [[String: Any]], current: UInt64 = 1, display: String = "Main") -> SpacesSnapshot {
    SpaceParser.parse([rawDisplay(display, current: current, spaces: spaces)], activeDisplayID: display)
}

final class MemoryPersistence: RecordPersistence {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

final class Clock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { date += seconds }
}

func urlCommand(_ string: String) -> URLCommand? {
    URL(string: string).flatMap(URLCommand.init(url:))
}

func longName(_ length: Int) -> String { String(repeating: "x", count: length) }

/// GitHub's comparison of a build's commit with `main`, trimmed to what the update check reads.
func comparison(aheadBy: Int, messages: [String]) -> Data {
    let commits = messages.enumerated().map { index, message in
        ["sha": "c\(index)", "commit": ["message": message], "html_url": "https://github.com/AlexanderCollins/spacenamer/commit/c\(index)"] as [String: Any]
    }
    let json: [String: Any] = ["ahead_by": aheadBy, "commits": commits, "html_url": "https://github.com/AlexanderCollins/spacenamer/compare/abc...main"]
    return try! JSONSerialization.data(withJSONObject: json)
}
