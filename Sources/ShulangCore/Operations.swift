import Foundation
import AppKit
import Quartz
import CryptoKit

// MARK: - 权限状态（TCC / Full Disk Access）

public enum FDAStatus: String, Codable, Sendable {
    case granted, denied, unknown
    public var title: String {
        switch self { case .granted: return "样本可访问"; case .denied: return "部分样本不可访问"; case .unknown: return "无法判定" }
    }
}

public enum PermissionProbe {
    private static let probePaths = [
        "Library/Safari", "Library/Mail", "Library/Messages",
        "Library/Containers/com.apple.mail", "Library/Application Support/AddressBook"
    ]

    /// 只做只读探测，绝不读写 TCC 数据库、不调用 tccutil。
    public static func fullDiskAccess() -> FDAStatus {
        let home = NSHomeDirectory()
        var results: [FDAStatus] = []
        for relative in probePaths {
            let path = (home as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                results.append(.granted)
            } catch {
                let nsError = error as NSError
                let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
                if nsError.code == EPERM || nsError.code == EACCES || nsError.code == 257 ||
                   (underlying?.code ?? 0) == EPERM || (underlying?.code ?? 0) == EACCES { results.append(.denied) }
                else { results.append(.unknown) }
            }
        }
        return summarize(results)
    }

    static func summarize(_ results: [FDAStatus]) -> FDAStatus {
        if results.contains(.denied) { return .denied }
        if results.isEmpty || results.contains(.unknown) { return .unknown }
        return .granted
    }

    public static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @discardableResult
    public static func quickLook(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return false }
        QuickLookSource.shared.urls = urls
        panel.dataSource = QuickLookSource.shared
        panel.makeKeyAndOrderFront(nil)
        return true
    }
}

private final class QuickLookSource: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookSource()
    var urls: [URL] = []
    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> QLPreviewItem? {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

// MARK: - 删除事务（M2-06 / M2-07）

public enum DeletionEngine {
    /// 只读文件首 4 KiB 计算 SHA-256；大文件也只读前缀，避免删除事务被全文 IO 拖慢（P0-A2）。
    private static func prefixChecksum(_ path: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 只接受扫描时取得身份的项目；不能把扫描后替换的文件当成原文件。
    public static func buildPlan(from candidates: [Candidate]) -> DeletePlan {
        let items = candidates.compactMap { candidate -> DeleteItem? in
            guard PathGuard.allowsDeletion(path: candidate.path), let identity = candidate.scannedIdentity else { return nil }
            var item = DeleteItem(originalPath: candidate.path, fileIdentity: identity,
                                  logicalSize: candidate.logicalSize, ruleID: candidate.ruleID,
                                  volumeID: String(identity.device))
            item.scannedModificationDate = candidate.scannedModificationDate
            item.duplicateKeeper = candidate.duplicateKeeper
            item.leftoverBundleID = candidate.leftoverBundleID
            item.scannedDirectoryFingerprint = candidate.scannedDirectoryFingerprint
            item.scannedChangeDate = candidate.scannedChangeDate
            return item
        }
        return DeletePlan(items: items, rulesVersion: RuleSet.currentVersion)
    }

    private static func valid(_ item: DeleteItem) -> Bool {
        guard PathGuard.allowsDeletion(path: item.originalPath), let identity = item.fileIdentity else { return false }
        var st = stat()
        guard lstat(item.originalPath, &st) == 0,
              UInt64(st.st_ino) == identity.inode, UInt64(UInt32(bitPattern: st.st_dev)) == identity.device else { return false }
        if (st.st_mode & S_IFMT) == S_IFREG && Int64(st.st_size) != item.logicalSize { return false }
        if (st.st_mode & S_IFMT) == S_IFDIR && item.ruleID == "uninstall.leftover" {
            guard let expected = item.scannedDirectoryFingerprint,
                  let actual = DirectoryFingerprint.capture(item.originalPath),
                  actual.digest == expected, actual.logicalBytes == item.logicalSize else { return false }
        }
        if let date = item.scannedModificationDate {
            let current = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
            if abs(date.timeIntervalSince1970 - current) > 0.000001 { return false }
        }
        if let date = item.scannedChangeDate {
            let current = Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) / 1_000_000_000
            if abs(date.timeIntervalSince1970 - current) > 0.000001 { return false }
        }
        return true
    }

    public static func dryRun(_ plan: DeletePlan) -> (valid: [DeleteItem], rejected: [DeleteItem]) {
        var accepted: [DeleteItem] = [], rejected: [DeleteItem] = []
        var volumeSensitivity: [UInt64: Bool] = [:]
        func sensitive(_ path: String, identity: FileIdentity?) -> Bool {
            if let device = identity?.device, let cached = volumeSensitivity[device] { return cached }
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            let value = values?.volumeSupportsCaseSensitiveNames ?? false
            if let device = identity?.device { volumeSensitivity[device] = value }
            return value
        }
        let paths = DeletionPathIndex(plan.items.map {
            DeletionPathIndex.Entry(path: $0.originalPath, caseSensitive: sensitive($0.originalPath, identity: $0.fileIdentity))
        })
        let overlaps = paths.overlappingIndices()
        for (index, item) in plan.items.enumerated() {
            let keeperSelected = item.duplicateKeeper.map { keeper in
                paths.hasSelectedAncestor(of: keeper.path, caseSensitive: sensitive(keeper.path, identity: keeper.identity))
            } ?? false
            let missingKeeper = item.ruleID == "duplicate.exact" && item.duplicateKeeper == nil
            if !overlaps.contains(index) && !keeperSelected && !missingKeeper && valid(item) {
                accepted.append(item)
            } else { rejected.append(item) }
        }
        return (accepted, rejected)
    }

    public static func execute(_ plan: DeletePlan, dryRun: Bool = false,
                               audit: AuditLog = .shared,
                               moveToTrash: (URL) throws -> URL? = { source in
                                   var result: NSURL?
                                   try FileManager.default.trashItem(at: source, resultingItemURL: &result)
                                   return result as URL?
                               },
                               onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> DeletionResult {
        guard audit.last?.pendingItem == nil else {
            throw NSError(domain: "Shulang", code: 1, userInfo: [NSLocalizedDescriptionKey: "上一次清理中断，仍有项目需要核查"])
        }
        let (accepted, rejected) = self.dryRun(plan)
        var failures = rejected.map { "路径或身份校验失败：\($0.originalPath)" }
        if dryRun {
            return DeletionResult(plan: plan, succeededCount: 0, failedCount: rejected.count,
                                  actuallyMovedBytes: 0, failures: failures, movedItems: [])
        }
        var moved: [DeleteItem] = []
        var movedBytes: Int64 = 0
        var pendingItem: DeleteItem?
        func result() -> DeletionResult {
            DeletionResult(plan: plan, succeededCount: moved.count, failedCount: failures.count,
                           actuallyMovedBytes: movedBytes, failures: failures, movedItems: moved,
                           pendingItem: pendingItem)
        }
        // 写前记录；无法写入时不移动任何文件。
        try audit.recordDurable(result())
        for (index, original) in accepted.enumerated() {
            var item = original
            guard valid(item) else {
                failures.append("执行前身份或内容变化，已跳过：\(item.originalPath)")
                try audit.recordDurable(result())
                continue
            }
            item.preDeleteChecksum = prefixChecksum(item.originalPath)
            pendingItem = item
            try audit.recordDurable(result())
            let duplicateValid: Bool
            if let keeper = item.duplicateKeeper {
                var st = stat()
                duplicateValid = lstat(keeper.path, &st) == 0 && UInt64(UInt32(bitPattern: st.st_dev)) == keeper.identity.device &&
                    UInt64(st.st_ino) == keeper.identity.inode &&
                    DuplicateEngine.fullHash(URL(fileURLWithPath: keeper.path)) == keeper.digest &&
                    DuplicateEngine.filesEqual(URL(fileURLWithPath: item.originalPath), URL(fileURLWithPath: keeper.path))
            } else { duplicateValid = item.ruleID != "duplicate.exact" }
            let hostInstalled: Bool
            if item.ruleID == "uninstall.leftover" {
                let installed = UninstallEngine.installedIdentifiers()
                let name = URL(fileURLWithPath: item.originalPath).lastPathComponent.lowercased()
                hostInstalled = item.leftoverBundleID.map { installed.bundleIDs.contains($0.lowercased()) } == true ||
                    installed.names.contains { UninstallEngine.nameMatches(entry: name, appName: $0) }
            } else { hostInstalled = false }
            guard duplicateValid, !hostInstalled, valid(item) else {
                pendingItem = nil
                failures.append("执行前身份或保留文件变化，已跳过：\(item.originalPath)")
                try audit.recordDurable(result())
                continue
            }
            let target: URL?
            do {
                target = try moveToTrash(URL(fileURLWithPath: item.originalPath))
            } catch {
                if valid(item) { pendingItem = nil }
                failures.append("移入废纸篓失败：\(item.originalPath) — \(error.localizedDescription)")
                for pending in accepted.dropFirst(index + 1) { failures.append("未执行：\(pending.originalPath)") }
                try audit.recordDurable(result())
                break
            }
            guard let target else {
                failures.append("移入废纸篓后无法确认位置：\(item.originalPath)")
                for pending in accepted.dropFirst(index + 1) { failures.append("未执行：\(pending.originalPath)") }
                try audit.recordDurable(result())
                break
            }
            item.trashPath = target.path
            pendingItem = nil
            moved.append(item)
            movedBytes += item.logicalSize
            // 记录失败必须向调用者报告，并阻止继续移动。
            try audit.recordDurable(result())
            onProgress(index + 1, accepted.count)
        }
        return result()
    }

    /// 仅在源文件仍在原处或废纸篓中存在唯一身份匹配时解决待处理项。
    @discardableResult
    public static func recoverInterrupted(audit: AuditLog = .shared,
        trashDirectory: (URL) throws -> URL = { original in
            try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                        appropriateFor: original.deletingLastPathComponent(), create: false)
        }) throws -> Bool {
        guard var result = audit.last, var item = result.pendingItem, let expected = item.fileIdentity else { return true }
        if valid(item) {
            result.pendingItem = nil
            try audit.recordDurable(result)
            return true
        }
        // 若原路径已被别的文件占用，保留待核查状态。
        var sourceStat = stat()
        guard lstat(item.originalPath, &sourceStat) != 0, errno == ENOENT else { return false }
        let directory = try trashDirectory(URL(fileURLWithPath: item.originalPath))
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let matches = entries.filter { url in
            var st = stat()
            guard lstat(url.path, &st) == 0, UInt64(UInt32(bitPattern: st.st_dev)) == expected.device,
                  UInt64(st.st_ino) == expected.inode else { return false }
            if let checksum = item.preDeleteChecksum { return prefixChecksum(url.path) == checksum }
            return true
        }
        guard matches.count == 1 else { return false }
        item.trashPath = matches[0].path
        var recovered = result.movedItems ?? []
        recovered.append(item)
        result = DeletionResult(plan: result.plan, succeededCount: result.succeededCount + 1,
                                failedCount: result.failedCount, actuallyMovedBytes: result.actuallyMovedBytes + item.logicalSize,
                                failures: result.failures, movedItems: recovered, pendingItem: nil, unverifiedItems: result.unverifiedItems)
        try audit.recordDurable(result)
        return true
    }

    /// Called only after the user has inspected the original location and Trash.
    public static func markInterruptedUnverified(audit: AuditLog = .shared) throws -> Bool {
        guard let current = audit.last, let item = current.pendingItem else { return false }
        let unresolved = (current.unverifiedItems ?? []) + [item]
        let updated = DeletionResult(plan: current.plan, succeededCount: current.succeededCount,
                                     failedCount: current.failedCount, actuallyMovedBytes: current.actuallyMovedBytes,
                                     failures: current.failures + ["用户已核查，状态无法验证：\(item.originalPath)"],
                                     movedItems: current.movedItems, pendingItem: nil, unverifiedItems: unresolved)
        try audit.recordDurable(updated)
        return true
    }

    @discardableResult
    public static func restoreLastCleanup(audit: AuditLog = .shared) throws -> Int {
        try restoreLastCleanupDetailed(audit: audit).restoredCount
    }

    public static func restoreLastCleanupDetailed(audit: AuditLog = .shared) throws -> RestoreResult {
        guard let result = audit.last else { return RestoreResult(items: []) }
        guard result.pendingItem == nil else {
            throw NSError(domain: "Shulang", code: 1, userInfo: [NSLocalizedDescriptionKey: "有中断的清理项目尚未定位，请先核查废纸篓"])
        }
        var outcomes: [RestoreItemOutcome] = []
        // 旧记录只有计划时不推测哪些项目实际成功。
        let recoverable = result.movedItems ?? []
        for item in recoverable {
            guard let trashPath = item.trashPath, let expected = item.fileIdentity else {
                outcomes.append(RestoreItemOutcome(path: item.originalPath, status: .failed, message: "缺少废纸篓位置或身份信息"))
                continue
            }
            var original = stat()
            if lstat(item.originalPath, &original) == 0 {
                let same = UInt64(UInt32(bitPattern: original.st_dev)) == expected.device && UInt64(original.st_ino) == expected.inode
                outcomes.append(RestoreItemOutcome(path: item.originalPath, status: same ? .alreadyRestored : .conflict,
                                                   message: same ? "原文件已在原位置" : "原位置已有其他文件，未覆盖"))
                continue
            }
            var st = stat()
            guard lstat(trashPath, &st) == 0, UInt64(st.st_ino) == expected.inode,
                  UInt64(UInt32(bitPattern: st.st_dev)) == expected.device else {
                outcomes.append(RestoreItemOutcome(path: item.originalPath, status: .failed, message: "废纸篓项目不存在或身份不符"))
                continue
            }
            if let checksum = item.preDeleteChecksum, prefixChecksum(trashPath) != checksum {
                outcomes.append(RestoreItemOutcome(path: item.originalPath, status: .failed, message: "废纸篓项目校验失败"))
                continue
            }
            do {
                try FileManager.default.moveItem(atPath: trashPath, toPath: item.originalPath)
                outcomes.append(RestoreItemOutcome(path: item.originalPath, status: .restored, message: "已恢复"))
            } catch {
                outcomes.append(RestoreItemOutcome(path: item.originalPath, status: .failed, message: error.localizedDescription))
            }
        }
        return RestoreResult(items: outcomes)
    }

}

// MARK: - 本地审计日志与扫描快照

public final class AuditLog: @unchecked Sendable {
    public static let shared = AuditLog()
    private let lock = NSLock()
    private var _records: [DeletionResult] = []
    private var _snapshots: [ScanReport] = []
    private var unreadableHistory = false
    public var last: DeletionResult? { lock.lock(); defer { lock.unlock() }; return _records.last }

    private let customDirectory: URL?
    private var directory: URL {
        if let customDirectory { return customDirectory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Shulang", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(directoryURL: URL? = nil) { self.customDirectory = directoryURL }

    public func recordDurable(_ result: DeletionResult) throws {
        lock.lock(); defer { lock.unlock() }
        guard !unreadableHistory else { throw CocoaError(.fileReadCorruptFile) }
        var records = _records
        if let index = records.firstIndex(where: { $0.plan.id == result.plan.id }) { records[index] = result }
        else { records.append(result) }
        let dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = Self.encodeHistory(reports: _snapshots, records: records) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: dir.appendingPathComponent("history.json"), options: .atomic)
        _records = records
    }

    public func record(_ result: DeletionResult) { try? recordDurable(result) }
    public func record(_ report: ScanReport) {
        lock.lock(); defer { lock.unlock() }
        guard !unreadableHistory else { return }
        _snapshots.append(report)
        if let data = Self.encodeHistory(reports: _snapshots, records: _records) {
            try? data.write(to: directory.appendingPathComponent("history.json"), options: .atomic)
        }
    }
    public var reports: [ScanReport] { lock.lock(); defer { lock.unlock() }; return _snapshots }
    public var history: [DeletionResult] { lock.lock(); defer { lock.unlock() }; return _records }

    /// 历史序列化抽成确定性纯函数，便于单测覆盖「重启后撤销栈仍在」（P0-A2）。
    static func encodeHistory(reports: [ScanReport], records: [DeletionResult]) -> Data? {
        // results 保存完整事务（含 trashPath 与校验和）；deletions 保留旧格式字段便于外部读取。
        let payload = HistoryPayload(formatVersion: 2, appVersion: ShulangVersion.current, reports: reports,
                                     deletions: records.map(\.plan),
                                     results: records)
        return try? JSONEncoder().encode(payload)
    }

    /// 反序列化时优先用完整事务；兼容 v1.0 只写 deletions 的历史文件。
    static func decodeHistory(_ data: Data) -> (reports: [ScanReport], records: [DeletionResult])? {
        guard let payload = try? JSONDecoder().decode(HistoryPayload.self, from: data) else { return nil }
        if let version = payload.formatVersion, version < 1 || version > 2 { return nil }
        let records: [DeletionResult]
        if let results = payload.results {
            records = results
        } else {
            records = payload.deletions.map { plan in
                DeletionResult(plan: plan, succeededCount: 0, failedCount: 0,
                               actuallyMovedBytes: 0, failures: ["旧版记录缺少逐项成功证据，无法验证或自动恢复"], movedItems: [])
            }
        }
        return (payload.reports, records)
    }

    private func persist() {
        let url = directory.appendingPathComponent("history.json")
        if let data = Self.encodeHistory(reports: reports, records: history) {
            try? data.write(to: url, options: .atomic)
        }
    }

    struct HistoryPayload: Codable {
        var formatVersion: Int? = nil
        var appVersion: String? = nil
        let reports: [ScanReport]
        let deletions: [DeletePlan]
        let results: [DeletionResult]?
    }

    public func loadIfNeeded() {
        let url = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let decoded = Self.decodeHistory(data) else {
            lock.lock(); unreadableHistory = true; lock.unlock()
            return
        }
        lock.lock()
        _snapshots = decoded.reports
        // P0-A2：恢复撤销栈，否则重启后 Shift+Cmd+Z 永远返回 0。
        _records = decoded.records
        lock.unlock()
    }
}

// MARK: - 报告导出（完全本地）

public enum Reporting {
    public static func markdown(report: ScanReport, candidates: [Candidate],
                                result: DeletionResult? = nil) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var lines: [String] = []
        lines.append("# 疏朗 · 空间分析报告")
        lines.append("")
        lines.append("- 生成时间：\(df.string(from: Date()))")
        lines.append("- 扫描范围：\(report.rootPath)")
        lines.append("- 规则版本：\(report.rulesVersion) · 枚举器：\(report.enumeratorName)")
        lines.append("- 扫描耗时：\(String(format: "%.2f", report.duration)) 秒")
        lines.append("- 条目数：\(report.totalNodes)（文件 \(report.totalFiles)）")
        lines.append("- 逻辑大小：\(ByteFormat.string(report.scannedLogicalBytes))")
        lines.append("- 已分配空间估算：\(ByteFormat.string(report.scannedAllocatedBytes))")
        lines.append("- 无法访问：\(report.inaccessibleCount) 处")
        lines.append("")
        lines.append("> 逻辑大小与已分配空间因 APFS 稀疏文件、克隆与硬链接而不同；逐文件已分配空间求和不代表唯一物理占用或可释放空间。")
        lines.append("")
        let summary = RiskEngine.summary(candidates)
        lines.append("## 候选概览")
        lines.append("")
        lines.append("| 风险等级 | 候选大小 | 条数 |")
        lines.append("|---|---:|---:|")
        for level in RiskLevel.allCases {
            let bytes = level == .safe ? summary.safe : level == .review ? summary.review : summary.caution
            let count = candidates.filter { $0.risk == level }.count
            lines.append("| \(level.title) | \(ByteFormat.string(bytes)) | \(count) |")
        }
        if let result {
            lines.append("")
            lines.append("## 清理事务")
            lines.append("")
            lines.append("- 计划字节：\(ByteFormat.string(result.plan.totalEstimatedBytes))")
            lines.append("- 实际移入废纸篓：\(ByteFormat.string(result.actuallyMovedBytes))（\(result.succeededCount) 项）")
            lines.append("- 失败：\(result.failedCount) 项")
            lines.append("- 恢复方式：Shift+Cmd+Z 或访达「放回原处」")
            lines.append("")
            lines.append("> 移入废纸篓后可用空间不会立即增加，需清空废纸篓。")
        }
        lines.append("")
        lines.append("## 候选项（按大小排序，最多 200 条）")
        lines.append("")
        lines.append("| 路径 | 大小 | 风险 | 规则 | 删除后果 |")
        lines.append("|---|---:|---|---|---|")
        for candidate in candidates.prefix(200) {
            let path = candidate.path.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| \(path) | \(ByteFormat.string(candidate.logicalSize)) | \(candidate.risk.title) | \(candidate.ruleID) | \(candidate.consequence) |")
        }
        if !report.errors.isEmpty {
            lines.append("")
            lines.append("## 扫描覆盖与限制")
            lines.append("")
            for error in report.errors { lines.append("- \(error)") }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func json(report: ScanReport, candidates: [Candidate]) throws -> Data {
        struct Payload: Codable {
            let report: ScanReport
            let candidates: [Candidate]
            let generatedAt: Date
            let note: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Payload(
            report: report, candidates: candidates, generatedAt: Date(),
            note: "candidate bytes are estimates, not immediately reclaimable space"
        ))
    }
}

// MARK: - 清理效果反馈（M4-07，自研）

public final class RegrowthTracker: @unchecked Sendable {
    public static let shared = RegrowthTracker()
    private let key = "shulang.regrowth.v1"

    public struct Record: Codable, Sendable {
        let ruleID: String
        let cleanedAt: Date
        let bytes: Int64
    }

    public func record(ruleID: String, bytes: Int64) {
        var all = load()
        all.append(Record(ruleID: ruleID, cleanedAt: Date(), bytes: bytes))
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 返回规则 id → 7 天内回长率（当前命中 / 上次清理）。
    public func regrowth(currentCandidates: [Candidate]) -> [String: Double] {
        let previous = load()
        guard !previous.isEmpty else { return [:] }
        var cleaned: [String: Int64] = [:]
        for record in previous { cleaned[record.ruleID, default: 0] += record.bytes }
        var current: [String: Int64] = [:]
        for candidate in currentCandidates { current[candidate.ruleID, default: 0] += candidate.logicalSize }
        var result: [String: Double] = [:]
        for (ruleID, bytes) in cleaned where bytes > 0 {
            result[ruleID] = Double(current[ruleID] ?? 0) / Double(bytes)
        }
        return result
    }

    private func load() -> [Record] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records
    }
}
