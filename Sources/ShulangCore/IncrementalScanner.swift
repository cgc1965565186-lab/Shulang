import Foundation
import Darwin

public struct IncrementalScanResult: Sendable {
    public let outcome: ScanOutcome
    public let usedFullScan: Bool
    public let fallbackReason: String?
}

public enum IncrementalScanner {
    /// The caller must flush a continuously running FSEvents stream before and after this operation.
    /// Events received during the scan must remain pending; this function never acknowledges them.
    public static func rescan(snapshot: ScanSnapshot, changedDirectories: [String], limits: ScanLimits,
                              onProgress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> IncrementalScanResult {
        let rootURL = URL(fileURLWithPath: snapshot.report.rootPath, isDirectory: true)
        func scan(_ url: URL, using limits: ScanLimits) async throws -> ScanOutcome {
            let engine = ScanEngine()
            return try await withTaskCancellationHandler {
                try await engine.scan(url: url, limits: limits, onProgress: onProgress)
            } onCancel: { engine.cancel() }
        }
        func full(_ reason: String) async throws -> IncrementalScanResult {
            try Task.checkCancellation()
            let result = try await scan(rootURL, using: limits)
            try Task.checkCancellation()
            return IncrementalScanResult(outcome: result, usedFullScan: true, fallbackReason: reason)
        }

        guard snapshot.formatVersion == 1, snapshot.report.completionStatus == "complete",
              snapshot.report.includeHidden == limits.includeHidden,
              snapshot.report.maxDepth == limits.maxDepth,
              snapshot.report.maxEntriesPerDirectory == limits.maxEntriesPerDirectory,
              snapshot.report.enumeratorName == limits.enumerator.rawValue,
              let first = snapshot.nodes.first, first.kind == .directory,
              let rootIdentity = first.identity else { return try await full("快照覆盖或扫描设置不兼容") }
        guard !snapshot.nodes.contains(where: { $0.linkCount == nil || $0.category == nil || $0.isProtected == nil || ($0.kind == .file && ($0.changeDate == nil || ($0.linkCount ?? 1) > 1)) }) else {
            return try await full("缺少元数据或存在硬链接")
        }
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        var rootStat = stat()
        guard lstat(canonicalRoot, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR,
              UInt64(UInt32(bitPattern: rootStat.st_dev)) == rootIdentity.device, UInt64(rootStat.st_ino) == rootIdentity.inode else {
            return try await full("扫描根目录或卷已变化")
        }
        let rootPrefix = canonicalRoot == "/" ? "/" : canonicalRoot + "/"
        let changed = Set(changedDirectories.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        guard !changed.contains(canonicalRoot), changed.allSatisfy({ $0.hasPrefix(rootPrefix) }) else {
            return try await full("根目录变化或失效路径超出扫描范围")
        }

        let byID = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var directories: [String: ScanSnapshot.Node] = [:]
        var unmarkedDirectoryChanged = false
        for node in snapshot.nodes where node.kind == .directory {
            var current = stat()
            guard let identity = node.identity, let changeDate = node.changeDate, lstat(node.path, &current) == 0,
                  (current.st_mode & S_IFMT) == S_IFDIR,
                  UInt64(UInt32(bitPattern: current.st_dev)) == identity.device,
                  UInt64(current.st_ino) == identity.inode,
                  access(node.path, R_OK | X_OK) == 0 else {
                return try await full("目录身份或访问权限已变化")
            }
            let canonical = URL(fileURLWithPath: node.path).resolvingSymlinksInPath().standardizedFileURL.path
            var ancestor = canonical
            var coveredByChange = false
            while ancestor != canonicalRoot {
                if changed.contains(ancestor) { coveredByChange = true; break }
                let parent = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
                if parent == ancestor { break }
                ancestor = parent
            }
            if !coveredByChange {
                let currentChange = Double(current.st_ctimespec.tv_sec) + Double(current.st_ctimespec.tv_nsec) / 1_000_000_000
                if abs(changeDate.timeIntervalSince1970 - currentChange) > 0.000001 {
                    unmarkedDirectoryChanged = true
                }
            }
            directories[canonical] = node
        }
        if unmarkedDirectoryChanged { return try await full("未标记目录的状态或权限已变化") }
        var selected: [(String, ScanSnapshot.Node)] = []
        for path in changed.sorted() {
            if selected.contains(where: { path.hasPrefix($0.0 + "/") }) { continue }
            guard let node = directories[path], node.parentID != nil,
                  FileManager.default.fileExists(atPath: path) else { return try await full("变化目录已移动、删除或无法识别") }
            selected.append((path, node))
        }

        let started = Date()
        var replacements: [(UUID, ScanNode)] = []
        for (path, node) in selected {
            try Task.checkCancellation()
            var depth = 0
            var ancestor = node.parentID
            while let id = ancestor, let parent = byID[id] { depth += 1; ancestor = parent.parentID }
            var subLimits = limits
            subLimits.maxDepth -= depth
            guard subLimits.maxDepth > 0 else { return try await full("变化目录达到扫描深度上限") }
            let result = try await scan(URL(fileURLWithPath: path, isDirectory: true), using: subLimits)
            try Task.checkCancellation()
            guard result.report.completionStatus == "complete",
                  !result.root.flattenedFiles().contains(where: { $0.linkCount > 1 }) else {
                return try await full("变化目录覆盖不完整或包含硬链接")
            }
            result.root.isProtected = PathGuard.isProtected(result.root.url)
            replacements.append((node.id, result.root))
        }

        let replaced = Set(replacements.map(\.0))
        var removed = Set<UUID>()
        var rebuilt: [UUID: ScanNode] = [:]
        var root: ScanNode?
        for item in snapshot.nodes {
            if replaced.contains(item.id) || item.parentID.map({ removed.contains($0) }) == true {
                removed.insert(item.id)
                continue
            }
            let node = ScanNode(url: URL(fileURLWithPath: item.path), kind: item.kind,
                                logicalSize: item.logicalSize, allocatedSize: item.allocatedSize,
                                modificationDate: item.modificationDate, accessDate: item.accessDate,
                                identity: item.identity, linkCount: item.linkCount ?? 1,
                                isProtected: item.isProtected ?? true, category: item.category ?? .other,
                                sourceRule: item.sourceRule, isInaccessible: item.isInaccessible, id: item.id, changeDate: item.changeDate)
            rebuilt[item.id] = node
            if let parent = item.parentID { rebuilt[parent]?.add(node) } else { root = node }
        }
        guard let root else { return try await full("无法重建快照根目录") }
        for (oldID, replacement) in replacements {
            guard let parentID = byID[oldID]?.parentID, let parent = rebuilt[parentID] else {
                return try await full("无法定位变化目录的父目录")
            }
            parent.add(replacement)
        }
        root.recomputeAggregates()
        var count = 0
        var pending = root.children
        while let node = pending.popLast() { count += 1; pending.append(contentsOf: node.children) }
        var report = ScanReport(startedAt: started, duration: Date().timeIntervalSince(started), rootPath: snapshot.report.rootPath,
                                totalNodes: count, totalFiles: root.flattenedFiles().count,
                                scannedLogicalBytes: root.effectiveSize, scannedAllocatedBytes: root.effectiveAllocatedSize,
                                inaccessibleCount: 0, errors: [], rulesVersion: RuleSet.currentVersion, enumeratorName: limits.enumerator.rawValue)
        report.completionStatus = "complete"
        report.excludedPaths = []
        report.truncatedPaths = []
        report.includeHidden = limits.includeHidden
        report.fallbackCount = 0
        report.maxDepth = limits.maxDepth
        report.maxEntriesPerDirectory = limits.maxEntriesPerDirectory
        return IncrementalScanResult(outcome: ScanOutcome(root: root, report: report), usedFullScan: false, fallbackReason: nil)
    }
}
