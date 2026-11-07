import Foundation

/// Finds overlaps conservatively when a volume's case behavior is unknown.
struct DeletionPathIndex {
    struct Entry {
        let path: String
        let caseSensitive: Bool
    }

    private let entries: [Entry]
    private let normalized: [String]
    private let byFoldedPath: [String: [Int]]

    init(_ entries: [Entry]) {
        self.entries = entries
        normalized = entries.map { Self.normalize($0.path) }
        var index: [String: [Int]] = [:]
        for (offset, path) in normalized.enumerated() { index[Self.fold(path), default: []].append(offset) }
        byFoldedPath = index
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    private static func fold(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func ancestors(of path: String) -> [String] {
        var parts: [String] = []
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            parts.append(prefix)
        }
        return parts
    }

    private func matchingAncestors(path: String, caseSensitive: Bool) -> [Int] {
        var matches: [Int] = []
        for prefix in ancestors(of: Self.normalize(path)) {
            for index in byFoldedPath[Self.fold(prefix)] ?? [] {
                if caseSensitive && entries[index].caseSensitive && normalized[index] != prefix { continue }
                matches.append(index)
            }
        }
        return matches
    }

    func overlappingIndices() -> Set<Int> {
        var conflicts = Set<Int>()
        for (index, entry) in entries.enumerated() {
            for ancestor in matchingAncestors(path: entry.path, caseSensitive: entry.caseSensitive) where ancestor != index {
                conflicts.insert(index)
                conflicts.insert(ancestor)
            }
        }
        return conflicts
    }

    func hasSelectedAncestor(of path: String, caseSensitive: Bool) -> Bool {
        !matchingAncestors(path: path, caseSensitive: caseSensitive).isEmpty
    }
}
