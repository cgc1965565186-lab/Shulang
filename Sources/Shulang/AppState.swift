import Foundation
import SwiftUI
import Observation
import AppKit
import ShulangCore

// MARK: - 导航

enum SidebarGroup: String, CaseIterable {
    case start = "开始"
    case clean = "清理"
    case records = "记录与设置"
}

enum SidebarItem: String, Identifiable, CaseIterable {
    case overview, space, cleanup, duplicates, uninstall, history, rules, automation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "开始"
        case .space: return "空间地图"
        case .cleanup: return "清理清单"
        case .duplicates: return "重复文件"
        case .uninstall: return "应用管理"
        case .history: return "历史与报告"
        case .rules: return "清理规则"
        case .automation: return "自动化"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "选范围 → 扫描 → 复核"
        case .space: return "看清谁占了空间"
        case .cleanup: return "批量选择与预览"
        case .duplicates: return "内容完全一致的副本"
        case .uninstall: return "应用清单与疑似残留"
        case .history: return "扫描与清理记录"
        case .rules: return "决定扫什么、删什么"
        case .automation: return "空间不足时提醒"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "house"
        case .space: return "square.grid.2x2"
        case .cleanup: return "checklist"
        case .duplicates: return "doc.on.doc"
        case .uninstall: return "app.badge.checkmark"
        case .history: return "clock.arrow.circlepath"
        case .rules: return "slider.horizontal.3"
        case .automation: return "clock"
        }
    }

    var group: SidebarGroup {
        switch self {
        case .overview: return .start
        case .space, .cleanup, .duplicates, .uninstall: return .clean
        case .history, .rules, .automation: return .records
        }
    }

    static func items(in group: SidebarGroup) -> [SidebarItem] {
        allCases.filter { $0.group == group && $0 != .automation }
    }
}

enum DisplayMode: String, CaseIterable { case treemap, sunburst, list
    var title: String { self == .treemap ? "矩形树图" : self == .sunburst ? "旭日图" : "列表" }
}
enum SizeBasis: String, CaseIterable { case logical, allocated
    var title: String { self == .logical ? "逻辑大小" : "已分配空间估算" }
}
enum AppPhase: String {
    case idle, scanning, reviewing, deleting, rolledBack, failed
    var title: String {
        switch self {
        case .idle: return "空闲"; case .scanning: return "扫描中"; case .reviewing: return "待复核"
        case .deleting: return "清理中"; case .rolledBack: return "已恢复"; case .failed: return "失败"
        }
    }
}
enum AnalysisPhase: String { case idle, running, done }

private final class WeakAppState: @unchecked Sendable {
    weak var value: AppState?
    init(_ value: AppState) { self.value = value }
}

/// 应用状态中枢。视图只读它、调用它的意图方法；昂贵计算与文件 IO 一律离开主线程。
@MainActor
@Observable
final class AppState {
    // 导航与外观
    var selection: SidebarItem = .overview
    var displayMode: DisplayMode = .treemap
    var sizeBasis: SizeBasis = .logical
    var showInspector = true { didSet { UserDefaults.standard.set(showInspector, forKey: "shulang.showInspector") } }
    var showOnboarding: Bool = !UserDefaults.standard.bool(forKey: "shulang.onboarded")
    var searchText = "" { didSet { rebuildVisibleCandidates() } }
    var categoryFilter: CategoryKind? { didSet { rebuildVisibleCandidates() } }
    /// ⌘F 时自增，清理清单据此把焦点移到搜索框。
    var searchFocusToken = 0

    // 选中与聚焦（检查器据此显示内容）
    var selectedNode: ScanNode?
    var selectedCandidateID: UUID?
    var focusNode: ScanNode?

    // 卷与扫描
    var volumes: [VolumeInfo] = []
    var selectedVolume: VolumeInfo?
    var scanURL: URL?
    var root: ScanNode?
    private(set) var scanSnapshot: ScanSnapshot?
    var sunburstLayoutCache: [String: [SunburstArc]] = [:]
    var treemapLayoutCache: [String: [TreemapTile]] = [:]
    private var nodeIndex: [UUID: ScanNode] = [:]
    var previousRoot: ScanNode?
    var report: ScanReport?
    var scanChangesPending = false
    var isIncrementalUpdate = false
    var progress: ScanProgress?
    var phase: AppPhase = .idle
    var fdaStatus: FDAStatus = .unknown
    var enumerator: EnumeratorKind = .foundation { didSet { UserDefaults.standard.set(enumerator.rawValue, forKey: "shulang.enumerator") } }
    var includeHidden = true { didSet { UserDefaults.standard.set(includeHidden, forKey: "shulang.includeHidden") } }

    // 分析结果
    var candidates: [Candidate] = [] { didSet { rebuildVisibleCandidates() } }
    var duplicateGroups: [DuplicateGroup] = []
    var leftovers: [LeftoverItem] = []
    var installedApps: [InstalledApplication] = []
    var customApplicationRoots = UserDefaults.standard.stringArray(forKey: "shulang.applicationRoots") ?? [] {
        didSet { UserDefaults.standard.set(customApplicationRoots, forKey: "shulang.applicationRoots") }
    }
    var diffEntries: [ScanDiffEntry] = []
    var diffAvailable = false
    var regrowth: [String: Double] = [:]
    var selectedCandidateIDs: Set<UUID> = []      // 默认零勾选
    var duplicatesPhase: AnalysisPhase = .idle
    var duplicateProgress: (Int, Int)?
    var leftoversPhase: AnalysisPhase = .idle
    var installedAppsPhase: AnalysisPhase = .idle
    var ruleSet: RuleSet = .builtin {
        didSet {
            let defaults = UserDefaults.standard
            if ruleSet.rules.allSatisfy(\.isBuiltin) {
                defaults.removeObject(forKey: "shulang.importedRules")
                defaults.set(Dictionary(uniqueKeysWithValues: ruleSet.rules.map { ($0.id, $0.enabled) }), forKey: "shulang.builtinRuleStates")
            } else if let data = try? ruleSet.exportJSON() {
                defaults.set(data, forKey: "shulang.importedRules")
            }
            refreshCandidatesForRules()
        }
    }

    // 事务与反馈
    var lastResult: DeletionResult?
    var lastRestoreResult: RestoreResult?
    var pendingRecovery: DeleteItem?
    var isRecoveringPending = false
    var lastFreedBytes: Int64?
    var lastCleanupAt: Date?
    private var reviewedPlan: DeletePlan?
    var showingConfirm = false
    var errorMessage: String?
    var toast: String? { didSet { scheduleToastDismissal() } }
    var automationEnabled = false
    var dryRunDefault = true { didSet { UserDefaults.standard.set(dryRunDefault, forKey: "shulang.dryRunDefault") } }

    private var toastCenter = ToastCenter()
    private var toastDismissTask: Task<Void, Never>?
    private var engine: ScanEngine?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var scanOperationGeneration = UUID()
    private var scanChangeEpoch: UInt64 = 0
    private var scanEventsReliable = false
    private var scanTracker: SnapshotInvalidationTracker?
    private var scanStore: SnapshotStore?
    private var trackedRoot: URL?
    private var duplicateTask: Task<Void, Never>?
    private var duplicateGeneration = UUID()
    private var leftoversGeneration = UUID()
    private var installedAppsGeneration = UUID()
    private var volumeRefreshGeneration = UUID()
    private var fdaRefreshGeneration = UUID()
    private var rulesRefreshGeneration = UUID()
    var isRefreshingRules = false

    private func scheduleToastDismissal() {
        toastDismissTask?.cancel()
        guard toast != nil else { toastCenter.clear(); return }
        let ticket = toastCenter.issue()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            if self.toastCenter.shouldDismiss(ticket) { self.toast = nil }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: "shulang.showInspector") as? Bool { showInspector = value }
        if let value = defaults.object(forKey: "shulang.includeHidden") as? Bool { includeHidden = value }
        if let value = defaults.object(forKey: "shulang.dryRunDefault") as? Bool { dryRunDefault = value }
        if let value = defaults.string(forKey: "shulang.enumerator"), let saved = EnumeratorKind(rawValue: value) { enumerator = saved }
        if let data = defaults.data(forKey: "shulang.importedRules"), let imported = try? RuleSet.importJSON(data) {
            ruleSet = imported
        } else if let states = defaults.dictionary(forKey: "shulang.builtinRuleStates") as? [String: Bool] {
            var builtins = RuleSet.builtin
            for index in builtins.rules.indices {
                if let enabled = states[builtins.rules[index].id] { builtins.rules[index].enabled = enabled }
            }
            ruleSet = builtins
        }
        // 默认扫主目录而不是整卷：整卷扫描慢，容易让用户误以为「卡住 / 快速开始无效」。
        scanURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        AuditLog.shared.loadIfNeeded()
        lastResult = AuditLog.shared.last
        pendingRecovery = lastResult?.pendingItem
        if AuditLog.shared.last?.pendingItem != nil {
            isRecoveringPending = true
            Task { [weak self] in
                defer { self?.isRecoveringPending = false }
                do {
                    let resolved = try await Task.detached { try DeletionEngine.recoverInterrupted() }.value
                    self?.lastResult = AuditLog.shared.last
                    self?.pendingRecovery = AuditLog.shared.last?.pendingItem
                    self?.errorMessage = resolved ? "已定位上次中断的清理项目，可在历史中恢复。" : "上次清理中断，有项目尚未定位；请在访达的废纸篓中核查。"
                } catch {
                    self?.errorMessage = "无法核查上次中断的清理：\(error.localizedDescription)"
                }
            }
        }
        refreshVolumes()
        refreshFDA()
    }

    // MARK: - 派生状态（视图直接读）

    var hasResults: Bool { root != nil }
    var currentRange: URL? { scanURL ?? selectedVolume?.mountPoint }
    var currentRangeLabel: String { currentRange?.path ?? "未选择范围" }
    var currentFocus: ScanNode? { focusNode ?? root }

    /// 四步工作流的当前位置，用于引导条高亮。
    var workflowStep: Int {
        if phase == .scanning { return 2 }
        if root == nil { return 2 }
        if selectedCandidateIDs.isEmpty { return 3 }
        return 4
    }

    /// 过滤与排序结果缓存：视图 body 直接读，避免每次重绘都全量 filter + sort（P0-B1）。
    private(set) var visibleCandidates: [Candidate] = []
    private var visibleCandidateIDs: Set<UUID> = []
    private var candidateIndex: [UUID: Candidate] = [:]
    private(set) var isFilteringCandidates = false
    /// 候选总量缓存，避免多处 body 内 reduce。
    private(set) var candidateTotalBytes: Int64 = 0

    private var filterGeneration = UUID()
    private var filterTask: Task<Void, Never>?

    private func rebuildVisibleCandidates() {
        let ticket = UUID()
        filterGeneration = ticket
        filterTask?.cancel()
        let input = candidates
        let categoryFilter = categoryFilter
        let searchText = searchText
        isFilteringCandidates = true
        visibleCandidates = []
        visibleCandidateIDs = []
        filterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
        let filtered = input.filter { candidate in
            if let categoryFilter, candidate.category != categoryFilter { return false }
            if !searchText.isEmpty, !candidate.path.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
                return (filtered.sorted { $0.logicalSize > $1.logicalSize }, input.reduce(Int64(0)) { $0 + $1.logicalSize },
                        Set(filtered.map(\.id)), Dictionary(input.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
            }.value
            guard !Task.isCancelled, let self, self.filterGeneration == ticket else { return }
            self.visibleCandidates = result.0
            self.candidateTotalBytes = result.1
            self.visibleCandidateIDs = result.2
            self.candidateIndex = result.3
            self.isFilteringCandidates = false
        }
    }

    // 兼容旧视图命名
    var filteredCandidates: [Candidate] { visibleCandidates }
    var selectedCandidates: [Candidate] {
        guard !isFilteringCandidates else { return [] }
        return selectedCandidateIDs.compactMap { candidateIndex[$0] }
    }
    var hiddenSelectedCount: Int {
        selectedCandidateIDs.subtracting(visibleCandidateIDs).count
    }
    var selectedBytes: Int64 { selectedCandidates.reduce(0) { $0 + $1.logicalSize } }
    var focusedCandidate: Candidate? {
        guard let id = selectedCandidateID else { return selectedCandidates.first }
        return isFilteringCandidates ? nil : candidateIndex[id]
    }

    // MARK: - 卷与权限

    func refreshVolumes() {
        let generation = UUID()
        volumeRefreshGeneration = generation
        Task { [weak self] in
            let result = await Task.detached { VolumeProvider.currentVolumes() }.value
            guard let self, self.volumeRefreshGeneration == generation else { return }
            self.volumes = result
            if self.selectedVolume == nil { self.selectedVolume = result.first }
            if let current = self.selectedVolume, let refreshed = result.first(where: { $0.id == current.id }) {
                self.selectedVolume = refreshed
            }
        }
    }

    func refreshFDA() {
        let generation = UUID()
        fdaRefreshGeneration = generation
        Task { [weak self] in
            let result = await Task.detached { PermissionProbe.fullDiskAccess() }.value
            guard let self, self.fdaRefreshGeneration == generation else { return }
            let previous = self.fdaStatus
            self.fdaStatus = result
            if previous != .unknown, previous != result { self.invalidateScanForEnvironmentChange() }
        }
    }

    func volumeDidChange() {
        refreshVolumes()
        invalidateScanForEnvironmentChange()
    }

    private func invalidateScanForEnvironmentChange() {
        guard let store = scanStore, let url = trackedRoot else { return }
        scanChangesPending = true
        scanChangeEpoch &+= 1
        scanEventsReliable = false
        let session = scanGeneration
        Task { [weak self] in
            do {
                try await Task.detached { try store.markInvalidated(sessionID: session, path: url.path) }.value
            } catch {
                if self?.scanGeneration == session { self?.toast = "无法保存变化记录，请重新全量扫描：\(error.localizedDescription)" }
            }
        }
    }

    func openFDASettings() {
        PermissionProbe.openFullDiskAccessSettings()
        toast = "授权后回到疏朗，点击「重新检测」"
    }

    @discardableResult
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选这个范围"
        panel.message = "疏朗只扫描你选择的目录。系统保护目录始终不可清理。"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setRange(url)
        return url
    }

    func setRange(_ url: URL) {
        scanURL = url
        selectedVolume = VolumeProvider.info(for: url)
        toast = "扫描范围：\(url.path)"
    }

    func selectVolume(_ volume: VolumeInfo) {
        selectedVolume = volume
        scanURL = volume.mountPoint
        toast = "扫描范围：整卷 \(volume.name)。整卷包含系统文件，耗时会明显更长；日常清理建议选个人文件夹"
    }

    /// 概览页的「一键开始」：没有范围就先选，然后立刻扫描并进入清理清单。
    func startQuickStart() {
        if scanURL == nil { guard pickFolder() != nil else { return } }
        startScan(destination: .cleanup)
    }

    // MARK: - 扫描

    func startScan(destination: SidebarItem? = nil) {
        guard let url = currentRange else {
            if pickFolder() == nil { return }
            startScan(destination: destination)
            return
        }
        guard phase != .deleting else { return }
        rulesRefreshGeneration = UUID()
        isRefreshingRules = false
        cancelDuplicates()
        scanGeneration = UUID()
        engine?.cancel()
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        scanOperationGeneration = UUID()
        scanChangeEpoch = 0
        scanEventsReliable = false
        isIncrementalUpdate = false
        scanTracker = nil
        scanStore = nil
        trackedRoot = nil
        scanChangesPending = false
        previousRoot = root
        phase = .scanning
        progress = ScanProgress(scannedItems: 0, scannedBytes: 0,
                                currentPath: url.path, isPaused: false, fallbackCount: 0)
        errorMessage = nil
        var limits = ScanLimits()
        limits.includeHidden = includeHidden
        limits.enumerator = enumerator
        let engine = ScanEngine()
        self.engine = engine
        let rules = ruleSet
        let previous = scanSnapshot
        scanTask = Task { [weak self] in
            do {
                let tracking = await Task.detached { [weak self] () -> (SnapshotStore?, SnapshotInvalidationTracker?, String?) in
                    do {
                        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        let directory = base.appendingPathComponent("Shulang", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let store = try SnapshotStore(url: directory.appendingPathComponent("snapshots.sqlite"))
                        let tracker = try SnapshotInvalidationTracker(root: url.resolvingSymlinksInPath(), sessionID: generation, store: store,
                            ignoredDirectories: [directory.resolvingSymlinksInPath()], onUpdate: { [weak self] _ in
                                Task { @MainActor [weak self] in
                                    if let self, self.scanGeneration == generation {
                                        self.scanChangesPending = true
                                        self.scanChangeEpoch &+= 1
                                    }
                                }
                            }, onFailure: { [weak self] message in
                                Task { @MainActor [weak self] in
                                    if let self, self.scanGeneration == generation {
                                        self.scanChangesPending = true
                                        self.scanChangeEpoch &+= 1
                                        self.scanEventsReliable = false
                                        self.toast = "变化记录失败：\(message)，请重新全量扫描"
                                    }
                                }
                            })
                        return (store, tracker, nil)
                    } catch { return (nil, nil, error.localizedDescription) }
                }.value
                guard !Task.isCancelled, self?.scanGeneration == generation else { return }
                self?.scanTracker = tracking.1
                self?.scanStore = tracking.0
                self?.trackedRoot = tracking.0 == nil ? nil : url.resolvingSymlinksInPath()
                self?.scanEventsReliable = tracking.1?.isReliable == true
                if let error = tracking.2 {
                    self?.scanChangesPending = true
                    self?.toast = "无法监测扫描后的变化：\(error)"
                }
                var outcome = try await engine.scan(url: url, limits: limits) { progress in
                    Task { @MainActor in
                        if self?.scanGeneration == generation {
                            self?.progress = ScanProgress(scannedItems: progress.scannedItems, scannedBytes: progress.scannedBytes,
                                                          scannedAllocatedBytes: progress.scannedAllocatedBytes, currentPath: progress.currentPath,
                                                          isPaused: engine.isPaused, fallbackCount: progress.fallbackCount)
                        }
                    }
                }
                let scanned = outcome
                let derived = await Task.detached(priority: .userInitiated) {
                    let candidates = scanned.report.completionStatus == "cancelled" ? [] : RiskEngine.makeCandidates(root: scanned.root, rules: rules)
                    var index: [UUID: ScanNode] = [:]
                    var pending = [scanned.root]
                    while let node = pending.popLast() {
                        index[node.id] = node
                        pending.append(contentsOf: node.children)
                    }
                    let snapshot = ScanSnapshot(outcome: scanned, sessionID: generation)
                    let comparable: Bool
                    let diff: [ScanDiffEntry]
                    if let previous, previous.canCompare(to: snapshot) {
                        comparable = true
                        diff = DiffEngine.compare(old: previous, new: snapshot)
                    } else {
                        comparable = false
                        diff = []
                    }
                    let largest = scanned.root.children.max { $0.effectiveSize < $1.effectiveSize }
                    return (candidates, diff, index, snapshot, largest, comparable)
                }.value
                guard !Task.isCancelled, self?.scanGeneration == generation else { return }
                if engine.isCancelled { outcome.report.completionStatus = "cancelled" }
                self?.nodeIndex = derived.2
                self?.scanSnapshot = engine.isCancelled && scanned.report.completionStatus != "cancelled" ? nil : derived.3
                self?.finishScan(outcome, candidates: engine.isCancelled ? [] : derived.0, initialNode: derived.4, destination: destination)
                self?.diffEntries = engine.isCancelled ? [] : derived.1
                self?.diffAvailable = !engine.isCancelled && derived.5
                let completedReport = outcome.report
                let snapshot = self?.scanSnapshot
                let store = tracking.0
                let saveError = await Task.detached { () -> String? in
                    AuditLog.shared.record(completedReport)
                    guard let snapshot, let store else { return nil }
                    do {
                        try store.save(snapshot)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let saveError, self?.scanGeneration == generation {
                    self?.toast = "扫描结果可查看，但快照保存失败：\(saveError)"
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self?.scanGeneration == generation else { return }
                    self?.phase = .reviewing
                    self?.toast = "扫描已取消；本次未完成的结果未保存"
                }
            } catch {
                await MainActor.run {
                    guard self?.scanGeneration == generation else { return }
                    self?.phase = .failed
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateChangedDirectories() {
        guard phase != .scanning, phase != .deleting, !isRefreshingRules else { return }
        guard scanEventsReliable, let snapshot = scanSnapshot, let tracker = scanTracker, tracker.isReliable, let store = scanStore,
              snapshot.sessionID == scanGeneration,
              currentRange?.resolvingSymlinksInPath().path == URL(fileURLWithPath: snapshot.report.rootPath).resolvingSymlinksInPath().path else {
            startScan()
            return
        }
        cancelDuplicates()
        let operation = UUID()
        scanOperationGeneration = operation
        let session = scanGeneration
        let rules = ruleSet
        var limits = ScanLimits()
        limits.includeHidden = includeHidden
        limits.enumerator = enumerator
        isIncrementalUpdate = true
        phase = .scanning
        progress = ScanProgress(scannedItems: 0, scannedBytes: 0, currentPath: snapshot.report.rootPath, isPaused: false, fallbackCount: 0)
        let stateRef = WeakAppState(self)
        scanTask = Task { [weak self] in
            do {
                await tracker.flush()
                try Task.checkCancellation()
                guard tracker.isReliable else { throw DirectoryEventsError.eventsLost }
                let batch = try await Task.detached { try store.pendingInvalidations(sessionID: session) }.value
                let paths = batch.paths.isEmpty ? [snapshot.report.rootPath] : batch.paths
                let result = try await IncrementalScanner.rescan(snapshot: snapshot, changedDirectories: paths, limits: limits) { progress in
                    Task { @MainActor in
                        if let state = stateRef.value, state.scanGeneration == session, state.scanOperationGeneration == operation { state.progress = progress }
                    }
                }
                try Task.checkCancellation()
                await tracker.flush()
                try Task.checkCancellation()
                guard tracker.isReliable else { throw DirectoryEventsError.eventsLost }
                guard let self, self.scanGeneration == session, self.scanOperationGeneration == operation else { return }
                let epoch = self.scanChangeEpoch
                let latest = try await Task.detached { try store.latestRevision(sessionID: session) }.value
                let revision = max(snapshot.revision, latest ?? 0) + 1
                let derived = await Task.detached(priority: .userInitiated) {
                    let candidates = RiskEngine.makeCandidates(root: result.outcome.root, rules: rules)
                    let next = ScanSnapshot(outcome: result.outcome, sessionID: session, revision: revision)
                    let comparable = snapshot.canCompare(to: next)
                    let diff = comparable ? DiffEngine.compare(old: snapshot, new: next) : []
                    var index: [UUID: ScanNode] = [:]
                    var stack = [result.outcome.root]
                    while let node = stack.popLast() { index[node.id] = node; stack.append(contentsOf: node.children) }
                    let largest = result.outcome.root.children.max { $0.effectiveSize < $1.effectiveSize }
                    return (candidates, diff, index, next, largest, comparable)
                }.value
                try Task.checkCancellation()
                guard self.scanGeneration == session, self.scanOperationGeneration == operation else { return }
                guard self.scanEventsReliable, tracker.isReliable else { throw DirectoryEventsError.eventsLost }
                let pending = try await Task.detached {
                    try store.commit(derived.3, acknowledging: batch)
                    AuditLog.shared.record(result.outcome.report)
                    return try store.pendingInvalidations(sessionID: session)
                }.value
                guard self.scanGeneration == session, self.scanOperationGeneration == operation else { return }
                self.nodeIndex = derived.2
                self.scanSnapshot = derived.3
                self.isIncrementalUpdate = false
                self.finishScan(result.outcome, candidates: derived.0, initialNode: derived.4, destination: nil)
                self.diffEntries = derived.1
                self.diffAvailable = derived.5
                self.scanChangesPending = !pending.paths.isEmpty || self.scanChangeEpoch != epoch
                self.toast = result.usedFullScan
                    ? "已回退全量扫描：\(result.fallbackReason ?? "覆盖需要重新核查")"
                    : "已更新 \(batch.paths.count) 个变化目录"
            } catch is CancellationError {
                guard self?.scanGeneration == session, self?.scanOperationGeneration == operation else { return }
                self?.isIncrementalUpdate = false
                self?.scanEventsReliable = false
                self?.phase = .reviewing
                self?.scanChangesPending = true
                self?.toast = "变化目录更新已取消，保留上次结果"
            } catch {
                guard self?.scanGeneration == session, self?.scanOperationGeneration == operation else { return }
                self?.isIncrementalUpdate = false
                self?.scanEventsReliable = false
                self?.phase = .reviewing
                self?.scanChangesPending = true
                self?.errorMessage = "更新未完成：\(error.localizedDescription)。上次结果仍保留，请重新扫描。"
            }
        }
    }

    private func refreshCandidatesForRules() {
        guard let root, phase != .scanning, phase != .deleting, report?.completionStatus != "cancelled" else { return }
        let generation = UUID()
        rulesRefreshGeneration = generation
        isRefreshingRules = true
        let rules = ruleSet
        let previousCandidates = candidates
        Task { [weak self] in
            let updated = await Task.detached(priority: .userInitiated) {
                let manual = previousCandidates.filter { $0.ruleID == "duplicate.exact" || $0.ruleID == "uninstall.leftover" }
                let manualPaths = Set(manual.map(\.path))
                return RiskEngine.makeCandidates(root: root, rules: rules).filter { !manualPaths.contains($0.path) } + manual
            }.value
            guard let self, self.rulesRefreshGeneration == generation, self.root === root else { return }
            self.candidates = updated
            self.selectedCandidateIDs = []
            self.selectedCandidateID = nil
            self.isRefreshingRules = false
            self.toast = "规则已更新，候选已重新计算；请重新勾选"
        }
    }

    private func finishScan(_ outcome: ScanOutcome, candidates newCandidates: [Candidate], initialNode: ScanNode?, destination: SidebarItem?) {
        root = outcome.root
        focusNode = nil
        report = outcome.report
        phase = .reviewing
        progress = nil
        candidates = newCandidates
        selectedCandidateIDs = []
        selectedCandidateID = nil
        regrowth = [:]
        selectedNode = initialNode ?? outcome.root
        // 重复/残留结果依赖新树，先失效，进入页面时再按需重算。
        duplicatesPhase = .idle
        leftoversPhase = .idle
        selection = destination ?? .cleanup
        toast = outcome.report.completionStatus == "cancelled"
            ? "扫描已取消：保留 \(outcome.report.totalNodes) 项的只读部分结果，重新扫描后才能清理"
            : "扫描完成：\(outcome.report.totalNodes) 项 · 已分配空间估算 \(ByteFormat.string(outcome.report.scannedAllocatedBytes))。下一步：核对清理清单"
    }

    func pauseScan() {
        guard !isIncrementalUpdate else { return }
        guard let engine else { return }
        engine.setPaused(!engine.isPaused)
        if let current = progress {
            progress = ScanProgress(scannedItems: current.scannedItems, scannedBytes: current.scannedBytes,
                                    scannedAllocatedBytes: current.scannedAllocatedBytes, currentPath: current.currentPath,
                                    isPaused: engine.isPaused, fallbackCount: current.fallbackCount)
        }
        if engine.isPaused { toast = "扫描已暂停，已扫描结果保留" }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        if isIncrementalUpdate {
            scanOperationGeneration = UUID()
            scanTask?.cancel()
            isIncrementalUpdate = false
            scanEventsReliable = false
            phase = .reviewing
            progress = nil
            scanChangesPending = true
            toast = "变化目录更新已取消，保留上次结果"
            return
        }
        engine?.cancel()
        toast = "正在停止扫描并整理只读部分结果…"
    }

    // MARK: - 树导航

    func drillInto(_ node: ScanNode) {
        guard node.isDirectoryLike else { selectedNode = node; return }
        focusNode = node
        selectedNode = node
    }
    func drillUp() {
        guard let parent = focusNode?.parent else { focusNode = nil; return }
        focusNode = parent === root ? nil : parent
        selectedNode = focusNode ?? root
    }
    func drillToRoot() { focusNode = nil; selectedNode = root }

    // MARK: - 分析（缓存 + 后台）

    func ensureDuplicates(force: Bool = false) {
        guard let root else { return }
        guard report?.completionStatus != "cancelled" else { return }
        if !force, duplicatesPhase == .done { return }
        guard duplicatesPhase != .running else { return }
        duplicatesPhase = .running
        duplicateProgress = nil
        let generation = UUID()
        duplicateGeneration = generation
        duplicateTask = Task.detached(priority: .userInitiated) {
            let groups = DuplicateEngine.find(root: root, onProgress: { count, total in
                Task { @MainActor in
                    if self.duplicateGeneration == generation { self.duplicateProgress = (count, total) }
                }
            }, shouldContinue: { !Task.isCancelled })
            await MainActor.run {
                guard self.root === root, self.duplicateGeneration == generation else { return }
                self.duplicateGroups = groups
                self.duplicatesPhase = .done
                self.duplicateTask = nil
            }
        }
    }

    func cancelDuplicates() {
        duplicateGeneration = UUID()
        duplicateTask?.cancel()
        duplicateTask = nil
        if duplicatesPhase == .running { duplicatesPhase = .idle }
        duplicateProgress = nil
    }

    func ensureLeftovers(force: Bool = false) {
        if !force, leftoversPhase == .done { return }
        guard leftoversPhase != .running else { return }
        leftoversPhase = .running
        let generation = UUID()
        leftoversGeneration = generation
        Task.detached(priority: .userInitiated) {
            let items = UninstallEngine.findLeftovers()
            await MainActor.run {
                guard self.leftoversGeneration == generation else { return }
                self.leftovers = items
                self.leftoversPhase = .done
            }
        }
    }

    func ensureInstalledApps(force: Bool = false) {
        if !force, installedAppsPhase == .done { return }
        guard installedAppsPhase != .running else { return }
        installedAppsPhase = .running
        let generation = UUID()
        installedAppsGeneration = generation
        Task.detached(priority: .userInitiated) {
            let applications = UninstallEngine.installedApplications()
            await MainActor.run {
                guard self.installedAppsGeneration == generation else { return }
                self.installedApps = applications
                self.installedAppsPhase = .done
            }
        }
    }

    func addApplicationRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加应用目录"
        guard panel.runModal() == .OK, let path = panel.url?.standardizedFileURL.path else { return }
        guard !UninstallEngine.appRoots.contains(path) else { toast = "该目录已在应用清单范围内"; return }
        customApplicationRoots.append(path)
        refreshApplicationDiscovery()
    }

    func removeApplicationRoot(_ path: String) {
        customApplicationRoots.removeAll { $0 == path }
        refreshApplicationDiscovery()
    }

    private func refreshApplicationDiscovery() {
        leftoversGeneration = UUID()
        installedAppsGeneration = UUID()
        leftoversPhase = .idle
        installedAppsPhase = .idle
        ensureLeftovers(force: true)
        ensureInstalledApps(force: true)
    }

    @discardableResult
    func addCandidates(_ additions: [Candidate]) -> Int {
        guard !isRefreshingRules else { errorMessage = "规则更新中，请稍候"; return 0 }
        guard report?.completionStatus != "cancelled" else {
            errorMessage = "本次扫描已取消，结果只供查看；请重新扫描后清理"
            return 0
        }
        guard !additions.isEmpty else { return 0 }
        let existing = Set(candidates.map(\.path))
        let fresh = additions.filter { !existing.contains($0.path) }
        guard !fresh.isEmpty else {
            selectedCandidateIDs.formUnion(additions.filter { $0.ruleID != "uninstall.leftover" && isAutoSelectable($0) }.map(\.id))
            toast = "这些项目已在清理清单中"
            return 0
        }
        candidates.append(contentsOf: fresh)
        selectedCandidateIDs.formUnion(fresh.filter { $0.ruleID != "uninstall.leftover" && isAutoSelectable($0) }.map(\.id))
        toast = "已加入 \(fresh.count) 项到清理清单"
        return fresh.count
    }

    // MARK: - 选择与聚焦

    private func isAutoSelectable(_ candidate: Candidate) -> Bool {
        !PathGuard.isProtected(path: candidate.path) && !candidate.path.contains("/.Trash/")
    }

    func selectSafeOnly() {
        selectedCandidateIDs = Set(visibleCandidates
            .filter { $0.risk == .safe && $0.verifiedRule == true && isAutoSelectable($0) }
            .map(\.id))
        toast = "已选择 \(selectedCandidateIDs.count) 项可重建候选"
    }

    func selectAllVisible() {
        selectedCandidateIDs.formUnion(visibleCandidates.filter { $0.risk != .caution && $0.verifiedRule == true && isAutoSelectable($0) }.map(\.id))
        toast = "已选择当前列表全部 \(selectedCandidateIDs.count) 项"
    }

    func selectAllExcludingCaution() {
        selectedCandidateIDs = Set(visibleCandidates
            .filter { $0.risk != .caution && $0.verifiedRule == true && isAutoSelectable($0) }
            .map(\.id))
    }

    func invertVisibleSelection() {
        let visible = Set(visibleCandidates.filter { $0.risk != .caution && $0.verifiedRule == true && isAutoSelectable($0) }.map(\.id))
        selectedCandidateIDs = selectedCandidateIDs.symmetricDifference(visible)
    }

    func deselectAll() { selectedCandidateIDs = [] }

    func requestSearchFocus() {
        selection = .cleanup
        searchFocusToken &+= 1
    }

    func unselect(_ candidate: Candidate) {
        selectedCandidateIDs.remove(candidate.id)
        if selectedCandidateID == candidate.id { selectedCandidateID = nil }
    }

    func toggle(_ candidate: Candidate) {
        if selectedCandidateIDs.contains(candidate.id) { selectedCandidateIDs.remove(candidate.id) }
        else if isAutoSelectable(candidate) { selectedCandidateIDs.insert(candidate.id) }
        focus(candidate)
    }

    func focus(_ candidate: Candidate) {
        selectedCandidateID = candidate.id
        selectedNode = findNode(id: candidate.nodeID) ?? selectedNode
    }

    func focus(_ node: ScanNode) {
        selectedNode = node
        selectedCandidateID = nil
    }

    func findNode(id: UUID) -> ScanNode? {
        nodeIndex[id]
    }

    // MARK: - 预览

    func preview(_ candidate: Candidate) {
        previewURLs([URL(fileURLWithPath: candidate.path)])
    }

    func previewURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { errorMessage = "没有可预览的项目"; return }
        let inaccessible = urls.filter { !FileManager.default.isReadableFile(atPath: $0.path) }
        guard inaccessible.isEmpty else {
            errorMessage = "有 \(inaccessible.count) 个项目不存在或无法读取，无法预览。请重新扫描或检查权限。"
            return
        }
        if !PermissionProbe.quickLook(urls) { errorMessage = "快速查看不可用，请在访达中打开该项目。" }
    }

    func previewSelected() {
        let urls = selectedCandidates.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { errorMessage = "先勾选要预览的项目"; return }
        previewURLs(Array(urls.prefix(20)))
        if urls.count > 20, errorMessage == nil { toast = "已预览前 20 项，共选择 \(urls.count) 项" }
    }

    // MARK: - 清理事务

    func cleanSelected() {
        guard !isFilteringCandidates else { errorMessage = "正在更新清单，请稍候"; return }
        guard !isRefreshingRules else { errorMessage = "规则更新中，请稍候"; return }
        guard !selectedCandidates.isEmpty else {
            errorMessage = "先勾选要清理的项目。可以点「只选可重建项」快速开始。"
            return
        }
        reviewedPlan = DeletionEngine.buildPlan(from: selectedCandidates)
        showingConfirm = true
    }

    func performCleanup(dryRun: Bool) {
        guard !isFilteringCandidates else { errorMessage = "正在更新清单，请稍候"; return }
        guard !isRefreshingRules else { errorMessage = "规则更新中，请稍候"; return }
        guard report?.completionStatus != "cancelled" else { errorMessage = "部分扫描结果只供查看，请重新扫描"; return }
        guard phase != .scanning, phase != .deleting, duplicatesPhase != .running else { errorMessage = "请先结束扫描、重复检测或清理"; return }
        let selected = selectedCandidates
        let frozen = reviewedPlan ?? DeletionEngine.buildPlan(from: selected)
        let retainedPaths = Set(selected.map(\.path))
        let plan = DeletePlan(items: frozen.items.filter { retainedPaths.contains($0.originalPath) }, rulesVersion: frozen.rulesVersion)
        reviewedPlan = nil
        guard !plan.items.isEmpty else {
            errorMessage = "所选项目缺少扫描身份或受到保护，请重新检测并复核"
            return
        }
        phase = .deleting
        showingConfirm = false
        Task.detached {
            do {
                let result = try DeletionEngine.execute(plan, dryRun: dryRun)
                await MainActor.run {
                    self.lastResult = result
                    self.pendingRecovery = result.pendingItem
                    self.phase = .reviewing
                    if dryRun {
                        self.toast = "预演完成：可处理 \(result.plan.items.count - result.failedCount) 项，拒绝 \(result.failedCount) 项；未做任何写操作"
                    } else {
                        self.lastFreedBytes = result.actuallyMovedBytes
                        self.lastCleanupAt = Date()
                        let cleanedPaths = Set((result.movedItems ?? []).map(\.originalPath))
                        self.removeCleaned(paths: cleanedPaths)
                        for candidate in selected where cleanedPaths.contains(candidate.path) {
                            RegrowthTracker.shared.record(ruleID: candidate.ruleID, bytes: candidate.logicalSize)
                        }
                        self.selectedCandidateIDs.subtract(selected.filter { cleanedPaths.contains($0.path) }.map(\.id))
                        self.selectedCandidateID = nil
                        self.duplicatesPhase = .idle
                        self.leftoversPhase = .idle
                        self.refreshVolumes()
                        self.selection = .cleanup
                        self.toast = "已移入废纸篓 \(result.succeededCount) 项，失败或跳过 \(result.failedCount + selected.count - plan.items.count) 项；未成功项目仍保留在清单。Shift+Cmd+Z 可恢复"
                    }
                }
            } catch {
                let saved = AuditLog.shared.last
                await MainActor.run {
                    if let saved, saved.plan.id == plan.id {
                        self.lastResult = saved
                        self.pendingRecovery = saved.pendingItem
                        self.removeCleaned(paths: Set((saved.movedItems ?? []).map(\.originalPath)))
                    }
                    self.phase = .failed
                    self.refreshVolumes()
                    self.errorMessage = "清理中断：\(error.localizedDescription)。已记录的成功项目已更新；未确认项目请核查废纸篓。"
                }
            }
        }
    }

    /// 清理成功后同步更新树与候选，避免容量统计和列表停留在旧数据（用户反馈的核心问题之一）。
    private func removeCleaned(paths: Set<String>) {
        if !paths.isEmpty { scanSnapshot = nil }
        candidates.removeAll { paths.contains($0.path) }
        guard let root else { return }
        func prune(_ node: ScanNode) {
            node.children.removeAll { child in
                guard paths.contains(child.url.path) else { return false }
                var removed = [child]
                while let item = removed.popLast() {
                    nodeIndex.removeValue(forKey: item.id)
                    removed.append(contentsOf: item.children)
                }
                return true
            }
            for child in node.children where child.isDirectoryLike { prune(child) }
        }
        prune(root)
        root.recomputeAggregates()
        rebuildVisibleCandidates()
        if let selected = selectedNode, paths.contains(selected.url.path) { selectedNode = root }
        if let focus = focusNode, paths.contains(focus.url.path) { focusNode = nil }
    }

    func restoreLastCleanup() {
        guard !isRefreshingRules else { errorMessage = "规则更新中，请稍候"; return }
        guard phase != .scanning, phase != .deleting, duplicatesPhase != .running else {
            errorMessage = "请先结束扫描、重复检测或清理"
            return
        }
        phase = .deleting
        Task { [weak self] in
            do {
                let result = try await Task.detached { try DeletionEngine.restoreLastCleanupDetailed() }.value
                guard let self else { return }
                self.lastRestoreResult = result
                self.phase = .rolledBack
                self.refreshVolumes()
                self.duplicatesPhase = .idle
                self.leftoversPhase = .idle
                self.toast = "已恢复 \(result.restoredCount) 项，失败或冲突 \(result.failedCount) 项；详情见历史"
                if result.restoredCount > 0 { self.startScan() }
            } catch { self?.phase = .failed; self?.errorMessage = error.localizedDescription }
        }
    }

    func retryInterruptedRecovery() {
        guard !isRecoveringPending, phase != .deleting else { return }
        isRecoveringPending = true
        Task { [weak self] in
            defer { self?.isRecoveringPending = false }
            do {
                let resolved = try await Task.detached { try DeletionEngine.recoverInterrupted() }.value
                self?.lastResult = AuditLog.shared.last
                self?.pendingRecovery = AuditLog.shared.last?.pendingItem
                self?.toast = resolved ? "已核查中断的清理记录" : "仍未找到可唯一确认的项目，请检查原位置与废纸篓"
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func markPendingUnverified() {
        guard !isRecoveringPending, phase != .deleting else { return }
        isRecoveringPending = true
        Task { [weak self] in
            defer { self?.isRecoveringPending = false }
            do {
                let changed = try await Task.detached { try DeletionEngine.markInterruptedUnverified() }.value
                self?.lastResult = AuditLog.shared.last
                self?.pendingRecovery = AuditLog.shared.last?.pendingItem
                if changed { self?.toast = "该项目已标为无法验证；记录会保留在历史中" }
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func checkDiskWatermark() {
        guard let volume = selectedVolume else { return }
        let threshold = Int64(Double(volume.totalBytes) * 0.10)
        if volume.availableBytes < threshold {
            toast = "可用空间低于 10%，建议做一次只读扫描（不会自动删除任何文件）"
        } else {
            toast = "可用空间充足：\(ByteFormat.string(volume.availableBytes))"
        }
    }

    // MARK: - 报告与规则

    func exportMarkdown() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "疏朗-空间分析报告.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = candidates, result = lastResult
        Task { [weak self] in
            do {
                try await Task.detached {
                    let text = Reporting.markdown(report: report, candidates: items, result: result)
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }.value
                self?.toast = "报告已导出到 \(url.lastPathComponent)"
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func exportJSON() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "疏朗-扫描数据.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = candidates
        Task { [weak self] in
            do {
                try await Task.detached {
                    let data = try Reporting.json(report: report, candidates: items)
                    try data.write(to: url, options: .atomic)
                }.value
                self?.toast = "数据已导出到 \(url.lastPathComponent)"
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "shulang-rules.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? ruleSet.exportJSON() else { return }
        do { try data.write(to: url); toast = "规则包已导出" }
        catch { errorMessage = error.localizedDescription }
    }

    func importRules() {
        guard phase != .scanning, phase != .deleting else { errorMessage = "请先结束扫描或清理"; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            ruleSet = try RuleSet.importJSON(data)
            toast = root == nil ? "已导入 \(ruleSet.rules.count) 条规则，扫描后生效" : "规则已导入，正在重新计算候选"
        } catch { errorMessage = "规则校验失败：\(error.localizedDescription)" }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "shulang.onboarded")
        showOnboarding = false
    }

    func reopenOnboarding() {
        UserDefaults.standard.set(false, forKey: "shulang.onboarded")
        showOnboarding = true
    }
}
