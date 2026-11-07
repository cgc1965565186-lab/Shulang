import Foundation
import Darwin

public struct ScanProgress: Sendable {
    public let scannedItems: Int
    /// 文件逻辑大小合计。
    public let scannedBytes: Int64
    /// 已分配空间估算；共享数据块可能导致汇总不同于唯一物理占用。
    public let scannedAllocatedBytes: Int64
    public let currentPath: String
    public let isPaused: Bool
    public let fallbackCount: Int
    public init(scannedItems: Int, scannedBytes: Int64, scannedAllocatedBytes: Int64 = 0,
                currentPath: String, isPaused: Bool, fallbackCount: Int) {
        self.scannedItems = scannedItems; self.scannedBytes = scannedBytes
        self.scannedAllocatedBytes = scannedAllocatedBytes
        self.currentPath = currentPath; self.isPaused = isPaused
        self.fallbackCount = fallbackCount
    }
}

/// 扫描边界策略：整卷扫描时必须跨过 APFS 的重复挂载视图与系统管理空间，
/// 否则 `/` 会把 `/System/Volumes/Data` 里的同一批文件再算一遍（曾出现 460 GB 卷扫出 598 GB）。
public enum ScanSkipPolicy {
    private static let alwaysSkipPrefixes = [
        "/dev", "/Network", "/cores", "/.vol",
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.Trashes",
        "/private/var/vm",          // swap / sleepimage，系统管理空间
        "/private/var/db/diagnostics", "/private/var/db/DiagnosticPipeline"
    ]

    /// - Parameters:
    ///   - path: 待判断的子项路径
    ///   - root: 本次扫描根；若根本身就在该前缀下，则不能跳过（用户显式选择）
    public static func shouldSkip(path: String, root: String) -> Bool {
        for prefix in alwaysSkipPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return true
        }
        // /System/Volumes 是同一 APFS 容器里系统卷、Preboot、VM、Update 等挂载视图的集合。
        // /Users、/Applications 等通过 firmlink 已可直接从 / 访问，跳过不会漏数据。
        if path.hasPrefix("/System/Volumes/"), !root.hasPrefix("/System/Volumes/") { return true }
        // 整卷扫描不跨到其他卷（外置盘、Recovery 等）。
        if path.hasPrefix("/Volumes/"), !root.hasPrefix("/Volumes/") { return true }
        return false
    }
}

public struct ScanOutcome: Sendable {
    public let root: ScanNode
    public var report: ScanReport
}

public struct ScanLimits: Sendable {
    public var maxDepth: Int = 64
    public var maxEntriesPerDirectory: Int = 200_000
    public var includeHidden: Bool = true
    public var enumerator: EnumeratorKind = .foundation
    public init() {}
}

/// 协作式扫描引擎：可取消、可暂停（暂停不丢已扫描节点）、流式进度、不可读目录跳过。
public final class ScanEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _paused = false

    public init() {}

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return _paused }

    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    public func setPaused(_ value: Bool) { lock.lock(); _paused = value; lock.unlock() }

    private func shouldContinue() -> Bool {
        if isCancelled { return false }
        while isPaused {
            if isCancelled { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    public func scan(url: URL, limits: ScanLimits = ScanLimits(),
                     onProgress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanOutcome {
        let engine = self
        return try await Task.detached(priority: .userInitiated) {
            try engine.perform(url: url, limits: limits, onProgress: onProgress)
        }.value
    }

    private func perform(url: URL, limits: ScanLimits,
                         onProgress: @escaping @Sendable (ScanProgress) -> Void) throws -> ScanOutcome {
        let started = Date()
        let foundation = FoundationEnumerator()
        let bulk = BulkEnumerator()
        var errors: [String] = []
        var inaccessible = 0
        var scannedItems = 0
        var scannedBytes: Int64 = 0
        var scannedAllocatedBytes: Int64 = 0
        var fallbacks = 0
        var excludedPaths: [String] = []
        var truncatedPaths: [String] = []
        var seenHardLinks = Set<FileIdentity>()

        func shouldContinue() -> Bool { self.shouldContinue() }

        func build(_ directory: URL, name: String, depth: Int, kind: NodeKind) throws -> ScanNode {
            let node = ScanNode(url: directory, name: name, kind: kind)
            var directoryStat = stat()
            if lstat(directory.path, &directoryStat) == 0, (directoryStat.st_mode & S_IFMT) == S_IFDIR {
                node.identity = FileIdentity(device: UInt64(UInt32(bitPattern: directoryStat.st_dev)), inode: UInt64(directoryStat.st_ino))
                node.modificationDate = Date(timeIntervalSince1970: Double(directoryStat.st_mtimespec.tv_sec) + Double(directoryStat.st_mtimespec.tv_nsec) / 1_000_000_000)
                node.changeDate = Date(timeIntervalSince1970: Double(directoryStat.st_ctimespec.tv_sec) + Double(directoryStat.st_ctimespec.tv_nsec) / 1_000_000_000)
                node.linkCount = Int(directoryStat.st_nlink)
            }
            if isCancelled { return node }
            guard kind == .directory else { return node }
            guard depth < limits.maxDepth else {
                errors.append("超过扫描深度上限：\(directory.path)")
                truncatedPaths.append(directory.path)
                node.isInaccessible = true
                return node
            }

            let primary: DirectoryEnumerating = limits.enumerator == .bulk ? bulk : foundation
            var listing: DirectoryListing?
            do {
                listing = try primary.entries(at: directory, includeHidden: limits.includeHidden,
                                              shouldContinue: shouldContinue)
                if listing == nil && limits.enumerator == .bulk {
                    fallbacks += 1
                    listing = try foundation.entries(at: directory, includeHidden: limits.includeHidden,
                                                     shouldContinue: shouldContinue)
                }
            } catch is CancellationError { return node }
            catch {
                inaccessible += 1
                errors.append("无法读取目录：\(directory.path) — \(error.localizedDescription)")
                node.isInaccessible = true
                return node
            }
            guard let listing else {
                inaccessible += 1
                errors.append("无法读取目录：\(directory.path)")
                node.isInaccessible = true
                return node
            }
            if listing.enumeratedCount > limits.maxEntriesPerDirectory {
                errors.append("单目录条目超过上限，已跳过：\(directory.path)")
                truncatedPaths.append(directory.path)
                node.isInaccessible = true
                return node
            }

            for entry in listing.entries {
                if isCancelled { break }
                if scannedItems % 64 == 0, !shouldContinue() { break }
                // 整卷扫描时跨过 APFS 重复挂载视图与系统管理空间（P1-09 计量修复）。
                if entry.kind == .directory,
                   ScanSkipPolicy.shouldSkip(path: entry.url.path, root: url.path) ||
                    entry.url.path.contains("/Library/CloudStorage/") ||
                    entry.url.path.hasSuffix("/Library/CloudStorage") ||
                    entry.url.path.contains("/Library/Mobile Documents/") ||
                    entry.url.path.hasSuffix("/Library/Mobile Documents") {
                    errors.append("已排除目录：\(entry.url.path)")
                    excludedPaths.append(entry.url.path)
                    continue
                }
                if !entry.isReadable {
                    inaccessible += 1
                    errors.append("无法读取项目：\(entry.url.path)")
                    let skipped = ScanNode(url: entry.url, name: entry.name, kind: entry.kind,
                                           isInaccessible: true)
                    skipped.isProtected = true
                    node.add(skipped)
                    continue
                }
                let child: ScanNode
                if entry.kind == .directory {
                    child = try build(entry.url, name: entry.name, depth: depth + 1, kind: .directory)
                } else {
                    child = ScanNode(url: entry.url, name: entry.name, kind: entry.kind,
                                     logicalSize: entry.logicalSize, allocatedSize: entry.allocatedSize,
                                     modificationDate: entry.modificationDate,
                                     accessDate: entry.accessDate, identity: entry.identity,
                                     linkCount: entry.linkCount, changeDate: entry.changeDate)
                    // 硬链接 / 同 inode 只首次计入容量，避免总量虚高。
                    if entry.linkCount > 1, let identity = entry.identity {
                        if seenHardLinks.contains(identity) {
                            child.logicalSize = 0
                            child.allocatedSize = 0
                        } else {
                            seenHardLinks.insert(identity)
                        }
                    }
                    // 符号链接只计链接本身，不递归、不跟随。
                    // 两个枚举器对 VLNK 的 resource values 口径不同，这里统一用 lstat 的
                    // st_size（链接路径字节数），保证 Foundation 与 getattrlistbulk 结果可比。
                    if entry.kind == .symbolicLink {
                        var linkStat = stat()
                        let linkBytes: Int64 = lstat(entry.url.path, &linkStat) == 0
                            ? Int64(linkStat.st_size) : 0
                        child.logicalSize = linkBytes
                        child.allocatedSize = linkBytes
                    }
                }
                child.isProtected = PathGuard.isProtected(entry.url)
                node.add(child)

                scannedItems += 1
                if entry.kind != .directory {
                    scannedBytes += child.logicalSize
                    scannedAllocatedBytes += child.allocatedSize
                }
                if scannedItems % 2000 == 0 {
                    onProgress(ScanProgress(scannedItems: scannedItems, scannedBytes: scannedBytes,
                                            scannedAllocatedBytes: scannedAllocatedBytes,
                                            currentPath: entry.url.path, isPaused: isPaused,
                                            fallbackCount: fallbacks))
                }
            }
            return node
        }

        let root = try build(url, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                             depth: 0, kind: .directory)
        CategoryEngine.classify(root)
        root.recomputeAggregates()   // 聚合一次，之后 effectiveSize 为 O(1) 读取
        let files = root.flattenedFiles()
        onProgress(ScanProgress(scannedItems: scannedItems, scannedBytes: scannedBytes,
                                scannedAllocatedBytes: scannedAllocatedBytes,
                                currentPath: url.path, isPaused: false, fallbackCount: fallbacks))
        var report = ScanReport(
            startedAt: started, duration: Date().timeIntervalSince(started),
            rootPath: url.path, totalNodes: scannedItems, totalFiles: files.count,
            scannedLogicalBytes: root.effectiveSize, scannedAllocatedBytes: root.effectiveAllocatedSize,
            inaccessibleCount: inaccessible, errors: errors,
            rulesVersion: RuleSet.currentVersion, enumeratorName: limits.enumerator.rawValue
        )
        report.completionStatus = isCancelled ? "cancelled" : (errors.isEmpty ? "complete" : "partial")
        report.excludedPaths = excludedPaths
        report.truncatedPaths = truncatedPaths
        report.includeHidden = limits.includeHidden
        report.fallbackCount = fallbacks
        report.maxDepth = limits.maxDepth
        report.maxEntriesPerDirectory = limits.maxEntriesPerDirectory
        return ScanOutcome(root: root, report: report)
    }
}

// MARK: - 扫描差异（M4-09）

public enum DiffEngine {
    private struct Record { let size: Int64; let identity: FileIdentity? }

    private static func index(_ root: ScanNode) -> [String: Record] {
        var result: [String: Record] = [:]
        for file in root.flattenedFiles() {
            result[file.url.path] = Record(size: file.logicalSize, identity: file.identity)
        }
        return result
    }

    public static func compare(old: ScanNode, new: ScanNode) -> [ScanDiffEntry] {
        compare(before: index(old), after: index(new))
    }

    public static func compare(old: ScanSnapshot, new: ScanSnapshot) -> [ScanDiffEntry] {
        func index(_ snapshot: ScanSnapshot) -> [String: Record] {
            Dictionary(snapshot.nodes.filter { $0.kind == .file }.map {
                ($0.path, Record(size: $0.logicalSize, identity: $0.identity))
            }, uniquingKeysWith: { first, _ in first })
        }
        return compare(before: index(old), after: index(new))
    }

    private static func compare(before: [String: Record], after: [String: Record]) -> [ScanDiffEntry] {
        var entries: [ScanDiffEntry] = []
        let removed = before.filter { after[$0.key] == nil }
        let added = after.filter { before[$0.key] == nil }
        var removedByIdentity: [FileIdentity: [String]] = [:]
        var addedByIdentity: [FileIdentity: [String]] = [:]
        for (path, record) in removed { if let identity = record.identity { removedByIdentity[identity, default: []].append(path) } }
        for (path, record) in added { if let identity = record.identity { addedByIdentity[identity, default: []].append(path) } }
        var renamedOld = Set<String>(), renamedNew = Set<String>()
        for (identity, oldPaths) in removedByIdentity {
            guard oldPaths.count == 1, let newPaths = addedByIdentity[identity], newPaths.count == 1,
                  let oldPath = oldPaths.first, let newPath = newPaths.first,
                  let oldRecord = before[oldPath], let newRecord = after[newPath] else { continue }
            var entry = ScanDiffEntry(path: newPath, change: .renamed, deltaBytes: newRecord.size - oldRecord.size)
            entry.oldPath = oldPath
            entries.append(entry)
            renamedOld.insert(oldPath); renamedNew.insert(newPath)
        }
        for (path, record) in after where before[path] == nil {
            if renamedNew.contains(path) { continue }
            entries.append(ScanDiffEntry(path: path, change: .added, deltaBytes: record.size))
        }
        for (path, record) in before where after[path] == nil {
            if renamedOld.contains(path) { continue }
            entries.append(ScanDiffEntry(path: path, change: .deleted, deltaBytes: -record.size))
        }
        for (path, newRecord) in after {
            guard let oldRecord = before[path] else { continue }
            let delta = newRecord.size - oldRecord.size
            if delta > 0 { entries.append(ScanDiffEntry(path: path, change: .grew, deltaBytes: delta)) }
            else if delta < 0 { entries.append(ScanDiffEntry(path: path, change: .shrank, deltaBytes: delta)) }
        }
        return entries.sorted { abs($0.deltaBytes) > abs($1.deltaBytes) }
    }
}
