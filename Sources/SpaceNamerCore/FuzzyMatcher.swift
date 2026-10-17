import Foundation

/// Small, predictable fuzzy matcher for the switcher: prefix beats word-prefix beats
/// substring beats scattered letters. Case and diacritics are ignored.
public enum FuzzyMatcher {
    public struct Match: Equatable {
        public let score: Int
        /// UTF-16 ranges in the original text, for highlighting.
        public let ranges: [NSRange]
    }

    public static func match(_ query: String, in text: String) -> Match? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Match(score: 0, ranges: []) }
        guard !text.isEmpty else { return nil }

        let nsText = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let found = nsText.range(of: query, options: options)
        if found.location != NSNotFound {
            let atStart = found.location == 0
            let atWord = atStart || isWordBoundary(before: found.location, in: nsText)
            let base = atStart ? 3000 : atWord ? 2000 : 1000
            let exact = found.length == nsText.length ? 500 : 0
            return Match(score: base + exact - min(found.location, 200), ranges: [found])
        }

        return subsequenceMatch(query, in: text)
    }

    private static func subsequenceMatch(_ query: String, in text: String) -> Match? {
        let needle = query.filter { !$0.isWhitespace }.map(fold)
        guard !needle.isEmpty else { return nil }

        var ranges: [NSRange] = []
        var score = 500
        var needleIndex = 0
        var utf16Offset = 0
        var previousMatchEnd: Int?
        var previousCharacter: Character?

        for character in text {
            let length = character.utf16.count
            defer {
                utf16Offset += length
                previousCharacter = character
            }
            guard needleIndex < needle.count else { break }
            guard fold(character) == needle[needleIndex] else { continue }

            if let end = previousMatchEnd, end == utf16Offset, let last = ranges.popLast() {
                ranges.append(NSRange(location: last.location, length: last.length + length))
                score += 15
            } else {
                ranges.append(NSRange(location: utf16Offset, length: length))
                if let gapStart = previousMatchEnd { score -= min(utf16Offset - gapStart, 20) }
            }
            if previousCharacter == nil || !(previousCharacter!.isLetter || previousCharacter!.isNumber) {
                score += 25
            }
            previousMatchEnd = utf16Offset + length
            needleIndex += 1
        }

        return needleIndex == needle.count ? Match(score: score, ranges: ranges) : nil
    }

    private static func fold(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isWordBoundary(before location: Int, in text: NSString) -> Bool {
        guard location > 0 else { return true }
        let previous = text.character(at: location - 1)
        guard let scalar = Unicode.Scalar(previous) else { return false }
        return !CharacterSet.alphanumerics.contains(scalar)
    }
}
