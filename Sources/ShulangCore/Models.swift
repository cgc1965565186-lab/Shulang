import Foundation

// MARK: - 基础枚举

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case safe, review, caution
    public var order: Int {
        switch self { case .safe: return 0; case .review: return 1; case .caution: return 2 }
    }
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.order < b.order }
    public var title: String {
        switch self { case .safe: return "可重建"; case .review: return "需复核"; case .caution: return "谨慎" }
    }
    public var symbol: String {
        switch self { case .safe: return "checkmark.shield"; case .review: return "exclamationmark.triangle"; case .caution: return "xmark.octagon" }
    }
    public var explanation: String {
        switch self {
        case .safe: return "可重建的缓存、日志或临时文件，删除后应用会自动生成。"
        case .review: return "可能影响应用状态或需要重新下载，请确认后再清理。"
        case .caution: return "涉及用户数据或系统管理内容，不参与「全选」，需逐项确认。"
        }
    }
}

public enum NodeKind: String, Codable, Sendable {
    case file, directory, symbolicLink, package
}

public enum CategoryKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case caches, logs, temporary, downloads, developer, applications, trash, mediaMail, largeFiles, duplicates, other, protected
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .caches: return "缓存"; case .logs: return "日志"; case .temporary: return "临时文件"
        case .downloads: return "下载"; case .developer: return "开发工具"; case .applications: return "应用与残留"
        case .trash: return "废纸篓"; case .mediaMail: return "媒体与邮件"; case .largeFiles: return "大文件"
        case .duplicates: return "重复文件"; case .other: return "其他"; case .protected: return "受保护"
        }
    }
}

public struct FileIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

// MARK: - 卷

public struct VolumeInfo: Identifiable, Codable, Sendable {
    public var id: String { mountPoint.path }
    public let url: URL
    public let mountPoint: URL
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let importantAvailableBytes: Int64
    public let isExternal: Bool
    public let isReadOnly: Bool

    public var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    public var usageFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    public init(url: URL, mountPoint: URL? = nil, name: String, totalBytes: Int64,
                availableBytes: Int64, importantAvailableBytes: Int64,
                isExternal: Bool = false, isReadOnly: Bool = false) {
        self.url = url
        self.mountPoint = mountPoint ?? url
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.importantAvailableBytes = importantAvailableBytes
        self.isExternal = isExternal
        self.isReadOnly = isReadOnly
    }
}

// MARK: - 扫描树

/// 文件树节点。用 class + weak parent 避免百万节点的值类型复制开销（计划 5.3 节）。
public final class ScanNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let kind: NodeKind
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var modificationDate: Date?
    public var accessDate: Date?
    public var changeDate: Date?
    public var identity: FileIdentity?
    public var linkCount: Int
    public var isProtected: Bool
    public var category: CategoryKind
    public var sourceRule: String?
    public var children: [ScanNode]
    public weak var parent: ScanNode?
    public var isInaccessible: Bool

    public init(url: URL, name: String? = nil, kind: NodeKind,
                logicalSize: Int64 = 0, allocatedSize: Int64 = 0,
                modificationDate: Date? = nil, accessDate: Date? = nil,
                identity: FileIdentity? = nil, linkCount: Int = 1,
                isProtected: Bool = false, category: CategoryKind = .other,
                sourceRule: String? = nil, isInaccessible: Bool = false, id: UUID = UUID(), changeDate: Date? = nil) {
        self.id = id
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.accessDate = accessDate
        self.changeDate = changeDate
        self.identity = identity
        self.linkCount = linkCount
        self.isProtected = isProtected
        self.category = category
        self.sourceRule = sourceRule
        self.children = []
        self.isInaccessible = isInaccessible
    }

    public var isDirectoryLike: Bool { kind == .directory || kind == .package }

    // 聚合值一次后序遍历填充，读取 O(1)。此前是每次递归整棵子树，
    // 切页面/点方块都会重复触发，是界面卡顿的主因之一（P0-B1）。
    public private(set) var aggregatedSize: Int64 = 0
    public private(set) var aggregatedAllocatedSize: Int64 = 0
    public private(set) var fileCount: Int = 0

    public var effectiveSize: Int64 { isDirectoryLike ? aggregatedSize : logicalSize }
    public var effectiveAllocatedSize: Int64 { isDirectoryLike ? aggregatedAllocatedSize : allocatedSize }

    /// 自底向上重算聚合值；扫描结束与清理裁剪后各调用一次。
    public func recomputeAggregates() {
        if isDirectoryLike {
            var size: Int64 = 0
            var allocated: Int64 = 0
            var count = 0
            for child in children {
                child.recomputeAggregates()
                size += child.effectiveSize
                allocated += child.effectiveAllocatedSize
                count += child.isDirectoryLike ? child.fileCount : 1
            }
            aggregatedSize = size
            aggregatedAllocatedSize = allocated
            fileCount = count
        } else {
            aggregatedSize = logicalSize
            aggregatedAllocatedSize = allocatedSize
            fileCount = 1
        }
    }

    public func add(_ child: ScanNode) { child.parent = self; children.append(child) }

    /// 扁平化为叶子文件列表，供去重、列表、报告使用。
    public func flattenedFiles() -> [ScanNode] {
        var result: [ScanNode] = []
        func walk(_ node: ScanNode) {
            if node.kind == .file { result.append(node); return }
            for child in node.children { walk(child) }
        }
        walk(self)
        return result
    }
}

// MARK: - 候选与风险

public struct Candidate: Identifiable, Codable, Sendable {
    public let id: UUID
    public let nodeID: UUID
    public let path: String
    public let displayName: String
    public let ruleID: String
    public let evidence: String
    public let confidence: Double
    public let risk: RiskLevel
    public let consequence: String
    public let rebuildable: Bool
    public let recoverable: Bool
    public let logicalSize: Int64
    public let category: CategoryKind
    public let scannedIdentity: FileIdentity?
    public let scannedModificationDate: Date?
    public let verifiedRule: Bool?
    public let duplicateKeeper: DuplicateKeeper?
    public let leftoverBundleID: String?
    public let scannedDirectoryFingerprint: String?
    public let scannedChangeDate: Date?

    public init(nodeID: UUID, path: String, displayName: String, ruleID: String,
                evidence: String, confidence: Double, risk: RiskLevel,
                consequence: String, rebuildable: Bool, recoverable: Bool,
                logicalSize: Int64, category: CategoryKind, scannedIdentity: FileIdentity? = nil,
                scannedModificationDate: Date? = nil, verifiedRule: Bool? = false,
                duplicateKeeper: DuplicateKeeper? = nil, leftoverBundleID: String? = nil,
                scannedDirectoryFingerprint: String? = nil, scannedChangeDate: Date? = nil) {
        self.duplicateKeeper = duplicateKeeper; self.leftoverBundleID = leftoverBundleID
        self.scannedDirectoryFingerprint = scannedDirectoryFingerprint
        self.scannedChangeDate = scannedChangeDate
        self.scannedIdentity = scannedIdentity; self.scannedModificationDate = scannedModificationDate
        self.verifiedRule = verifiedRule
        self.id = UUID(); self.nodeID = nodeID; self.path = path; self.displayName = displayName
        self.ruleID = ruleID; self.evidence = evidence; self.confidence = confidence
        self.risk = risk; self.consequence = consequence; self.rebuildable = rebuildable
        self.recoverable = recoverable; self.logicalSize = logicalSize; self.category = category
    }
}

// MARK: - 重复文件

public struct DuplicateKeeper: Codable, Sendable {
    public let path: String
    public let identity: FileIdentity
    public let digest: String
    public init(path: String, identity: FileIdentity, digest: String) {
        self.path = path; self.identity = identity; self.digest = digest
    }
}

public struct DuplicateCandidate: Identifiable, Codable, Sendable {
    public var id: UUID { nodeID }
    public let nodeID: UUID
    public let url: URL
    public let logicalSize: Int64
    public let modificationDate: Date?
    public let identity: FileIdentity?
    public let changeDate: Date?
    public init(nodeID: UUID, url: URL, logicalSize: Int64, modificationDate: Date?, identity: FileIdentity? = nil, changeDate: Date? = nil) {
        self.identity = identity
        self.changeDate = changeDate
        self.nodeID = nodeID; self.url = url; self.logicalSize = logicalSize
        self.modificationDate = modificationDate
    }
}

public struct DuplicateGroup: Identifiable, Codable, Sendable {
    public let id: UUID
    public let digest: String
    public let candidates: [DuplicateCandidate]
    public let recommendedKeepIndex: Int
    public init(digest: String, candidates: [DuplicateCandidate], recommendedKeepIndex: Int) {
        self.id = UUID(); self.digest = digest; self.candidates = candidates
        self.recommendedKeepIndex = recommendedKeepIndex
    }
    public var reclaimableBytes: Int64 {
        guard candidates.count > 1 else { return 0 }
        return candidates.enumerated().filter { $0.offset != recommendedKeepIndex }
            .reduce(0) { $0 + $1.element.logicalSize }
    }
}

// MARK: - 删除事务

public struct DeleteItem: Codable, Sendable {
    public let originalPath: String
    public let fileIdentity: FileIdentity?
    public var trashPath: String?
    public let logicalSize: Int64
    public let ruleID: String
    /// 删除前对文件首 4 KiB 计算的 SHA-256，用于恢复时核对身份（P0-A2）。
    public var preDeleteChecksum: String?
    public var scannedModificationDate: Date?
    public var duplicateKeeper: DuplicateKeeper?
    public var leftoverBundleID: String?
    public var scannedDirectoryFingerprint: String?
    public var scannedChangeDate: Date?
    /// 源卷标识，用于按卷分桶执行删除事务（P0-A2）。
    public let volumeID: String?
    public init(originalPath: String, fileIdentity: FileIdentity?, logicalSize: Int64,
                ruleID: String, preDeleteChecksum: String? = nil, volumeID: String? = nil) {
        self.originalPath = originalPath; self.fileIdentity = fileIdentity
        self.logicalSize = logicalSize; self.ruleID = ruleID
        self.preDeleteChecksum = preDeleteChecksum; self.volumeID = volumeID; self.scannedModificationDate = nil
        self.duplicateKeeper = nil; self.leftoverBundleID = nil; self.scannedDirectoryFingerprint = nil; self.scannedChangeDate = nil
    }
}

public struct DeletePlan: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let nonce: String
    public let rulesVersion: String
    public var items: [DeleteItem]
    public let totalEstimatedBytes: Int64
    public init(items: [DeleteItem], rulesVersion: String) {
        self.id = UUID(); self.createdAt = Date(); self.nonce = UUID().uuidString
        self.rulesVersion = rulesVersion; self.items = items
        self.totalEstimatedBytes = items.reduce(0) { $0 + $1.logicalSize }
    }
}

public struct DeletionResult: Codable, Sendable {
    public let plan: DeletePlan
    public let succeededCount: Int
    public let failedCount: Int
    public let actuallyMovedBytes: Int64
    public let failures: [String]
    public var movedItems: [DeleteItem]? = nil
    /// 已写入日志、尚未确认移动结果的项目。重启后只能凭身份查找，不能按名称猜测。
    public var pendingItem: DeleteItem? = nil
    /// 用户核查后仍无法确认位置的项目，不计作成功或可恢复。
    public var unverifiedItems: [DeleteItem]? = nil
}

public struct RestoreItemOutcome: Sendable {
    public enum Status: String, Sendable { case restored, alreadyRestored, conflict, failed }
    public let path: String
    public let status: Status
    public let message: String
}

public struct RestoreResult: Sendable {
    public let items: [RestoreItemOutcome]
    public var restoredCount: Int { items.filter { $0.status == .restored }.count }
    public var failedCount: Int { items.filter { $0.status == .conflict || $0.status == .failed }.count }
}

// MARK: - 扫描报告

public struct ScanReport: Codable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let duration: TimeInterval
    public let rootPath: String
    public let totalNodes: Int
    public let totalFiles: Int
    public let scannedLogicalBytes: Int64
    public let scannedAllocatedBytes: Int64
    public let inaccessibleCount: Int
    public let errors: [String]
    public let rulesVersion: String
    public let enumeratorName: String
    public var completionStatus: String? = nil
    public var excludedPaths: [String]? = nil
    public var truncatedPaths: [String]? = nil
    public var includeHidden: Bool? = nil
    public var fallbackCount: Int? = nil
    public var maxDepth: Int? = nil
    public var maxEntriesPerDirectory: Int? = nil
    public init(startedAt: Date, duration: TimeInterval, rootPath: String, totalNodes: Int,
                totalFiles: Int, scannedLogicalBytes: Int64, scannedAllocatedBytes: Int64,
                inaccessibleCount: Int, errors: [String], rulesVersion: String, enumeratorName: String) {
        self.id = UUID(); self.startedAt = startedAt; self.duration = duration; self.rootPath = rootPath
        self.totalNodes = totalNodes; self.totalFiles = totalFiles
        self.scannedLogicalBytes = scannedLogicalBytes; self.scannedAllocatedBytes = scannedAllocatedBytes
        self.inaccessibleCount = inaccessibleCount; self.errors = errors
        self.rulesVersion = rulesVersion; self.enumeratorName = enumeratorName
    }
}

public enum ScanChange: String, Codable, Sendable {
    case added, deleted, renamed, grew, shrank
}
public struct ScanDiffEntry: Identifiable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let change: ScanChange
    public let deltaBytes: Int64
    public var oldPath: String? = nil
}
