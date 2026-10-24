import Foundation

/// Newer commits on GitHub than the build that's running.
public struct AvailableUpdate: Equatable {
    public struct Change: Equatable {
        /// The commit's subject line.
        public let summary: String
        /// The commit on GitHub.
        public let page: URL?

        public init(summary: String, page: URL?) {
            self.summary = summary
            self.page = page
        }
    }

    /// Every change, newest first.
    public let changes: [Change]
    /// The newest commit, which identifies this update.
    public let latest: String
    /// All the changes on GitHub.
    public let page: URL?

    public init(changes: [Change], latest: String, page: URL?) {
        self.changes = changes
        self.latest = latest
        self.page = page
    }
}

/// Asks GitHub which commits on `main` are newer than the one a build was made from.
public enum UpdateCheck {
    public static let repository = "AlexanderCollins/spacenamer"
    public static let branch = "main"
    private static let longestSummary = 70

    /// GitHub's comparison of `commit` with the latest on `branch`.
    public static func request(since commit: String) -> URLRequest? {
        guard commit.count >= 7, commit.allSatisfy(\.isHexDigit),
              let url = URL(string: "https://api.github.com/repos/\(repository)/compare/\(commit)...\(branch)")
        else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SpaceNamer", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The update a comparison describes, or nil when the build is up to date (or ahead).
    public static func update(fromComparison data: Data) throws -> AvailableUpdate? {
        let comparison = try JSONDecoder().decode(Comparison.self, from: data)
        // Oldest first from GitHub.
        guard comparison.aheadBy > 0, let latest = comparison.commits.last?.sha else { return nil }
        let changes = comparison.commits.reversed().compactMap { commit -> AvailableUpdate.Change? in
            guard let subject = commit.commit.message.split(separator: "\n").first.map(String.init),
                  // Merges say nothing about what changed.
                  !subject.hasPrefix("Merge ")
            else { return nil }
            let summary = subject.count > longestSummary ? String(subject.prefix(longestSummary - 1)) + "…" : subject
            return AvailableUpdate.Change(summary: summary, page: commit.htmlURL)
        }
        return AvailableUpdate(changes: changes, latest: latest, page: comparison.htmlURL)
    }

    private struct Comparison: Decodable {
        struct Commit: Decodable {
            struct Details: Decodable { let message: String }
            let sha: String
            let commit: Details
            let htmlURL: URL?

            enum CodingKeys: String, CodingKey {
                case sha, commit
                case htmlURL = "html_url"
            }
        }

        let aheadBy: Int
        let commits: [Commit]
        let htmlURL: URL?

        enum CodingKeys: String, CodingKey {
            case aheadBy = "ahead_by"
            case commits
            case htmlURL = "html_url"
        }
    }
}
