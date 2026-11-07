import Foundation

/// Immutable, versioned metadata captured from one completed scan.
public struct ScanSnapshot: Codable, Sendable {
    public struct Node: Codable, Sendable {
        public let id: UUID
        public let parentID: UUID?
        public let path: String
        public let kind: NodeKind
        public let logicalSize: Int64
        public let allocatedSize: Int64
        public let identity: FileIdentity?
        public let modificationDate: Date?
        public let isInaccessible: Bool
        public let accessDate: Date?
        public let linkCount: Int?
        public let category: CategoryKind?
        public let sourceRule: String?
        public let isProtected: Bool?
        public let changeDate: Date?
        public let effectiveLogicalSize: Int64?
        public let effectiveAllocatedSize: Int64?
    }

    public let formatVersion: Int
    public let sessionID: UUID
    public let revision: Int
    public let report: ScanReport
    public let nodes: [Node]

    public init(outcome: ScanOutcome, sessionID: UUID = UUID(), revision: Int = 1) {
        formatVersion = 1
        self.sessionID = sessionID
        self.revision = revision
        report = outcome.report
        var result: [Node] = []
        var stack: [(ScanNode, UUID?)] = [(outcome.root, nil)]
        while let (node, parentID) = stack.popLast() {
            result.append(Node(id: node.id, parentID: parentID, path: node.url.path, kind: node.kind,
                               logicalSize: node.logicalSize, allocatedSize: node.allocatedSize,
                               identity: node.identity, modificationDate: node.modificationDate,
                               isInaccessible: node.isInaccessible, accessDate: node.accessDate,
                               linkCount: node.linkCount, category: node.category,
                               sourceRule: node.sourceRule, isProtected: node.isProtected, changeDate: node.changeDate,
                               effectiveLogicalSize: node.effectiveSize, effectiveAllocatedSize: node.effectiveAllocatedSize))
            stack.append(contentsOf: node.children.reversed().map { ($0, node.id) })
        }
        nodes = result
    }

    /// Diff results are meaningful only when both scans have the same known coverage.
    public func canCompare(to other: ScanSnapshot) -> Bool {
        func knownCoverage(_ report: ScanReport, excluded: [String]) -> Bool {
            if report.completionStatus == "complete" { return report.errors.isEmpty && excluded.isEmpty }
            guard report.completionStatus == "partial", !excluded.isEmpty else { return false }
            let exclusions = excluded.map { "已排除目录：\($0)" }
            return report.errors.count == exclusions.count && Set(report.errors) == Set(exclusions)
        }
        guard formatVersion == 1, other.formatVersion == 1,
              report.rootPath == other.report.rootPath,
              let hidden = report.includeHidden, hidden == other.report.includeHidden,
              let depth = report.maxDepth, depth == other.report.maxDepth,
              let entries = report.maxEntriesPerDirectory, entries == other.report.maxEntriesPerDirectory,
              let excluded = report.excludedPaths, let otherExcluded = other.report.excludedPaths,
              let truncated = report.truncatedPaths, let otherTruncated = other.report.truncatedPaths else { return false }
        return knownCoverage(report, excluded: excluded) && knownCoverage(other.report, excluded: otherExcluded) &&
            Set(excluded) == Set(otherExcluded) && truncated.isEmpty && otherTruncated.isEmpty &&
            report.inaccessibleCount == 0 && other.report.inaccessibleCount == 0
    }

    /// Nodes are stored in depth-first order, allowing a subtree to be read without walking mutable UI state.
    public func files(in directoryID: UUID) -> [Node] {
        var directories = Set<UUID>()
        var result: [Node] = []
        var found = false
        for item in nodes {
            if item.id == directoryID { found = true; directories.insert(item.id); continue }
            guard found else { continue }
            guard let parent = item.parentID, directories.contains(parent) else { break }
            if item.kind == .directory || item.kind == .package { directories.insert(item.id) }
            else if item.kind == .file { result.append(item) }
        }
        return result
    }
}
