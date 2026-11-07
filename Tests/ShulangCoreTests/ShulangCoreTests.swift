import XCTest
import CoreServices
@testable import ShulangCore

final class ShulangCoreTests: XCTestCase {

    func testSingleInstanceLockPreventsConcurrentHistoryWriters() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: SingleInstanceLock? = try XCTUnwrap(SingleInstanceLock(directory: directory))
        XCTAssertNotNil(first)
        XCTAssertNil(SingleInstanceLock(directory: directory))
        first = nil
        XCTAssertNotNil(SingleInstanceLock(directory: directory))
    }

    // D8/D9：单位换算写成确定性纯函数并对边界值实测，避免假阳性/假阴性。
    func testCorruptHistoryCannotBeOverwrittenByCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let original = Data("broken history".utf8)
        try original.write(to: url)
        let audit = AuditLog(directoryURL: dir)
        audit.loadIfNeeded()
        let plan = DeletionEngine.buildPlan(from: [])
        let result = DeletionResult(plan: plan, succeededCount: 0, failedCount: 0, actuallyMovedBytes: 0, failures: [])
        XCTAssertThrowsError(try audit.recordDurable(result))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testByteFormatBoundaries() {
        XCTAssertEqual(ByteFormat.string(0), "0 B")
        XCTAssertEqual(ByteFormat.string(1023), "1023 B")
        XCTAssertEqual(ByteFormat.string(1024), "1.0 KB")
        XCTAssertEqual(ByteFormat.string(1536), "1.5 KB")
        XCTAssertEqual(ByteFormat.string(1024 * 1024), "1.0 MB")
        XCTAssertEqual(ByteFormat.string(-99), "0 B")
    }

    func testPathGuardRejectsSystemAndHomeRoots() {
        XCTAssertTrue(PathGuard.isProtected(path: "/"))
        XCTAssertTrue(PathGuard.isProtected(path: "/System/Library/Foo"))
        XCTAssertTrue(PathGuard.isProtected(path: NSHomeDirectory()))
        XCTAssertTrue(PathGuard.isProtected(path: NSHomeDirectory() + "/Library/Mail/V10"))
        XCTAssertTrue(PathGuard.isProtected(path: "/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertFalse(PathGuard.allowsDeletion(path: "/"))
        XCTAssertFalse(PathGuard.allowsDeletion(path: "/Volumes"))
    }

    func testPathGuardAllowsOrdinaryUserFile() {
        let path = NSHomeDirectory() + "/Downloads/old-installer.dmg"
        XCTAssertFalse(PathGuard.isProtected(path: path))
    }

    func testRuleSetImportRejectsInvalidInput() {
        XCTAssertThrowsError(try RuleSet.importJSON(Data("not json".utf8)))
        let empty = "{\"version\":\"\",\"rules\":[]}"
        XCTAssertThrowsError(try RuleSet.importJSON(Data(empty.utf8)))
        let duplicate = """
        {"version":"1.0.0","rules":[
          {"id":"a","title":"A","category":"caches","risk":"safe","pathPatterns":["*"],"minAgeDays":0,"minSizeBytes":0,"consequence":"x","rebuildable":true,"enabled":true,"isBuiltin":false},
          {"id":"a","title":"B","category":"logs","risk":"safe","pathPatterns":["*"],"minAgeDays":0,"minSizeBytes":0,"consequence":"x","rebuildable":true,"enabled":true,"isBuiltin":false}
        ]}
        """
        XCTAssertThrowsError(try RuleSet.importJSON(Data(duplicate.utf8)))
    }

    func testRuleSetRoundTrip() throws {
        let data = try RuleSet.builtin.exportJSON()
        let restored = try RuleSet.importJSON(data)
        XCTAssertEqual(restored.rules.count, RuleSet.builtin.rules.count)
        XCTAssertEqual(restored.version, RuleSet.currentVersion)
    }

    func testCategoryClassificationIsDeterministic() {
        let cache = CategoryEngine.classify(path: NSHomeDirectory() + "/Library/Caches/com.example/foo.bin", size: 100)
        XCTAssertEqual(cache.0, .caches)
        let developer = CategoryEngine.classify(path: NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData/A/Build/x", size: 100)
        XCTAssertEqual(developer.0, .developer)
        let protected = CategoryEngine.classify(path: "/System/Library/Caches/x", size: 100)
        XCTAssertEqual(protected.0, .protected)
    }

    func testRiskConfidenceRange() {
        let rule = RuleSet.builtin.rules.first!
        for age in [0, 30, 400] {
            for size: Int64 in [0, 1024, 1024 * 1024 * 1024] {
                let value = RiskEngine.confidence(for: rule, ageDays: age, size: size)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testTreemapCoversFullAreaWithoutOverlap() {
        let inputs = (0..<60).map { index in
            TreemapLayout.Input(nodeID: UUID(), weight: Int64(100 - index),
                                title: "item\(index)", category: .other)
        }
        let bounds = SLRect(x: 0, y: 0, width: 1, height: 1)
        let tiles = TreemapLayout.squarify(inputs, in: bounds)
        XCTAssertFalse(tiles.isEmpty)
        let covered = tiles.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
        XCTAssertEqual(covered, 1.0, accuracy: 0.02)
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.rect.x, -0.001)
            XCTAssertGreaterThanOrEqual(tile.rect.y, -0.001)
            XCTAssertLessThanOrEqual(tile.rect.x + tile.rect.width, 1.001)
            XCTAssertLessThanOrEqual(tile.rect.y + tile.rect.height, 1.001)
        }
    }

    func testTreemapClustersTinyItems() {
        let inputs = (0..<5000).map { _ in
            TreemapLayout.Input(nodeID: UUID(), weight: 1, title: "tiny", category: .other)
        }
        let tiles = TreemapLayout.squarify(inputs, in: SLRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThan(tiles.count, 500)
        XCTAssertTrue(tiles.contains { $0.isCluster })
    }

    func testScanDiffDetectsChanges() {
        func makeRoot(_ entries: [(String, Int64)]) -> ScanNode {
            let root = ScanNode(url: URL(fileURLWithPath: "/tmp/test"), name: "test", kind: .directory)
            for entry in entries {
                root.add(ScanNode(url: URL(fileURLWithPath: entry.0), name: (entry.0 as NSString).lastPathComponent,
                                  kind: .file, logicalSize: entry.1))
            }
            return root
        }
        let old = makeRoot([("/tmp/a", 100), ("/tmp/b", 200)])
        let new = makeRoot([("/tmp/a", 150), ("/tmp/c", 300)])
        let diff = DiffEngine.compare(old: old, new: new)
        XCTAssertTrue(diff.contains { $0.path == "/tmp/b" && $0.change == .deleted })
        XCTAssertTrue(diff.contains { $0.path == "/tmp/c" && $0.change == .added })
        XCTAssertTrue(diff.contains { $0.path == "/tmp/a" && $0.change == .grew && $0.deltaBytes == 50 })
    }

    func testDeletePlanRejectsProtectedPaths() {
        let candidates = [
            Candidate(nodeID: UUID(), path: "/System/Library/Caches/x", displayName: "x", ruleID: "cache.user",
                      evidence: "e", confidence: 0.9, risk: .safe, consequence: "c", rebuildable: true,
                      recoverable: true, logicalSize: 100, category: .caches),
            Candidate(nodeID: UUID(), path: NSHomeDirectory() + "/Downloads/old.dmg", displayName: "old.dmg",
                      ruleID: "download.old", evidence: "e", confidence: 0.9, risk: .safe,
                      consequence: "c", rebuildable: true, recoverable: true, logicalSize: 200, category: .downloads)
        ]
        let plan = DeletionEngine.buildPlan(from: candidates)
        XCTAssertTrue(plan.items.isEmpty, "缺少扫描身份的候选不得执行")
    }

    func testDryRunNeverWrites() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shulang-dryrun-\(UUID().uuidString)")
        try "keep".write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        var st = stat()
        lstat(temp.path, &st)
        let item = DeleteItem(originalPath: temp.path,
                              fileIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)),
                              logicalSize: 4, ruleID: "test")
        let plan = DeletePlan(items: [item], rulesVersion: RuleSet.currentVersion)
        let result = try DeletionEngine.execute(plan, dryRun: true)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))
    }

    func testEnumeratorFallsBackSafelyOnNonDirectory() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "shulang-not-a-dir-\(UUID().uuidString)")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let bulk = BulkEnumerator()
        let result = try? bulk.entries(at: file, includeHidden: false) { true }
        XCTAssertNil(result)
    }

    /// 证明批量枚举器走的是原生路径（返回非 nil），且解析出的元数据与真实文件一致，
    /// 而不是靠回落 Foundation 得到正确结果。
    func testBulkEnumeratorParsesRealDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shulang-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payloads = ["alpha.bin": 1024, "beta.bin": 4096, "gamma.bin": 8192]
        for (name, count) in payloads {
            try Data(repeating: 0x5A, count: count)
                .write(to: dir.appendingPathComponent(name))
        }
        let listing = try BulkEnumerator().entries(at: dir, includeHidden: false) { true }
        let entries = try XCTUnwrap(listing, "原生枚举器不应回落到 Foundation")
        XCTAssertEqual(entries.entries.count, payloads.count)
        XCTAssertEqual(Set(entries.entries.map(\.name)), Set(payloads.keys))
        for entry in entries.entries {
            XCTAssertEqual(entry.kind, .file)
            XCTAssertEqual(entry.logicalSize, Int64(payloads[entry.name]!))
            XCTAssertGreaterThanOrEqual(entry.allocatedSize, 0)
            XCTAssertNotNil(entry.identity)
            XCTAssertFalse(entry.url.path.contains(".."))
        }
    }

    /// 规则命中必须产出带证据、置信度与后果的候选项。
    func testRiskEngineProducesExplainableCandidates() throws {
        let root = ScanNode(url: URL(fileURLWithPath: "/tmp/scan"), name: "scan", kind: .directory)
        let path = NSHomeDirectory() + "/Library/Caches/com.example.shulang/entry.cache"
        root.add(ScanNode(url: URL(fileURLWithPath: path), name: "entry.cache", kind: .file,
                          logicalSize: 20_000, allocatedSize: 24_576,
                          modificationDate: Date().addingTimeInterval(-30 * 86_400)))
        let candidates = RiskEngine.makeCandidates(root: root)
        let hit = try XCTUnwrap(candidates.first(where: { $0.ruleID == "cache.user" }))
        XCTAssertEqual(hit.risk, .safe)
        XCTAssertTrue(hit.rebuildable)
        XCTAssertTrue(hit.recoverable)
        XCTAssertFalse(hit.evidence.isEmpty)
        XCTAssertFalse(hit.consequence.isEmpty)
        XCTAssertGreaterThan(hit.confidence, 0.5)
        XCTAssertLessThanOrEqual(hit.confidence, 1.0)
        XCTAssertEqual(hit.logicalSize, 20_000)
    }

    // MARK: - P0-A 回归测试

    /// P0-A1：废纸篓内容不得出现在任何候选中，也不得进入删除计划。
    func testTrashNeverProducesCleanupCandidate() {
        let path = NSHomeDirectory() + "/.Trash/old-installer.dmg"
        XCTAssertTrue(PathGuard.isProtected(path: path))
        XCTAssertFalse(PathGuard.allowsDeletion(path: path))
        XCTAssertTrue(RuleSet.builtin.rules.allSatisfy { !$0.pathPatterns.contains("*/.Trash/*") })

        let root = ScanNode(url: URL(fileURLWithPath: "/tmp/scan"), name: "scan", kind: .directory)
        let file = ScanNode(url: URL(fileURLWithPath: path), name: "old-installer.dmg",
                            kind: .file, logicalSize: 1024)
        file.isProtected = PathGuard.isProtected(file.url)
        root.add(file)
        XCTAssertTrue(RiskEngine.makeCandidates(root: root).isEmpty)

        let candidate = Candidate(nodeID: file.id, path: path, displayName: file.name,
                                  ruleID: "tmp.user", evidence: "test", confidence: 0.9,
                                  risk: .safe, consequence: "test", rebuildable: true,
                                  recoverable: true, logicalSize: 1024, category: .trash)
        XCTAssertTrue(DeletionEngine.buildPlan(from: [candidate]).items.isEmpty)
    }

    /// P0-A2：历史文件往返后撤销记录仍在，且保留废纸篁路径与校验和。
    func testUndoSurvivesRestart() throws {
        var item = DeleteItem(originalPath: "/tmp/shulang-undo/a.bin", fileIdentity: nil,
                              logicalSize: 10, ruleID: "test", volumeID: "1")
        item.trashPath = NSHomeDirectory() + "/.Trash/a.bin"
        item.preDeleteChecksum = "deadbeef"
        let plan = DeletePlan(items: [item], rulesVersion: RuleSet.currentVersion)
        let result = DeletionResult(plan: plan, succeededCount: 1, failedCount: 0,
                                    actuallyMovedBytes: 10, failures: [])
        let data = try XCTUnwrap(AuditLog.encodeHistory(reports: [], records: [result]))
        let decoded = try XCTUnwrap(AuditLog.decodeHistory(data))
        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.records.first?.plan.items.first?.trashPath, item.trashPath)
        XCTAssertEqual(decoded.records.first?.plan.items.first?.preDeleteChecksum, "deadbeef")
        XCTAssertEqual(decoded.records.first?.plan.items.first?.volumeID, "1")
    }

    /// P0-A2：v1.0 只写 deletions 的旧历史文件也要能恢复撤销记录。
    func testLegacyHistoryRestoresRecords() throws {
        let plan = DeletePlan(items: [DeleteItem(originalPath: "/tmp/legacy", fileIdentity: nil,
                                                 logicalSize: 5, ruleID: "test")],
                              rulesVersion: RuleSet.currentVersion)
        let planData = try JSONEncoder().encode(plan)
        let planJSON = try JSONSerialization.jsonObject(with: planData)
        let legacy: [String: Any] = ["reports": [], "deletions": [planJSON], "results": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try XCTUnwrap(AuditLog.decodeHistory(data))
        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.records.first?.plan.items.count, 1)
    }

    /// P0-A2：新增字段可在事务中序列化。
    func testDeleteItemCarriesChecksumAndVolume() throws {
        let item = DeleteItem(originalPath: "/tmp/a", fileIdentity: nil, logicalSize: 1,
                              ruleID: "x", preDeleteChecksum: "sum", volumeID: "42")
        let decoded = try JSONDecoder().decode(DeleteItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.volumeID, "42")
        XCTAssertEqual(decoded.preDeleteChecksum, "sum")
    }

    /// 卸载残留准确性：bundle id 提取与名称匹配必须可预期，避免把仍安装的应用误判为残留。
    func testLeftoverBundleIDExtraction() {
        XCTAssertEqual(UninstallEngine.bundleIdentifier(from: "com.example.app"), "com.example.app")
        XCTAssertEqual(UninstallEngine.bundleIdentifier(from: "com.example.app.savedState"), "com.example.app")
        XCTAssertEqual(UninstallEngine.bundleIdentifier(from: "com.example.app.plist"), "com.example.app")
        XCTAssertNil(UninstallEngine.bundleIdentifier(from: "Visual Studio Code"))
        XCTAssertNil(UninstallEngine.bundleIdentifier(from: "com.example"))
    }

    func testLeftoverNameMatchingAvoidsFalsePositives() {
        XCTAssertTrue(UninstallEngine.nameMatches(entry: "com.google.chrome", appName: "google chrome"))
        XCTAssertTrue(UninstallEngine.nameMatches(entry: "chrome", appName: "chrome"))
        XCTAssertFalse(UninstallEngine.nameMatches(entry: "com.example.other", appName: "chrome"))
        XCTAssertFalse(UninstallEngine.nameMatches(entry: "x", appName: "x"))
    }

    func testInstalledIdentifiersReadable() {
        let installed = UninstallEngine.installedIdentifiers()
        XCTAssertFalse(installed.bundleIDs.isEmpty, "应能从 /Applications 或 /System/Applications 读到 bundle id")
        XCTAssertFalse(installed.names.isEmpty)
        XCTAssertTrue(installed.bundleIDs.contains("com.apple.safari") || installed.names.contains("safari"))
    }

    func testLeftoverItemExposesConfidenceAndEvidence() {
        let item = LeftoverItem(path: "/tmp/x", displayName: "x", ownerHint: "com.example.x",
                                estimatedBytes: 10, reason: "关联目录仍在", bundleID: "com.example.x",
                                confidence: 0.85, evidence: "按 bundle id 反查未找到")
        XCTAssertEqual(item.confidence, 0.85, accuracy: 0.001)
        XCTAssertFalse(item.evidence.isEmpty)
        XCTAssertEqual(item.bundleID, "com.example.x")
    }

    /// 整卷扫描必须跨过 APFS 重复挂载视图与系统管理空间，否则 460 GB 卷会扫出 598 GB。
    func testScanSkipPolicyProtectsVolumeBoundaries() {
        XCTAssertTrue(ScanSkipPolicy.shouldSkip(path: "/System/Volumes/Data/Users/a", root: "/"))
        XCTAssertTrue(ScanSkipPolicy.shouldSkip(path: "/System/Volumes/Preboot/x", root: "/"))
        XCTAssertTrue(ScanSkipPolicy.shouldSkip(path: "/private/var/vm/sleepimage", root: "/"))
        XCTAssertTrue(ScanSkipPolicy.shouldSkip(path: "/Volumes/USB/x", root: "/"))
        XCTAssertTrue(ScanSkipPolicy.shouldSkip(path: "/.Spotlight-V100/x", root: "/Users"))
        // 用户数据与用户显式选择的卷根不能被跳过
        XCTAssertFalse(ScanSkipPolicy.shouldSkip(path: "/Users/me/Documents/a", root: "/"))
        XCTAssertFalse(ScanSkipPolicy.shouldSkip(path: "/System/Volumes/Data/Users/a", root: "/System/Volumes/Data"))
        XCTAssertFalse(ScanSkipPolicy.shouldSkip(path: "/Volumes/USB/photo.jpg", root: "/Volumes/USB"))
    }

    /// 聚合尺寸必须一次计算、读取恒定；子节点变化后需显式重算才更新。
    func testNodeAggregatesAreCached() {
        let root = ScanNode(url: URL(fileURLWithPath: "/tmp/r"), name: "r", kind: .directory)
        let a = ScanNode(url: URL(fileURLWithPath: "/tmp/r/a"), name: "a", kind: .file,
                         logicalSize: 100, allocatedSize: 120)
        let dir = ScanNode(url: URL(fileURLWithPath: "/tmp/r/d"), name: "d", kind: .directory)
        let b = ScanNode(url: URL(fileURLWithPath: "/tmp/r/d/b"), name: "b", kind: .file,
                         logicalSize: 50, allocatedSize: 60)
        dir.add(b); root.add(a); root.add(dir)
        root.recomputeAggregates()
        XCTAssertEqual(root.effectiveSize, 150)
        XCTAssertEqual(root.effectiveAllocatedSize, 180)
        XCTAssertEqual(root.fileCount, 2)
        XCTAssertEqual(dir.effectiveSize, 50)
        b.logicalSize = 999
        XCTAssertEqual(root.effectiveSize, 150, "未重算前应读缓存")
        root.recomputeAggregates()
        XCTAssertEqual(root.effectiveSize, 1099)
    }

    /// P0-A4：旧票据的定时任务不能清掉后发的新消息。
    func testToastCenterOldTicketCannotDismissNewMessage() {
        var center = ToastCenter()
        let first = center.issue()
        let second = center.issue()
        XCTAssertFalse(center.shouldDismiss(first), "旧票据不应清掉新消息")
        XCTAssertTrue(center.hasCurrent)
        XCTAssertTrue(center.shouldDismiss(second))
        XCTAssertFalse(center.hasCurrent)
        XCTAssertFalse(center.shouldDismiss(second), "重复清理应被拒绝")
    }
    func testImportedRulesCannotClaimBuiltinTrust() throws {
        let data = try RuleSet.builtin.exportJSON()
        let imported = try RuleSet.importJSON(data)
        XCTAssertTrue(imported.rules.allSatisfy { !$0.isBuiltin && $0.risk != .safe })
    }

    func testDurablePartialCleanupCanBeRestoredAfterRestart() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-txn-\(UUID().uuidString)")
        let trash = dir.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first")
        let second = dir.appendingPathComponent("second")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        func candidate(_ url: URL) -> Candidate {
            var st = stat(); lstat(url.path, &st)
            return Candidate(nodeID: UUID(), path: url.path, displayName: url.lastPathComponent,
                             ruleID: "test", evidence: "fixture", confidence: 0, risk: .review,
                             consequence: "test", rebuildable: false, recoverable: true,
                             logicalSize: Int64(st.st_size), category: .other,
                             scannedIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)))
        }
        let plan = DeletionEngine.buildPlan(from: [candidate(first), candidate(second)])
        XCTAssertEqual(plan.items.count, 2)
        let log = AuditLog(directoryURL: dir.appendingPathComponent("audit"))
        let result = try DeletionEngine.execute(plan, audit: log, moveToTrash: { source in
            if source.lastPathComponent == "second" { throw CocoaError(.fileWriteNoPermission) }
            let target = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        })
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let reopened = AuditLog(directoryURL: dir.appendingPathComponent("audit"))
        reopened.loadIfNeeded()
        XCTAssertEqual(try DeletionEngine.restoreLastCleanup(audit: reopened), 1)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
    }

    func testChangedFileRejectedBeforeMove() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-change-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file")
        try Data("original".utf8).write(to: file)
        var st = stat(); lstat(file.path, &st)
        let item = DeleteItem(originalPath: file.path, fileIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)), logicalSize: Int64(st.st_size), ruleID: "test")
        let plan = DeletePlan(items: [item], rulesVersion: RuleSet.currentVersion)
        try Data("changed length".utf8).write(to: file)
        let result = try DeletionEngine.execute(plan, dryRun: true)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testScanCountsAppBundleWithBothEnumerators() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-package-\(UUID().uuidString)")
        let contents = dir.appendingPathComponent("Demo.app/Contents/Resources")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 8192).write(to: contents.appendingPathComponent("data"))
        for kind in [EnumeratorKind.foundation, .bulk] {
            var limits = ScanLimits(); limits.enumerator = kind
            let result = try await ScanEngine().scan(url: dir, limits: limits) { _ in }
            XCTAssertEqual(result.report.scannedLogicalBytes, 8192)
            XCTAssertTrue(RiskEngine.makeCandidates(root: result.root).isEmpty)
        }
    }

    func testFailedJournalPreventsAnyMove() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file")
        let notDirectory = dir.appendingPathComponent("not-directory")
        try Data("keep".utf8).write(to: file)
        try Data("x".utf8).write(to: notDirectory)
        var st = stat(); lstat(file.path, &st)
        let item = DeleteItem(originalPath: file.path, fileIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)), logicalSize: Int64(st.st_size), ruleID: "test")
        let plan = DeletePlan(items: [item], rulesVersion: RuleSet.currentVersion)
        var moved = false
        XCTAssertThrowsError(try DeletionEngine.execute(plan, audit: AuditLog(directoryURL: notDirectory), moveToTrash: { url in moved = true; return url }))
        XCTAssertFalse(moved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testGuardRejectsPathTraversalAndCaseVariants() {
        XCTAssertFalse(PathGuard.allowsDeletion(path: NSHomeDirectory() + "/Downloads/../../System/Library/file"))
        XCTAssertTrue(PathGuard.isProtected(path: "/SYSTEM/Library/file"))
        XCTAssertTrue(PathGuard.isProtected(path: NSHomeDirectory() + "/.TRASH/file"))
    }

    func testInterruptedMoveRecoveredByIdentityAfterRestart() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-recovery-\(UUID().uuidString)")
        let trash = dir.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original"), moved = trash.appendingPathComponent("renamed")
        try Data("payload".utf8).write(to: original)
        var st = stat(); XCTAssertEqual(lstat(original.path, &st), 0)
        let item = DeleteItem(originalPath: original.path, fileIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)), logicalSize: Int64(st.st_size), ruleID: "test")
        let plan = DeletePlan(items: [item], rulesVersion: RuleSet.currentVersion)
        let log = AuditLog(directoryURL: dir.appendingPathComponent("audit"))
        try log.recordDurable(DeletionResult(plan: plan, succeededCount: 0, failedCount: 0, actuallyMovedBytes: 0, failures: [], movedItems: [], pendingItem: item))
        try FileManager.default.moveItem(at: original, to: moved)
        let restarted = AuditLog(directoryURL: dir.appendingPathComponent("audit")); restarted.loadIfNeeded()
        XCTAssertTrue(try DeletionEngine.recoverInterrupted(audit: restarted, trashDirectory: { _ in trash }))
        XCTAssertNil(restarted.last?.pendingItem)
        XCTAssertEqual(restarted.last?.movedItems?.first?.trashPath, moved.path)
        XCTAssertEqual(try DeletionEngine.restoreLastCleanup(audit: restarted), 1)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "payload")
    }

    func testInterruptedMoveWithoutMatchingFileRemainsPending() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = DeleteItem(originalPath: dir.appendingPathComponent("missing").path, fileIdentity: FileIdentity(device: 1, inode: 42), logicalSize: 1, ruleID: "test")
        let plan = DeletePlan(items: [item], rulesVersion: RuleSet.currentVersion)
        let log = AuditLog(directoryURL: dir.appendingPathComponent("audit"))
        try log.recordDurable(DeletionResult(plan: plan, succeededCount: 0, failedCount: 0, actuallyMovedBytes: 0, failures: [], movedItems: [], pendingItem: item))
        XCTAssertFalse(try DeletionEngine.recoverInterrupted(audit: log, trashDirectory: { _ in dir }))
        XCTAssertNotNil(log.last?.pendingItem)
    }

    func testDuplicateKeeperSelectedOrChangedPreventsMove() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-duplicate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keeper = dir.appendingPathComponent("keeper"), copy = dir.appendingPathComponent("copy")
        try Data("equal data".utf8).write(to: keeper); try Data("equal data".utf8).write(to: copy)
        func ident(_ url: URL) -> FileIdentity { var st = stat(); lstat(url.path, &st); return FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)) }
        let digest = try XCTUnwrap(DuplicateEngine.fullHash(keeper))
        var duplicate = DeleteItem(originalPath: copy.path, fileIdentity: ident(copy), logicalSize: 10, ruleID: "duplicate.exact")
        duplicate.duplicateKeeper = DuplicateKeeper(path: keeper.path, identity: ident(keeper), digest: digest)
        let keepItem = DeleteItem(originalPath: keeper.path, fileIdentity: ident(keeper), logicalSize: 10, ruleID: "test")
        XCTAssertEqual(DeletionEngine.dryRun(DeletePlan(items: [duplicate, keepItem], rulesVersion: "1")).rejected.count, 1)
        try Data("different!".utf8).write(to: keeper)
        let audit = AuditLog(directoryURL: dir.appendingPathComponent("audit"))
        var called = false
        let result = try DeletionEngine.execute(DeletePlan(items: [duplicate], rulesVersion: "1"), audit: audit, moveToTrash: { url in called = true; return url })
        XCTAssertFalse(called); XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testSystemTrashRoundTripWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["SHULANG_SYSTEM_TRASH_TEST"] == "1" else {
            throw XCTSkip("Set SHULANG_SYSTEM_TRASH_TEST=1 to test only a generated file in the system trash")
        }
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-real-trash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shulang-test-" + UUID().uuidString + ".txt")
        try Data("recover this generated test file".utf8).write(to: file)
        var st = stat(); XCTAssertEqual(lstat(file.path, &st), 0)
        let item = DeleteItem(originalPath: file.path, fileIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)), logicalSize: Int64(st.st_size), ruleID: "test")
        let auditURL = dir.appendingPathComponent("audit")
        let result = try DeletionEngine.execute(DeletePlan(items: [item], rulesVersion: "test"), audit: AuditLog(directoryURL: auditURL))
        XCTAssertEqual(result.succeededCount, 1, result.failures.joined(separator: "\n"))
        let restarted = AuditLog(directoryURL: auditURL)
        restarted.loadIfNeeded()
        XCTAssertEqual(try DeletionEngine.restoreLastCleanup(audit: restarted), 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "recover this generated test file")
    }

    func testCancellationReturnsReadOnlyPartialTree() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<2100 {
            try Data([1]).write(to: dir.appendingPathComponent("file-\(index)"))
        }
        let engine = ScanEngine()
        let outcome = try await engine.scan(url: dir) { progress in
            if progress.scannedItems >= 2000 { engine.cancel() }
        }
        XCTAssertEqual(outcome.report.completionStatus, "cancelled")
        XCTAssertEqual(outcome.report.totalFiles, 2000)
        XCTAssertEqual(outcome.report.scannedLogicalBytes, 2000)
        XCTAssertLessThan(outcome.report.totalFiles, 2100)
    }

    func testScanReportsDepthTruncation() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-depth-" + UUID().uuidString)
        let child = dir.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: child.appendingPathComponent("file"))
        var limits = ScanLimits(); limits.maxDepth = 1
        let outcome = try await ScanEngine().scan(url: dir, limits: limits) { _ in }
        XCTAssertEqual(outcome.report.completionStatus, "partial")
        XCTAssertEqual(outcome.report.truncatedPaths?.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, [child.resolvingSymlinksInPath().path])
        XCTAssertEqual(outcome.report.scannedLogicalBytes, 0)
        let decoded = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(outcome.report))
        XCTAssertEqual(decoded.truncatedPaths, outcome.report.truncatedPaths)
    }

    func testDuplicateContentComparisonAndCancellation() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-compare-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        let prefix = Data(repeating: 0x41, count: 4096)
        try (prefix + Data([1])).write(to: a)
        try (prefix + Data([2])).write(to: b)
        XCTAssertEqual(DuplicateEngine.partialHash(a), DuplicateEngine.partialHash(b))
        XCTAssertFalse(DuplicateEngine.filesEqual(a, b))
        XCTAssertNil(DuplicateEngine.fullHash(a, shouldContinue: { false }))
        XCTAssertFalse(DuplicateEngine.filesEqual(a, a, shouldContinue: { false }))
        var changed = false
        XCTAssertFalse(DuplicateEngine.filesEqual(a, a, shouldContinue: {
            if !changed {
                changed = true
                try? Data(repeating: 0x42, count: 4097).write(to: a)
            }
            return true
        }))
    }

    func testSunburstUsesSelectedSizeBasis() throws {
        let root = ScanNode(url: URL(fileURLWithPath: "/fixture"), kind: .directory)
        let first = ScanNode(url: URL(fileURLWithPath: "/fixture/a"), kind: .file, logicalSize: 900, allocatedSize: 100)
        let second = ScanNode(url: URL(fileURLWithPath: "/fixture/b"), kind: .file, logicalSize: 100, allocatedSize: 900)
        root.add(first); root.add(second); root.recomputeAggregates()
        let logical = try XCTUnwrap(SunburstLayout.arcs(root: root).first { $0.nodeID == first.id })
        let allocated = try XCTUnwrap(SunburstLayout.arcs(root: root, allocated: true).first { $0.nodeID == first.id })
        XCTAssertEqual(logical.endAngle - logical.startAngle, 1.8 * .pi, accuracy: 0.0001)
        XCTAssertEqual(allocated.endAngle - allocated.startAngle, 0.2 * .pi, accuracy: 0.0001)
        let report = ScanReport(startedAt: Date(), duration: 0, rootPath: root.url.path,
                                totalNodes: 2, totalFiles: 2, scannedLogicalBytes: 1000,
                                scannedAllocatedBytes: 1000, inaccessibleCount: 0, errors: [],
                                rulesVersion: "test", enumeratorName: "test")
        let snapshot = ScanSnapshot(outcome: ScanOutcome(root: root, report: report))
        let snapshotLogical = try XCTUnwrap(SunburstLayout.arcs(snapshot: snapshot, rootID: root.id)?.first)
        let snapshotAllocated = try XCTUnwrap(SunburstLayout.arcs(snapshot: snapshot, rootID: root.id, allocated: true)?.first)
        XCTAssertEqual(snapshotLogical.endAngle, logical.endAngle, accuracy: 0.0001)
        XCTAssertEqual(snapshotAllocated.endAngle, allocated.endAngle, accuracy: 0.0001)
        XCTAssertNil(SunburstLayout.arcs(snapshot: snapshot, rootID: UUID()))
        let logicalInputs = try XCTUnwrap(TreemapLayout.inputs(snapshot: snapshot, rootID: root.id))
        let allocatedInputs = try XCTUnwrap(TreemapLayout.inputs(snapshot: snapshot, rootID: root.id, allocated: true))
        XCTAssertEqual(logicalInputs.first { $0.nodeID == first.id }?.weight, 900)
        XCTAssertEqual(allocatedInputs.first { $0.nodeID == first.id }?.weight, 100)
        XCTAssertNil(TreemapLayout.inputs(snapshot: snapshot, rootID: UUID()))
    }

    func testDiffRecognizesUnambiguousRenameOnly() {
        let identity = FileIdentity(device: 1, inode: 2)
        func root(_ names: [String]) -> ScanNode {
            let root = ScanNode(url: URL(fileURLWithPath: "/fixture"), kind: .directory)
            for name in names { root.add(ScanNode(url: URL(fileURLWithPath: "/fixture/" + name), kind: .file, logicalSize: 5, identity: identity)) }
            return root
        }
        let renamed = DiffEngine.compare(old: root(["old"]), new: root(["new"]))
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed.first?.change, .renamed)
        XCTAssertEqual(renamed.first?.oldPath, "/fixture/old")
        XCTAssertEqual(renamed.first?.path, "/fixture/new")
        let ambiguous = DiffEngine.compare(old: root(["a", "b"]), new: root(["c", "d"]))
        XCTAssertEqual(ambiguous.filter { $0.change == .renamed }.count, 0)
        XCTAssertEqual(ambiguous.count, 4)
    }

    func testSpecificCacheRulesTakePrecedenceOverGeneric() {
        let root = ScanNode(url: URL(fileURLWithPath: "/Users/example"), kind: .directory)
        for path in ["/Users/example/Library/Caches/Firefox/a", "/Users/example/Library/Caches/Homebrew/b", "/Users/example/Library/Caches/Other/c"] {
            root.add(ScanNode(url: URL(fileURLWithPath: path), kind: .file, logicalSize: 1))
        }
        let candidates = RiskEngine.makeCandidates(root: root)
        XCTAssertEqual(candidates.first { $0.path.hasSuffix("Firefox/a") }?.ruleID, "cache.browser")
        XCTAssertEqual(candidates.first { $0.path.hasSuffix("Homebrew/b") }?.ruleID, "dev.brew")
        XCTAssertEqual(candidates.first { $0.path.hasSuffix("Other/c") }?.ruleID, "cache.user")
    }

    func testOldScanReportWithoutCoverageFieldsDecodes() throws {
        let report = ScanReport(startedAt: Date(), duration: 1, rootPath: "/fixture", totalNodes: 0, totalFiles: 0, scannedLogicalBytes: 0, scannedAllocatedBytes: 0, inaccessibleCount: 0, errors: [], rulesVersion: "1", enumeratorName: "foundation")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        for key in ["completionStatus", "excludedPaths", "truncatedPaths", "includeHidden", "fallbackCount"] { object.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(ScanReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.rootPath, "/fixture")
        XCTAssertNil(restored.completionStatus)
    }

    func testDuplicateGroupingRejectsMatchingPrefixWithDifferentTail() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-groups-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = Data(repeating: 0x41, count: 4096)
        for (name, suffix): (String, UInt8) in [("a", 1), ("b", 1), ("c", 2)] {
            try (prefix + Data([suffix])).write(to: dir.appendingPathComponent(name))
        }
        let outcome = try await ScanEngine().scan(url: dir) { _ in }
        let groups = DuplicateEngine.find(root: outcome.root)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].candidates.map { $0.url.lastPathComponent }), Set(["a", "b"]))
        XCTAssertTrue(DuplicateEngine.find(root: outcome.root, shouldContinue: { false }).isEmpty)
    }

    func testSnapshotRoundTripAndDiffAfterRename() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("old"), renamed = dir.appendingPathComponent("new")
        try Data("snapshot".utf8).write(to: original)
        let first = try await ScanEngine().scan(url: dir) { _ in }
        let snapshot = ScanSnapshot(outcome: first)
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.sessionID, snapshot.sessionID)
        XCTAssertEqual(decoded.nodes.count, 2)
        try FileManager.default.moveItem(at: original, to: renamed)
        let second = try await ScanEngine().scan(url: dir) { _ in }
        XCTAssertTrue(decoded.canCompare(to: ScanSnapshot(outcome: second)))
        var differentLimits = ScanLimits()
        differentLimits.maxDepth = 2
        let limited = try await ScanEngine().scan(url: dir, limits: differentLimits) { _ in }
        XCTAssertFalse(decoded.canCompare(to: ScanSnapshot(outcome: limited)))
        let changes = DiffEngine.compare(old: decoded, new: ScanSnapshot(outcome: second))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.change, .renamed)
        XCTAssertEqual(changes.first?.path, second.root.flattenedFiles().first?.url.path)
    }

    func testSnapshotDiffAllowsSameExplicitExclusionsButRejectsDifferentCoverage() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-diff-coverage-" + UUID().uuidString)
        let excluded = dir.appendingPathComponent("Library/CloudStorage")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = ScanSnapshot(outcome: try await ScanEngine().scan(url: dir) { _ in })
        let second = ScanSnapshot(outcome: try await ScanEngine().scan(url: dir) { _ in })
        XCTAssertEqual(first.report.completionStatus, "partial")
        XCTAssertTrue(first.canCompare(to: second))
        try FileManager.default.removeItem(at: excluded)
        let third = ScanSnapshot(outcome: try await ScanEngine().scan(url: dir) { _ in })
        XCTAssertFalse(first.canCompare(to: third))
    }

    func testSnapshotStoreSurvivesReopenAndKeepsInvalidations() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: input.appendingPathComponent("file"))
        let outcome = try await ScanEngine().scan(url: input) { _ in }
        let first = ScanSnapshot(outcome: outcome)
        let second = ScanSnapshot(outcome: outcome, sessionID: first.sessionID, revision: 2)
        let db = dir.appendingPathComponent("snapshots.sqlite")
        do {
            let store = try SnapshotStore(url: db)
            try store.save(first)
            XCTAssertThrowsError(try store.save(first))
            try store.markInvalidated(sessionID: first.sessionID, path: input.path)
            try store.markInvalidated(sessionID: first.sessionID, path: input.path)
            let batch = try store.pendingInvalidations(sessionID: first.sessionID)
            try store.markInvalidated(sessionID: first.sessionID, path: input.path)
            try store.commit(second, acknowledging: batch)
            let remaining = try store.pendingInvalidations(sessionID: first.sessionID)
            XCTAssertEqual(remaining.paths, [input.path])
            XCTAssertGreaterThan(remaining.through, batch.through)
            XCTAssertThrowsError(try store.commit(second, acknowledging: remaining))
            XCTAssertEqual(try store.pendingInvalidations(sessionID: first.sessionID).through, remaining.through)
        }
        let reopened = try SnapshotStore(url: db)
        XCTAssertEqual(try reopened.load(sessionID: first.sessionID, revision: 1)?.nodes.count, first.nodes.count)
        XCTAssertEqual(try reopened.load(sessionID: first.sessionID, revision: 2)?.revision, 2)
        XCTAssertNil(try reopened.load(sessionID: first.sessionID, revision: 3))
        XCTAssertEqual(try reopened.invalidatedPaths(sessionID: first.sessionID), [input.path])
    }

    func testInvalidationFallsBackOnLostEventsAndForeignPaths() {
        let root = URL(fileURLWithPath: "/Users/example/folder")
        XCTAssertEqual(InvalidationPlanner.decide(root: root, events: [(root.path + "/a", 0), (root.path + "/a/sub", 0)]), .directories([root.path + "/a", root.path + "/a/sub"]))
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagUnmount] {
            XCTAssertEqual(InvalidationPlanner.decide(root: root, events: [(root.path, UInt32(flag))]), .fullRescan)
        }
        XCTAssertEqual(InvalidationPlanner.decide(root: root, events: [("/Users/example/folder-other", 0)]), .fullRescan)
    }

    func testDirectoryEventsObserveGeneratedFileWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SHULANG_FSEVENT_TEST"] == "1" else {
            throw XCTSkip("Set SHULANG_FSEVENT_TEST=1 to run the FSEvents integration test")
        }
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-events-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watched = dir.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        let store = try SnapshotStore(url: dir.appendingPathComponent("snapshots.sqlite"))
        let session = UUID()
        let received = expectation(description: "durable change event")
        received.assertForOverFulfill = false
        let monitor = try SnapshotInvalidationTracker(root: watched.resolvingSymlinksInPath(), sessionID: session, store: store, onUpdate: { decision in
            switch decision {
            case .fullRescan: received.fulfill()
            case .directories(let paths): if !paths.isEmpty { received.fulfill() }
            }
        }, onFailure: { _ in })
        try Data("test".utf8).write(to: watched.appendingPathComponent("generated"))
        await monitor.flush()
        await fulfillment(of: [received], timeout: 10)
        XCTAssertFalse(try store.invalidatedPaths(sessionID: session).isEmpty)
        withExtendedLifetime(monitor) {}
    }

    func testApplicationInventoryFindsNestedTools() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-apps-" + UUID().uuidString)
        let app = dir.appendingPathComponent("Tools/Nested/Example.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.example.demo"], format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertTrue(UninstallEngine.applicationRoots(custom: [dir.path]).contains(dir.path))
        let apps = UninstallEngine.installedApplications(roots: [dir.path, dir.appendingPathComponent("Tools").path])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.name, "Example")
        XCTAssertEqual(apps.first?.bundleID, "org.example.demo")
        XCTAssertEqual(apps.first?.isSystem, false)
        XCTAssertTrue(UninstallEngine.installedIdentifiers(roots: [dir.path]).bundleIDs.contains("org.example.demo"))
    }

    func testSnapshotSubtreeFilesExcludeSiblings() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-subtree-" + UUID().uuidString)
        let selected = dir.appendingPathComponent("selected/nested")
        let sibling = dir.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: selected.appendingPathComponent("inside"))
        try Data([2]).write(to: sibling.appendingPathComponent("outside"))
        let outcome = try await ScanEngine().scan(url: dir) { _ in }
        let selectedNode = try XCTUnwrap(outcome.root.children.first { $0.name == "selected" })
        let snapshot = ScanSnapshot(outcome: outcome)
        XCTAssertEqual(snapshot.files(in: selectedNode.id).map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["inside"])
        XCTAssertEqual(snapshot.files(in: outcome.root.id).count, 2)
        XCTAssertTrue(snapshot.files(in: UUID()).isEmpty)
    }

    func testHistoryHasVersionAndRejectsUnknownFutureFormat() throws {
        let data = try XCTUnwrap(AuditLog.encodeHistory(reports: [], records: []))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        XCTAssertEqual(object["appVersion"] as? String, ShulangVersion.current)
        object["formatVersion"] = 99
        XCTAssertNil(AuditLog.decodeHistory(try JSONSerialization.data(withJSONObject: object)))
    }

    func testIncrementalScanMatchesFullAndFallsBackSafely() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-incremental-" + UUID().uuidString)
        let changed = dir.appendingPathComponent("changed"), untouched = dir.appendingPathComponent("untouched")
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untouched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 100).write(to: changed.appendingPathComponent("old"))
        try Data(repeating: 2, count: 200).write(to: untouched.appendingPathComponent("keep"))
        let limits = ScanLimits()
        let before = try await ScanEngine().scan(url: dir, limits: limits) { _ in }
        let snapshot = ScanSnapshot(outcome: before)
        try FileManager.default.removeItem(at: changed.appendingPathComponent("old"))
        try Data(repeating: 3, count: 300).write(to: changed.appendingPathComponent("new"))
        let update = try await IncrementalScanner.rescan(snapshot: snapshot, changedDirectories: [changed.path], limits: limits)
        XCTAssertFalse(update.usedFullScan, update.fallbackReason ?? "unexpected full scan")
        let full = try await ScanEngine().scan(url: dir, limits: limits) { _ in }
        func files(_ root: ScanNode) -> [String: Int64] {
            Dictionary(uniqueKeysWithValues: root.flattenedFiles().map { ($0.url.resolvingSymlinksInPath().path, $0.logicalSize) })
        }
        XCTAssertEqual(files(update.outcome.root), files(full.root))
        XCTAssertEqual(update.outcome.report.scannedLogicalBytes, full.report.scannedLogicalBytes)
        XCTAssertEqual(update.outcome.report.scannedAllocatedBytes, full.report.scannedAllocatedBytes)
        let fallback = try await IncrementalScanner.rescan(snapshot: snapshot, changedDirectories: [dir.path], limits: limits)
        XCTAssertTrue(fallback.usedFullScan)
        XCTAssertEqual(files(fallback.outcome.root), files(full.root))
    }

    func testIncrementalScanFallsBackForHardlinks() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-hardlink-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first")
        try Data("data".utf8).write(to: first)
        try FileManager.default.linkItem(at: first, to: dir.appendingPathComponent("second"))
        let outcome = try await ScanEngine().scan(url: dir) { _ in }
        let result = try await IncrementalScanner.rescan(snapshot: ScanSnapshot(outcome: outcome), changedDirectories: [], limits: ScanLimits())
        XCTAssertTrue(result.usedFullScan)
        XCTAssertTrue(result.fallbackReason?.contains("硬链接") == true)
    }

    func testEventDrivenUpdateMatchesFullScanWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["SHULANG_FSEVENT_TEST"] == "1" else {
            throw XCTSkip("Set SHULANG_FSEVENT_TEST=1 to run the FSEvents integration test")
        }
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-event-update-" + UUID().uuidString)
        let root = dir.appendingPathComponent("watched"), changed = root.appendingPathComponent("changed")
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = changed.appendingPathComponent("file")
        try Data("before".utf8).write(to: file)
        let store = try SnapshotStore(url: dir.appendingPathComponent("snapshots.sqlite"))
        let session = UUID()
        let event = expectation(description: "filesystem event persisted")
        event.assertForOverFulfill = false
        let tracker = try SnapshotInvalidationTracker(root: root.resolvingSymlinksInPath(), sessionID: session, store: store,
                                                       onUpdate: { _ in event.fulfill() }, onFailure: { _ in })
        let baseline = try await ScanEngine().scan(url: root) { _ in }
        let snapshot = ScanSnapshot(outcome: baseline, sessionID: session)
        try store.save(snapshot)
        try Data("a longer replacement".utf8).write(to: file)
        await fulfillment(of: [event], timeout: 10)
        await tracker.flush()
        XCTAssertTrue(tracker.isReliable)
        let batch = try store.pendingInvalidations(sessionID: session)
        XCTAssertFalse(batch.paths.isEmpty)
        let updated = try await IncrementalScanner.rescan(snapshot: snapshot, changedDirectories: batch.paths, limits: ScanLimits())
        await tracker.flush()
        let revision = ScanSnapshot(outcome: updated.outcome, sessionID: session, revision: 2)
        try store.commit(revision, acknowledging: batch)
        let full = try await ScanEngine().scan(url: root) { _ in }
        XCTAssertEqual(updated.outcome.report.scannedLogicalBytes, full.report.scannedLogicalBytes)
        XCTAssertEqual(updated.outcome.report.scannedAllocatedBytes, full.report.scannedAllocatedBytes)
        XCTAssertEqual(updated.outcome.root.flattenedFiles().map(\.logicalSize), full.root.flattenedFiles().map(\.logicalSize))
        XCTAssertNotNil(try store.load(sessionID: session, revision: 2))
        withExtendedLifetime(tracker) {}
    }

    func testChangedNestedLeftoverDirectoryIsRejected() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-leftover-" + UUID().uuidString)
        let candidateDir = dir.appendingPathComponent("candidate"), nested = candidateDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = nested.appendingPathComponent(".hidden")
        try Data("one".utf8).write(to: file)
        let capture = try XCTUnwrap(DirectoryFingerprint.capture(candidateDir.path))
        var st = stat(); XCTAssertEqual(lstat(candidateDir.path, &st), 0)
        let identity = FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
        let modification = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        let candidate = Candidate(nodeID: UUID(), path: candidateDir.path, displayName: "candidate", ruleID: "uninstall.leftover", evidence: "test", confidence: 0, risk: .review, consequence: "test", rebuildable: false, recoverable: true, logicalSize: capture.logicalBytes, category: .applications, scannedIdentity: identity, scannedModificationDate: modification, scannedDirectoryFingerprint: capture.digest)
        let plan = DeletionEngine.buildPlan(from: [candidate])
        XCTAssertEqual(DeletionEngine.dryRun(plan).valid.count, 1)
        try Data("two".utf8).write(to: file)
        XCTAssertEqual(DeletionEngine.dryRun(plan).rejected.count, 1)
        var moved = false
        let result = try DeletionEngine.execute(plan, audit: AuditLog(directoryURL: dir.appendingPathComponent("audit")), moveToTrash: { url in moved = true; return url })
        XCTAssertFalse(moved)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRewrittenFileWithRestoredModificationTimeIsRejected() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-ctime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file")
        try Data("aaa".utf8).write(to: file)
        var before = stat(); XCTAssertEqual(lstat(file.path, &before), 0)
        func date(_ time: timespec) -> Date { Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000) }
        let candidate = Candidate(nodeID: UUID(), path: file.path, displayName: "file", ruleID: "test", evidence: "test", confidence: 0, risk: .review, consequence: "test", rebuildable: false, recoverable: true, logicalSize: 3, category: .other, scannedIdentity: FileIdentity(device: UInt64(before.st_dev), inode: UInt64(before.st_ino)), scannedModificationDate: date(before.st_mtimespec), scannedChangeDate: date(before.st_ctimespec))
        let plan = DeletionEngine.buildPlan(from: [candidate])
        XCTAssertEqual(DeletionEngine.dryRun(plan).valid.count, 1)
        try Data("bbb".utf8).write(to: file)
        let times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimensat(AT_FDCWD, file.path, $0.baseAddress!, 0) }, 0)
        var after = stat(); XCTAssertEqual(lstat(file.path, &after), 0)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        XCTAssertEqual(DeletionEngine.dryRun(plan).rejected.count, 1)
    }

    func testRestoreReportsConflictWithoutBlockingOtherItems() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-restore-conflict-" + UUID().uuidString)
        let trash = dir.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func item(_ name: String) throws -> DeleteItem {
            let target = trash.appendingPathComponent(name)
            try Data(name.utf8).write(to: target)
            var st = stat(); XCTAssertEqual(lstat(target.path, &st), 0)
            var item = DeleteItem(originalPath: dir.appendingPathComponent(name).path, fileIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)), logicalSize: Int64(st.st_size), ruleID: "test")
            item.trashPath = target.path
            return item
        }
        let first = try item("first"), second = try item("second")
        try Data("existing".utf8).write(to: dir.appendingPathComponent("first"))
        let plan = DeletePlan(items: [first, second], rulesVersion: "test")
        let audit = AuditLog(directoryURL: dir.appendingPathComponent("audit"))
        try audit.recordDurable(DeletionResult(plan: plan, succeededCount: 2, failedCount: 0, actuallyMovedBytes: first.logicalSize + second.logicalSize, failures: [], movedItems: [first, second]))
        let result = try DeletionEngine.restoreLastCleanupDetailed(audit: audit)
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.items.first?.status, .conflict)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("first"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("second"), encoding: .utf8), "second")
        XCTAssertEqual(try DeletionEngine.restoreLastCleanupDetailed(audit: audit).items.last?.status, .alreadyRestored)
    }

    func testUnverifiedInterruptedItemSurvivesRestartWithoutClaimingSuccess() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-unverified-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = DeleteItem(originalPath: dir.appendingPathComponent("unknown").path, fileIdentity: FileIdentity(device: 1, inode: 2), logicalSize: 10, ruleID: "test")
        let plan = DeletePlan(items: [item], rulesVersion: "test")
        let audit = AuditLog(directoryURL: dir)
        try audit.recordDurable(DeletionResult(plan: plan, succeededCount: 0, failedCount: 0, actuallyMovedBytes: 0, failures: [], movedItems: [], pendingItem: item))
        XCTAssertTrue(try DeletionEngine.markInterruptedUnverified(audit: audit))
        let restarted = AuditLog(directoryURL: dir); restarted.loadIfNeeded()
        XCTAssertNil(restarted.last?.pendingItem)
        XCTAssertEqual(restarted.last?.succeededCount, 0)
        XCTAssertEqual(restarted.last?.unverifiedItems?.first?.originalPath, item.originalPath)
        XCTAssertEqual(try DeletionEngine.restoreLastCleanup(audit: restarted), 0)
    }

    func testLegacyPlanWithTrashPathDoesNotProveSuccess() throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-legacy-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let trashed = dir.appendingPathComponent("trash-item")
        try Data("data".utf8).write(to: trashed)
        var st = stat(); XCTAssertEqual(lstat(trashed.path, &st), 0)
        var item = DeleteItem(originalPath: dir.appendingPathComponent("original").path, fileIdentity: FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino)), logicalSize: 4, ruleID: "test")
        item.trashPath = trashed.path
        let plan = DeletePlan(items: [item], rulesVersion: "test")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
        let data = try JSONSerialization.data(withJSONObject: ["reports": [], "deletions": [object]])
        try data.write(to: dir.appendingPathComponent("history.json"))
        let audit = AuditLog(directoryURL: dir); audit.loadIfNeeded()
        XCTAssertEqual(try DeletionEngine.restoreLastCleanup(audit: audit), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.originalPath))
    }

    func testPausedScanCanBeCancelledWithPartialResult() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-pause-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<2200 { try Data([1]).write(to: dir.appendingPathComponent("file-\(index)")) }
        let engine = ScanEngine()
        let paused = expectation(description: "scan paused")
        let task = Task {
            try await engine.scan(url: dir) { progress in
                if progress.scannedItems >= 2000 && !engine.isCancelled {
                    engine.setPaused(true)
                    paused.fulfill()
                }
            }
        }
        await fulfillment(of: [paused], timeout: 15)
        XCTAssertTrue(engine.isPaused)
        engine.cancel()
        let result = try await task.value
        XCTAssertEqual(result.report.completionStatus, "cancelled")
        XCTAssertGreaterThanOrEqual(result.report.totalFiles, 2000)
        XCTAssertLessThan(result.report.totalFiles, 2200)
    }

    func testIncrementalScanFallsBackWhenDirectoryIdentityChanges() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-dir-replaced-" + UUID().uuidString)
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("before".utf8).write(to: b.appendingPathComponent("file"))
        let initial = try await ScanEngine().scan(url: dir) { _ in }
        let snapshot = ScanSnapshot(outcome: initial)
        try FileManager.default.moveItem(at: b, to: dir.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
        let result = try await IncrementalScanner.rescan(snapshot: snapshot, changedDirectories: [a.path], limits: ScanLimits())
        XCTAssertTrue(result.usedFullScan)
        XCTAssertTrue(result.fallbackReason?.contains("目录身份") == true)
        XCTAssertTrue(result.outcome.root.flattenedFiles().contains { $0.url.lastPathComponent == "file" })
    }

    func testPermissionProbeDoesNotDeclareFullAccessFromOneReadableDirectory() {
        XCTAssertEqual(PermissionProbe.summarize([]), .unknown)
        XCTAssertEqual(PermissionProbe.summarize([.granted, .denied]), .denied)
        XCTAssertEqual(PermissionProbe.summarize([.granted, .unknown]), .unknown)
        XCTAssertEqual(PermissionProbe.summarize([.granted, .granted]), .granted)
    }

    func testUnreadableNestedDirectoryCannotBeFingerprinted() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires a non-root test user") }
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-unreadable-" + UUID().uuidString)
        let nested = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { _ = chmod(nested.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        try Data("test".utf8).write(to: nested.appendingPathComponent("file"))
        XCTAssertEqual(chmod(nested.path, 0), 0)
        XCTAssertNil(DirectoryFingerprint.capture(dir.path))
    }

    func testIncrementalScanFallsBackOnUnreportedPermissionChange() async throws {
        let dir = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("shulang-permissions-" + UUID().uuidString)
        let changed = dir.appendingPathComponent("changed"), other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = try await ScanEngine().scan(url: dir) { _ in }
        let snapshot = ScanSnapshot(outcome: initial)
        XCTAssertEqual(chmod(other.path, 0o700), 0)
        let result = try await IncrementalScanner.rescan(snapshot: snapshot, changedDirectories: [changed.path], limits: ScanLimits())
        XCTAssertTrue(result.usedFullScan)
        XCTAssertTrue(result.fallbackReason?.contains("状态或权限") == true)
    }

    func testDeletionOverlapRespectsCaseAndProtectsAllChildren() {
        let sensitive = DeletionPathIndex([
            .init(path: "/disk/A", caseSensitive: true),
            .init(path: "/disk/a/file", caseSensitive: true)
        ])
        XCTAssertTrue(sensitive.overlappingIndices().isEmpty)
        XCTAssertFalse(sensitive.hasSelectedAncestor(of: "/disk/a/keeper", caseSensitive: true))
        let insensitive = DeletionPathIndex([
            .init(path: "/disk/A", caseSensitive: false),
            .init(path: "/disk/a/file", caseSensitive: false),
            .init(path: "/disk/A/other", caseSensitive: false)
        ])
        XCTAssertEqual(insensitive.overlappingIndices(), Set([0, 1, 2]))
        XCTAssertTrue(insensitive.hasSelectedAncestor(of: "/disk/a/keeper", caseSensitive: false))
        let separate = DeletionPathIndex([
            .init(path: "/disk/a", caseSensitive: false),
            .init(path: "/disk/ab/file", caseSensitive: false)
        ])
        XCTAssertTrue(separate.overlappingIndices().isEmpty)
    }

}
