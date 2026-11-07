import SwiftUI
import AppKit
import ShulangCore

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @State private var isDropTargeted = false
    @State private var showCoverage = false

    var body: some View {
        @Bindable var bindable = state
        NavigationSplitView {
            SidebarView()
        } content: {
            VStack(spacing: 0) {
                if state.phase == .scanning { ScanBanner() }
                if state.scanChangesPending, state.report != nil, state.phase != .scanning {
                    HStack {
                        Text("扫描范围可能已变化；更新后可查看最新结果。").font(.callout)
                        Spacer()
                        Button("更新变化目录") { state.updateChangedDirectories() }
                    }.padding(12).background(SLColor.notice.opacity(0.12))
                }
                if let report = state.report, state.phase != .scanning, report.completionStatus == "cancelled" {
                    Text("扫描已取消：当前为只读部分结果。请重新扫描后清理。")
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(SLColor.notice.opacity(0.12))
                } else if let report = state.report, state.phase != .scanning, report.completionStatus == "partial" {
                    HStack {
                        Text("扫描范围不完整：\(report.inaccessibleCount) 处无法访问，\(report.excludedPaths?.count ?? 0) 处策略排除，\(report.truncatedPaths?.count ?? 0) 处达到上限。")
                            .font(.callout)
                        Spacer()
                        Button("查看详情") { showCoverage = true }
                            .popover(isPresented: $showCoverage) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("未覆盖的项目").font(.headline)
                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 6) {
                                            ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in
                                                Text(error).font(.caption).textSelection(.enabled)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding().frame(width: 520, height: 320)
                            }
                    }
                    .padding(12).background(SLColor.notice.opacity(0.12))
                }
                MainContentView()
            }
            .background(SLColor.window)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(SLColor.scan, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .background(SLColor.scan.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc").font(.largeTitle)
                                Text("松开即可扫描这个文件夹").font(.headline)
                            }.foregroundStyle(SLColor.scan)
                        }
                        .padding(10)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
        } detail: {
            if state.showInspector {
                InspectorView()
                    .frame(minWidth: 280, idealWidth: SLMetrics.inspectorWidth)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right").font(.title).foregroundStyle(.tertiary)
                    Text("检查器已隐藏").font(.callout).foregroundStyle(.secondary)
                    Button("显示检查器") { state.showInspector = true }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        .toolbar { MainToolbar() }
        .background(SLColor.window)
        .task {
            while !Task.isCancelled {
                if scenePhase == .active { state.refreshVolumes() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { state.refreshVolumes(); state.refreshFDA() } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in state.volumeDidChange() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in state.volumeDidChange() }
        .sheet(isPresented: $bindable.showOnboarding) { OnboardingView() }
        .sheet(isPresented: $bindable.showingConfirm) { ConfirmDeletionView() }
        .alert("提示", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SLColor.safe)
                    Text(toast).font(.callout)
                    Button { state.toast = nil } label: {
                        Image(systemName: "xmark").font(.caption)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SLColor.separator))
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.24), value: state.toast)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let value = item as? URL {
                url = value
            }
            guard let url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            Task { @MainActor in
                state.setRange(url)
                state.startScan(destination: .cleanup)
            }
        }
        return true
    }
}

// MARK: - 侧边栏

struct SidebarView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        List(selection: Binding(
            get: { state.selection },
            set: { if let value = $0 { state.selection = value } }
        )) {
            ForEach(SidebarGroup.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(SidebarItem.items(in: group)) { item in
                        SidebarRow(item: item, badge: badge(for: item)).tag(item)
                    }
                }
            }
            Section("当前状态") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.phase == .failed ? SLColor.danger : (state.phase == .scanning ? SLColor.scan : SLColor.safe))
                            .frame(width: 7, height: 7)
                        Text(state.phase.title).font(.caption)
                        Spacer()
                    }
                    Text(state.hasResults ? "已扫描 \(state.report?.totalNodes ?? 0) 项" : "尚未扫描")
                        .font(.caption2).foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield").font(.caption2)
                        Text("受保护目录探测：\(state.fdaStatus.title)").font(.caption2)
                    }.foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "leaf").foregroundStyle(SLColor.safe)
                    Text("疏朗 · 看清空间，安心释放")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("完全本地 · 零遥测 · 开源")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func badge(for item: SidebarItem) -> Int? {
        switch item {
        case .cleanup: return state.candidates.isEmpty ? nil : state.candidates.count
        case .duplicates: return state.duplicateGroups.isEmpty ? nil : state.duplicateGroups.count
        case .uninstall: return state.leftovers.isEmpty ? nil : state.leftovers.count
        default: return nil
        }
    }
}

struct SidebarRow: View {
    let item: SidebarItem
    let badge: Int?
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol).frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                Text(item.subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if let badge {
                Text("\(badge)").font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 扫描横幅（全局，不再单独占一个页面）

struct ScanBanner: View {
    @Environment(AppState.self) private var state
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("正在扫描：\(state.currentRange?.lastPathComponent ?? "…")").font(.callout.weight(.medium))
                if let progress = state.progress {
                    Text("\(progress.scannedItems) 项 · 已分配空间估算 \(ByteFormat.string(progress.scannedAllocatedBytes)) · \(progress.currentPath)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button(state.progress?.isPaused == true ? "继续" : "暂停") { state.pauseScan() }
                .buttonStyle(.bordered)
                .disabled(state.isIncrementalUpdate)
            Button("取消") { state.cancelScan() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(SLColor.scan.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - 主内容路由

struct MainContentView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        Group {
            switch state.selection {
            case .overview: OverviewView()
            case .space: SpaceMapView()
            case .cleanup: CleanupListView()
            case .duplicates: DuplicateView()
            case .uninstall: UninstallView()
            case .history: HistoryView()
            case .rules: RulesView()
            case .automation: AutomationView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SLColor.window)
        .navigationTitle(state.selection.title)
    }
}

// MARK: - 工具栏（全部带文字，避免只剩一排看不懂的图标）

struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var state
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Section("快速范围") {
                    Button("个人文件夹（推荐）") {
                        state.setRange(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
                    }
                    Button("下载") {
                        state.setRange(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads", isDirectory: true))
                    }
                }
                Section("整卷") {
                    ForEach(state.volumes) { volume in
                        Button("\(volume.name)（整卷，较慢）") { state.selectVolume(volume) }
                    }
                }
                Divider()
                Button("选择其他文件夹…") { state.pickFolder() }
            } label: {
                Label(rangeLabel, systemImage: "folder")
            }
            .help("扫描范围：\(state.currentRangeLabel)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.startScan(destination: .cleanup) } label: {
                Label(state.hasResults ? "重新扫描" : "开始扫描", systemImage: "play.fill")
            }
            .disabled(state.phase == .scanning)
            .help("只读扫描当前范围（⌘R）")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.previewSelected() } label: {
                Label("预览", systemImage: "eye")
            }
            .disabled(state.selectedCandidateIDs.isEmpty)
            .help("用快速查看预览勾选的项目（空格）")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { state.cleanSelected() } label: {
                Label(state.selectedCandidateIDs.isEmpty ? "清理" : "清理 \(state.selectedCandidateIDs.count) 项",
                      systemImage: "trash")
            }
            .disabled(state.selectedCandidateIDs.isEmpty)
            .help("先复核，再移入废纸篓（⌘Delete）")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("导出 Markdown 报告") { state.exportMarkdown() }
                Button("导出 JSON 数据") { state.exportJSON() }
                Divider()
                Button("导出规则包") { state.exportRules() }
                Button("恢复上次清理") { state.restoreLastCleanup() }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .help("导出报告、恢复上次清理")
        }
    }

    private var rangeLabel: String {
        guard let range = state.currentRange else { return "选择范围" }
        let home = NSHomeDirectory()
        if range.path == home { return "个人文件夹" }
        if range.path == home + "/Downloads" { return "下载" }
        if range.path == "/" { return "整卷" }
        return range.lastPathComponent
    }
}
