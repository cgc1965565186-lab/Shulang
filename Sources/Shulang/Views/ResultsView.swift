import SwiftUI
import AppKit
import ShulangCore

// MARK: - 空间地图（只负责「看清空间」，不承担清理决策）

struct SpaceMapView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            if let focus = state.currentFocus {
                HStack(spacing: 10) {
                    Button { state.drillToRoot() } label: { Image(systemName: "house") }
                        .buttonStyle(.borderless).help("回到扫描根目录")
                    Button { state.drillUp() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                        .disabled(state.focusNode == nil)
                        .help("上一级")
                    Text(breadcrumb(for: focus))
                        .font(.callout.monospacedDigit())
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Picker("", selection: Binding(get: { state.displayMode }, set: { state.displayMode = $0 })) {
                        ForEach(DisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 250).labelsHidden()
                    Picker("", selection: Binding(get: { state.sizeBasis }, set: { state.sizeBasis = $0 })) {
                        ForEach(SizeBasis.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).frame(width: 110).labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)

                Text("点击方块下钻；点击文件在右侧检查器查看详情。这里只做分析，清理请到「清理清单」。")
                    .font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)

                Group {
                    switch state.displayMode {
                    case .treemap: TreemapView(node: focus)
                    case .sunburst: SunburstView(node: focus)
                    case .list: FileListView(node: focus)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)

                HStack {
                    if let report = state.report {
                        Text("已分配空间估算 \(ByteFormat.string(report.scannedAllocatedBytes)) · 逻辑大小 \(ByteFormat.string(report.scannedLogicalBytes)) · \(report.totalNodes) 项")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("去清理清单核对候选") {
                        state.selection = .cleanup
                    }.buttonStyle(.borderedProminent)
                }
                .padding(16)
            } else {
                SLEmptyState(
                    title: "还没有空间数据",
                    reason: "先做一次只读扫描，就能看到每个文件夹占了多少空间。默认扫描你的个人文件夹，也可以拖一个文件夹进来。",
                    actionTitle: "开始扫描",
                    action: { state.startQuickStart() }
                )
            }
        }
    }

    private func breadcrumb(for node: ScanNode) -> String {
        var parts: [String] = []
        var current: ScanNode? = node
        while let item = current { parts.append(item.name); current = item.parent }
        return parts.reversed().joined(separator: " › ")
    }
}

// MARK: - 文件列表

struct FileListView: View {
    @Environment(AppState.self) private var state
    let node: ScanNode
    @State private var sortBySize = true
    @State private var fileIDs: [UUID] = []
    @State private var cacheKey = ""
    @State private var visibleCount = 300

    private var listKey: String {
        "\(node.id)-\(node.aggregatedSize)-\(node.aggregatedAllocatedSize)-\(state.sizeBasis.rawValue)-\(sortBySize)"
    }

    private func rebuildIfNeeded() async {
        let target = listKey
        guard target != cacheKey else { return }
        let sortSize = sortBySize
        let allocated = state.sizeBasis == .allocated
        let snapshot = state.scanSnapshot
        let focusID = node.id
        let fallback = snapshot == nil ? node.flattenedFiles().map { (id: $0.id, name: $0.name, size: allocated ? $0.allocatedSize : $0.logicalSize) } : []
        let ids = await Task.detached(priority: .userInitiated) {
            var entries = fallback
            if let snapshot {
                entries = snapshot.files(in: focusID).map {
                    ($0.id, URL(fileURLWithPath: $0.path).lastPathComponent,
                     allocated ? $0.allocatedSize : $0.logicalSize)
                }
            }
            return (sortSize ? entries.sorted { $0.size > $1.size } : entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).map { $0.id }
        }.value
        guard !Task.isCancelled, target == listKey else { return }
        fileIDs = ids
        visibleCount = 300
        cacheKey = target
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(fileIDs.count) 个文件").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("按大小排序", isOn: $sortBySize).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            List(Array(fileIDs.prefix(visibleCount)), id: \.self) { id in
                if let file = state.findNode(id: id) { HStack(spacing: 10) {
                    Image(systemName: file.kind == .symbolicLink ? "link" : "doc")
                        .foregroundStyle(SLColor.category(file.category)).frame(width: 16)
                    Text(file.name).lineLimit(1)
                    Spacer()
                    Text(ByteFormat.string(state.sizeBasis == .allocated ? file.allocatedSize : file.logicalSize))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button { state.previewURLs([file.url]) } label: {
                        Image(systemName: "eye")
                    }.buttonStyle(.borderless).help("快速查看")
                }
                .frame(height: SLMetrics.rowHeight)
                .contentShape(Rectangle())
                .onTapGesture { state.focus(file) }
                .contextMenu { NodeContextMenu(node: file) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            if visibleCount < fileIDs.count {
                Button("显示更多（剩余 \(fileIDs.count - visibleCount) 项）") { visibleCount += 300 }
                    .padding(8)
            }
        }
        .background(SLColor.content)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SLColor.separator))
        .task(id: listKey) { await rebuildIfNeeded() }
    }
}

struct NodeContextMenu: View {
    @Environment(AppState.self) private var state
    let node: ScanNode
    var body: some View {
        Button("快速查看") { state.previewURLs([node.url]) }
        Button("在访达中显示") { PermissionProbe.revealInFinder(node.url) }
        Button("复制路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        if let candidate = state.candidates.first(where: { $0.path == node.url.path }) {
            Divider()
            Button(state.selectedCandidateIDs.contains(candidate.id) ? "从清理清单取消勾选" : "加入清理清单并勾选") {
                state.toggle(candidate)
            }
        }
    }
}

// MARK: - 清理清单（批量选择 + 预览 + 复核）

struct CleanupListView: View {
    @Environment(AppState.self) private var state
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.root == nil {
                SLEmptyState(
                    title: "还没有可核对的清单",
                    reason: "清理清单来自一次只读扫描。默认扫描个人文件夹，也可以拖一个文件夹进窗口，或点下面的按钮开始。",
                    actionTitle: "一键开始",
                    action: { state.startQuickStart() }
                )
            } else if state.isFilteringCandidates {
                ProgressView("正在更新清单…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.visibleCandidates.isEmpty {
                SLEmptyState(
                    title: state.searchText.isEmpty ? "这个范围没有命中清理规则" : "没有匹配的项目",
                    reason: state.searchText.isEmpty
                        ? "扫描已完成，但当前规则没有找到可清理项。可以换一个范围，或到「清理规则」看看启用了哪些规则。"
                        : "试试清空搜索词，或换一个类别筛选。",
                    actionTitle: state.searchText.isEmpty ? "换一个范围" : "清空搜索",
                    action: {
                        if state.searchText.isEmpty { state.pickFolder() } else { state.searchText = "" }
                    }
                )
            } else {
                list
            }
            if !state.visibleCandidates.isEmpty { footer }
        }
        .onChange(of: state.searchFocusToken) { _, _ in
            searchFocused = true
        }
    }

    private var header: some View {
        @Bindable var bindable = state
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理清单").font(.title2.weight(.semibold))
                    Text("扫描范围：\(state.report?.rootPath ?? state.currentRangeLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if state.report != nil {
                    Text("共 \(state.candidates.count) 项候选 · \(ByteFormat.string(state.candidateTotalBytes))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("按路径搜索", text: $bindable.searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    if !state.searchText.isEmpty {
                        Button { state.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(SLColor.content, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SLColor.separator))
                .frame(maxWidth: 280)

                Menu {
                    Button("全部类别") { state.categoryFilter = nil }
                    Divider()
                    ForEach(CategoryKind.allCases) { kind in
                        Button(kind.title) { state.categoryFilter = kind }
                    }
                } label: {
                    Label(state.categoryFilter?.title ?? "全部类别", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton).frame(width: 130)

                Spacer()

                Button("全选") { state.selectAllVisible() }
                Button("反选") { state.invertVisibleSelection() }
                Button("只选可重建项") { state.selectSafeOnly() }
                Button("清空") { state.deselectAll() }
            }
            .buttonStyle(.bordered)
            .font(.callout)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private var list: some View {
        List(state.visibleCandidates, id: \.id) { candidate in
            CandidateRow(candidate: candidate)
                .frame(height: 44)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("已选 \(state.selectedCandidateIDs.count) 项 · \(ByteFormat.string(state.selectedBytes))")
                .font(.callout.monospacedDigit())
            if state.hiddenSelectedCount > 0 {
                Text("其中 \(state.hiddenSelectedCount) 项被筛选隐藏")
                    .font(.caption).foregroundStyle(SLColor.notice)
            }
            Text("移入废纸篓，可恢复").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("预览选中") { state.previewSelected() }
                .disabled(state.selectedCandidateIDs.isEmpty)
                .help("快速查看勾选的文件")
            Button("复核并清理") { state.cleanSelected() }
                .buttonStyle(.borderedProminent)
                .disabled(state.selectedCandidateIDs.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct CandidateRow: View {
    @Environment(AppState.self) private var state
    let candidate: Candidate

    private var isSelected: Bool { state.selectedCandidateIDs.contains(candidate.id) }
    private var isFocused: Bool { state.selectedCandidateID == candidate.id }

    var body: some View {
        HStack(spacing: 10) {
            Button { state.toggle(candidate) } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? SLColor.scan : .secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "取消勾选" : "勾选")

            Image(systemName: iconName)
                .foregroundStyle(SLColor.category(candidate.category))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.displayName).font(.callout).lineLimit(1)
                    SLRiskBadge(level: candidate.risk)
                }
                Text(candidate.path).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(candidate.logicalSize))
                    .font(.callout.monospacedDigit())
                Text(candidate.verifiedRule == true ? "内置规则" : "需人工核对")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button { state.preview(candidate) } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("快速查看这个文件")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { state.focus(candidate) }
        .background(isFocused ? SLColor.scan.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("快速查看") { state.preview(candidate) }
            Button("在访达中显示") { PermissionProbe.revealInFinder(URL(fileURLWithPath: candidate.path)) }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.path, forType: .string)
            }
            Divider()
            Button(isSelected ? "取消勾选" : "勾选") { state.toggle(candidate) }
        }
    }

    private var iconName: String {
        switch candidate.category {
        case .caches: return "archivebox"
        case .logs: return "doc.text"
        case .downloads: return "arrow.down.circle"
        case .developer: return "hammer"
        case .applications: return "app"
        case .mediaMail: return "photo"
        case .largeFiles: return "externaldrive"
        case .duplicates: return "doc.on.doc"
        default: return "doc"
        }
    }
}

// MARK: - 检查器（三种状态：候选证据 / 文件详情 / 本次扫描摘要）

struct InspectorView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("检查器").font(.headline)
                if let candidate = state.focusedCandidate {
                    candidateCard(candidate)
                    if let node = state.selectedNode, node.url.path == candidate.path {
                        nodeCard(node, compact: true)
                    }
                } else if let node = state.selectedNode {
                    nodeCard(node, compact: false)
                } else {
                    summaryCard
                }
            }
            .padding(16)
        }
        .background(SLColor.sidebar)
    }

    private func candidateCard(_ candidate: Candidate) -> some View {
        SLCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc")
                        .font(.title3).foregroundStyle(SLColor.category(candidate.category))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(candidate.displayName).font(.callout.weight(.semibold)).lineLimit(2)
                        SLRiskBadge(level: candidate.risk)
                    }
                }
                Divider()
                InfoLine("完整路径", candidate.path)
                InfoLine("大小", ByteFormat.string(candidate.logicalSize))
                InfoLine("命中规则", candidate.ruleID)
                InfoLine("判断依据", candidate.verifiedRule == true ? "内置规则" : "需人工核对")
                InfoLine("删除后果", candidate.consequence)
                InfoLine("会自动重建", candidate.rebuildable ? "是" : "否")
                InfoLine("恢复方式", candidate.recoverable ? "移入废纸篓，可放回" : "不可恢复")
                Text(candidate.evidence)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(candidate.risk.explanation)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { state.preview(candidate) } label: { Label("快速查看", systemImage: "eye") }
                    Button {
                        PermissionProbe.revealInFinder(URL(fileURLWithPath: candidate.path))
                    } label: { Label("在访达中显示", systemImage: "folder") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(state.selectedCandidateIDs.contains(candidate.id) ? "从清单取消勾选" : "加入并勾选") {
                    state.toggle(candidate)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nodeCard(_ node: ScanNode, compact: Bool) -> some View {
        SLCard {
            VStack(alignment: .leading, spacing: 8) {
                Label(node.name, systemImage: node.isDirectoryLike ? "folder" : "doc")
                    .font(.callout.weight(.medium)).lineLimit(2)
                Divider()
                InfoLine("路径", node.url.path)
                InfoLine("类型", node.isDirectoryLike ? "文件夹" : "文件")
                InfoLine("逻辑大小", ByteFormat.string(node.logicalSize))
                InfoLine("已分配空间估算", ByteFormat.string(node.allocatedSize))
                if node.isDirectoryLike { InfoLine("目录合计", ByteFormat.string(node.effectiveSize)) }
                if let date = node.modificationDate {
                    InfoLine("修改时间", date.formatted(date: .abbreviated, time: .shortened))
                }
                InfoLine("分类", node.category.title)
                if node.isProtected {
                    Label("受保护路径，引擎层禁止删除", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(SLColor.danger)
                }
                if !compact {
                    HStack {
                        Button { state.previewURLs([node.url]) } label: { Label("快速查看", systemImage: "eye") }
                        Button { PermissionProbe.revealInFinder(node.url) } label: { Label("在访达中显示", systemImage: "folder") }
                        Button("复制路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.url.path, forType: .string)
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SLCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("本次扫描", systemImage: "chart.pie").font(.headline)
                    if let report = state.report {
                        InfoLine("范围", report.rootPath)
                        InfoLine("条目", "\(report.totalNodes) 项，其中文件 \(report.totalFiles) 个")
                        InfoLine("已分配空间估算 / 逻辑大小", "\(ByteFormat.string(report.scannedAllocatedBytes)) / \(ByteFormat.string(report.scannedLogicalBytes))")
                        InfoLine("候选", "\(state.candidates.count) 项 · \(ByteFormat.string(state.candidateTotalBytes))")
                        if let freed = state.lastFreedBytes {
                            InfoLine("上次移入废纸篓", ByteFormat.string(freed))
                        }
                    } else {
                        Text("还没有扫描结果。点「开始扫描」，或把文件夹拖进窗口。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SLCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("下一步做什么", systemImage: "list.number").font(.headline)
                    stepRow(1, "在「清理清单」勾选要删的项目", active: state.root != nil)
                    stepRow(2, "点「预览」确认内容", active: !state.selectedCandidateIDs.isEmpty)
                    stepRow(3, "点「复核并清理」移入废纸篓", active: !state.selectedCandidateIDs.isEmpty)
                    Text("移入废纸篓后可尝试恢复；文件被移走、清空或原位置冲突时可能无法恢复。")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let volume = state.selectedVolume {
                SLCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("当前卷", systemImage: "internaldrive").font(.headline)
                        MetricRow(label: "可用", value: ByteFormat.string(volume.availableBytes))
                        MetricRow(label: "总容量", value: ByteFormat.string(volume.totalBytes))
                        CapacityRing(fraction: volume.usageFraction)
                            .frame(width: 96, height: 96)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func stepRow(_ number: Int, _ text: String, active: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .frame(width: 18, height: 18)
                .background(active ? SLColor.scan : Color.secondary.opacity(0.15), in: Circle())
            Text(text).font(.caption).foregroundStyle(active ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InfoLine: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
