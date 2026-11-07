import SwiftUI
import ShulangCore

// MARK: - 重复文件

struct DuplicateView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .task { state.ensureDuplicates() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("重复文件").font(.title2.weight(.semibold))
                    Text("每组文件的完整 SHA-256 一致；清理前请预览并确认保留的文件。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新检测") { state.ensureDuplicates(force: true) }
                Button("并排预览") {
                    let urls = state.duplicateGroups.prefix(4).flatMap(\.candidates).map(\.url)
                    if !urls.isEmpty { state.previewURLs(Array(urls.prefix(8))) }
                }
                .disabled(state.duplicateGroups.isEmpty)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if state.root == nil {
            SLEmptyState(title: "先扫描一次",
                         reason: "重复检测基于扫描到的文件清单，不会重新遍历磁盘。默认扫描个人文件夹，也可以拖一个文件夹进来。",
                         actionTitle: "一键开始", action: { state.startQuickStart() })
        } else if state.report?.completionStatus == "cancelled" {
            SLEmptyState(title: "扫描结果不完整", reason: "本次扫描已取消。请重新扫描后再检测重复文件。", actionTitle: "重新扫描", action: { state.startScan() })
        } else if state.duplicatesPhase == .running {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在按大小、首 4KB、完整哈希三段比对…").font(.callout).foregroundStyle(.secondary)
                if let progress = state.duplicateProgress {
                    Text("已处理 \(progress.0) 项，初筛候选 \(progress.1) 项；完整校验仍在进行")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("只读操作，不会修改任何文件").font(.caption).foregroundStyle(.tertiary)
                Button("取消检测") { state.cancelDuplicates() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.duplicatesPhase == .idle {
            SLEmptyState(title: "尚未完成重复检测", reason: "检测可以随时取消，不会修改文件。", actionTitle: "开始检测", action: { state.ensureDuplicates() })
        } else if state.duplicateGroups.isEmpty {
            SLEmptyState(title: "没有发现完全相同的文件",
                         reason: "当前范围内没有内容哈希一致的重复文件。可以换一个范围，或确认扫描包含了你关心的目录。",
                         actionTitle: "换一个范围", action: { state.pickFolder() })
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(state.duplicateGroups.count) 组 · 副本逻辑大小 \(ByteFormat.string(state.duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }))")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("每组默认保留最早修改的一份").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20).padding(.top, 12)

                List(state.duplicateGroups, id: \.id) { group in
                    DuplicateGroupRow(group: group)
                        .padding(.vertical, 4)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .padding(.horizontal, 12)
            }
        }
    }
}

struct DuplicateGroupRow: View {
    @Environment(AppState.self) private var state
    let group: DuplicateGroup
    @State private var selectedKeeper: Int?
    private var keepIndex: Int { selectedKeeper ?? group.recommendedKeepIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.on.doc").foregroundStyle(SLColor.scan)
                Text(group.candidates.first?.url.lastPathComponent ?? "重复组")
                    .font(.callout.weight(.medium))
                Text("×\(group.candidates.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("副本大小 \(ByteFormat.string(group.reclaimableBytes))")
                    .font(.callout.monospacedDigit())
                Button("加入清理清单") { addToCleanup() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Image(systemName: "number").font(.caption2).foregroundStyle(.tertiary)
                Text("SHA-256 \(group.digest.prefix(20))…").font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text("完整 SHA-256 一致").font(.caption2).foregroundStyle(SLColor.safe)
            }
            ForEach(Array(group.candidates.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Text(index == keepIndex ? "保留" : "副本")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(index == keepIndex ? SLColor.safe : .secondary)
                        .frame(width: 34, alignment: .leading)
                    Button("保留此文件") { selectedKeeper = index }
                        .buttonStyle(.borderless).disabled(index == keepIndex)
                    Text(item.url.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormat.string(item.logicalSize)).font(.caption.monospacedDigit())
                    Button { state.previewURLs([item.url]) } label: {
                        Image(systemName: "eye")
                    }.buttonStyle(.borderless).help("快速查看这个文件")
                }
            }
            if group.candidates.count > 1 {
                Text("已选择保留：\(group.candidates[keepIndex].url.lastPathComponent)；清理前会再次核对内容。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func addToCleanup() {
        let keep = group.candidates[keepIndex]
        guard let keepIdentity = keep.identity else { return }
        let keeper = DuplicateKeeper(path: keep.url.path, identity: keepIdentity, digest: group.digest)
        state.addCandidates(group.candidates.enumerated()
            .filter { $0.offset != keepIndex }
            .map { _, item in
                Candidate(nodeID: item.nodeID, path: item.url.path,
                          displayName: item.url.lastPathComponent,
                          ruleID: "duplicate.exact",
                          evidence: "完整 SHA-256 一致：\(group.digest.prefix(20))…；同组 \(group.candidates.count) 份，保留用户指定的一份",
                          confidence: 1.0, risk: .review,
                          consequence: "删除重复副本，保留的一份不受影响。",
                          rebuildable: false, recoverable: true,
                          logicalSize: item.logicalSize, category: .duplicates,
                          scannedIdentity: item.identity, scannedModificationDate: item.modificationDate,
                          duplicateKeeper: keeper, scannedChangeDate: item.changeDate)
            })
    }
}

// MARK: - 卸载残留

struct UninstallView: View {
    @Environment(AppState.self) private var state
    @State private var showInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if showInstalled { installedContent } else { content }
        }
        .task { state.ensureLeftovers() }
        .onChange(of: showInstalled) { _, value in if value { state.ensureInstalledApps() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("应用管理").font(.title2.weight(.semibold))
                    Text("查看常见位置的应用和疑似残留；未找到宿主不代表数据无用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("内容", selection: $showInstalled) {
                    Text("疑似残留").tag(false)
                    Text("已安装应用").tag(true)
                }.pickerStyle(.segmented).frame(width: 200)
                Menu("应用目录") {
                    Button("添加自定义目录…") { state.addApplicationRoot() }
                    if !state.customApplicationRoots.isEmpty {
                        Menu("移除自定义目录") {
                            ForEach(state.customApplicationRoots, id: \.self) { path in
                                Button(path) { state.removeApplicationRoot(path) }
                            }
                        }
                    }
                }
                Button("重新检测") {
                    if showInstalled { state.ensureInstalledApps(force: true) }
                    else { state.ensureLeftovers(force: true) }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    @ViewBuilder
    private var installedContent: some View {
        if state.installedAppsPhase == .running {
            ProgressView("正在读取应用清单…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading) {
                Text("\(state.installedApps.count) 个应用 · 覆盖标准应用目录及其嵌套工具目录")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 12)
                List(state.installedApps) { app in
                    HStack {
                        Image(systemName: "app").foregroundStyle(SLColor.scan)
                        VStack(alignment: .leading) {
                            HStack {
                                Text(app.name)
                                if app.isSystem { Text("系统应用").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(app.bundleID ?? "未找到 bundle id").font(.caption).foregroundStyle(.secondary)
                            Text(app.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("访达定位") { PermissionProbe.revealInFinder(URL(fileURLWithPath: app.path)) }
                            .buttonStyle(.bordered)
                    }
                }.listStyle(.inset(alternatesRowBackgrounds: true))
                Text("应用清单为只读；完整卸载功能尚未接入。可通过「应用目录」添加其他安装位置。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.leftoversPhase == .running {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在读取已安装应用的 bundle id 并比对关联目录…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.leftovers.isEmpty {
            SLEmptyState(title: "没有发现疑似残留",
                         reason: "已检查可访问的常见应用数据位置；权限、应用安装位置或命名方式可能影响检测结果。",
                         actionTitle: "重新检测", action: { state.ensureLeftovers(force: true) })
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(state.leftovers.count) 项 · 可计算项目的逻辑大小 \(ByteFormat.string(state.leftovers.reduce(0) { $0 + $1.estimatedBytes }))")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Text("未找到宿主不代表数据无用；自定义位置的应用可能未被识别")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20).padding(.top, 12)

                List(state.leftovers, id: \.id) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "app.badge.checkmark").foregroundStyle(SLColor.notice)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.displayName).font(.callout.weight(.medium)).lineLimit(1)
                                Text("疑似残留，请核对")
                                    .font(.caption2)
                                    .foregroundStyle(SLColor.notice)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(item.evidence).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(item.path).font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(item.directoryFingerprint == nil ? "无法完整读取" : ByteFormat.string(item.estimatedBytes)).font(.callout.monospacedDigit())
                            HStack(spacing: 6) {
                                Button { PermissionProbe.revealInFinder(URL(fileURLWithPath: item.path)) } label: {
                                    Image(systemName: "folder")
                                }.buttonStyle(.borderless).help("在访达中显示")
                                Button("加入") { addToCleanup(item) }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .disabled(item.directoryFingerprint == nil)
                                    .help(item.directoryFingerprint == nil ? "目录未能完整读取或检测时发生变化，不能加入清理" : "加入清理清单并逐项复核")
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .padding(.horizontal, 12)

                Text("提示：残留目录也可能被其他应用复用。请先在访达中确认内容，再决定是否清理。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }

    private func addToCleanup(_ item: LeftoverItem) {
        state.addCandidates([
            Candidate(nodeID: UUID(), path: item.path, displayName: item.displayName,
                      ruleID: "uninstall.leftover", evidence: item.evidence,
                      confidence: item.confidence, risk: .review,
                      consequence: "关联项移入废纸篓；若应用曾被重装，可能需要重新配置。",
                      rebuildable: false, recoverable: true,
                      logicalSize: item.estimatedBytes, category: .applications,
                      scannedIdentity: item.identity, scannedModificationDate: item.modificationDate,
                      leftoverBundleID: item.bundleID, scannedDirectoryFingerprint: item.directoryFingerprint,
                      scannedChangeDate: item.changeDate)
        ])
    }
}

// MARK: - 独立确认窗口（危险操作不进工具栏）

struct ConfirmDeletionView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false
    @State private var dryRun = true

    private var selected: [Candidate] { state.selectedCandidates }
    private var grouped: [(RiskLevel, [Candidate])] {
        RiskLevel.allCases.compactMap { level in
            let items = selected.filter { $0.risk == level }
            return items.isEmpty ? nil : (level, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("复核清理", systemImage: "trash").font(.title2.weight(.semibold))
            Text("所有项目只会移入废纸篓，可用 Shift+Cmd+Z 恢复。疏朗首版不提供永久删除。")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 16) {
                SLCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("计划字节").font(.caption).foregroundStyle(.secondary)
                        Text(ByteFormat.string(state.selectedBytes)).font(.title3.monospacedDigit())
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                SLCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("项目数").font(.caption).foregroundStyle(.secondary)
                        Text("\(selected.count)").font(.title3.monospacedDigit())
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                SLCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("处理方式").font(.caption).foregroundStyle(.secondary)
                        Text("移入废纸篓").font(.title3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("候选大小是估算；移入废纸篓后可用空间不会立刻增加，需要清空废纸篓。")
                .font(.caption).foregroundStyle(.tertiary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(grouped, id: \.0) { level, items in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                SLRiskBadge(level: level)
                                Text("\(items.count) 项").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("预览这组前 12 个") {
                                    state.previewURLs(items.prefix(12).map { URL(fileURLWithPath: $0.path) })
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            Text(level.explanation).font(.caption).foregroundStyle(.secondary)
                            // 全量列出，不再截断；LazyVStack 保证大清单也不卡。
                            ForEach(items, id: \.id) { item in
                                HStack(spacing: 8) {
                                    Text(item.path).font(.caption.monospacedDigit())
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(ByteFormat.string(item.logicalSize)).font(.caption.monospacedDigit())
                                    Button { state.previewURLs([URL(fileURLWithPath: item.path)]) } label: {
                                        Image(systemName: "eye")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("快速查看这个文件")
                                    Button { state.unselect(item) } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("从本次清理中移除")
                                }
                            }
                        }
                        .padding(10)
                        .background(SLColor.content, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 280)

            Toggle("先预演（dry-run，不写任何文件）", isOn: $dryRun)
            Toggle("我已逐项复核，确认将这些项目移入废纸篓", isOn: $acknowledged)
                .foregroundStyle(acknowledged ? .primary : .secondary)

            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(dryRun ? "运行预演" : "确认移入废纸篓") {
                    state.performCleanup(dryRun: dryRun)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(dryRun ? SLColor.scan : SLColor.danger)
                .disabled(!acknowledged)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 700, height: 620)
        .onAppear { dryRun = state.dryRunDefault }
    }
}

// MARK: - 历史与报告

struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var showUnverifiedConfirmation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SLSectionTitle("历史报告", detail: "扫描与清理记录只保存在本机，可导出 Markdown 或 JSON")
                HStack {
                    Button("导出 Markdown 报告") { state.exportMarkdown() }.disabled(state.report == nil)
                    Button("导出 JSON 数据") { state.exportJSON() }.disabled(state.report == nil)
                    Button("恢复上次清理") { state.restoreLastCleanup() }
                        .disabled((state.lastResult?.movedItems?.isEmpty ?? true) || state.pendingRecovery != nil || state.isRecoveringPending)
                }.buttonStyle(.bordered)

                if let pending = state.pendingRecovery {
                    SLCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("上次清理有未确认的项目", systemImage: "exclamationmark.triangle").font(.headline)
                            Text(pending.originalPath).font(.caption).textSelection(.enabled)
                            Text("请检查原位置和访达废纸篓。未确认前，疏朗会暂停后续清理。")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("重新核查") { state.retryInterruptedRecovery() }
                                Button("在访达中查看原位置") { PermissionProbe.revealInFinder(URL(fileURLWithPath: pending.originalPath)) }
                                Button("已核查，标为无法验证…") { showUnverifiedConfirmation = true }
                            }.buttonStyle(.bordered).disabled(state.isRecoveringPending)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                let unverified = AuditLog.shared.history.flatMap { $0.unverifiedItems ?? [] }
                if !unverified.isEmpty {
                    SLCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("无法验证的历史项目", systemImage: "questionmark.folder").font(.headline)
                            ForEach(Array(unverified.enumerated()), id: \.offset) { _, item in
                                Text(item.originalPath).font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let report = state.report {
                    SLCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("最近扫描", systemImage: "magnifyingglass").font(.headline)
                            InfoLine("范围", report.rootPath)
                            InfoLine("耗时", String(format: "%.2f 秒", report.duration))
                            InfoLine("条目 / 文件", "\(report.totalNodes) / \(report.totalFiles)")
                            InfoLine("已分配空间估算 / 逻辑大小", "\(ByteFormat.string(report.scannedAllocatedBytes)) / \(ByteFormat.string(report.scannedLogicalBytes))")
                            InfoLine("无法访问", "\(report.inaccessibleCount) 处")
                            InfoLine("规则版本", report.rulesVersion)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let result = state.lastResult {
                    SLCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("最近清理事务", systemImage: "trash").font(.headline)
                            InfoLine("计划字节", ByteFormat.string(result.plan.totalEstimatedBytes))
                            InfoLine("实际移入废纸篓", ByteFormat.string(result.actuallyMovedBytes))
                            InfoLine("成功 / 失败", "\(result.succeededCount) / \(result.failedCount)")
                            if let moved = result.movedItems, !moved.isEmpty {
                                DisclosureGroup("已移入废纸篓：\(moved.count) 项") {
                                    LazyVStack(alignment: .leading) {
                                        ForEach(Array(moved.enumerated()), id: \.offset) { _, item in
                                            Text(item.originalPath).font(.caption).textSelection(.enabled)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if !result.failures.isEmpty {
                                DisclosureGroup("失败或跳过：\(result.failures.count) 项") {
                                    LazyVStack(alignment: .leading) {
                                        ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                                            Text(failure).font(.caption).textSelection(.enabled)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Text("计划字节与实际移入量分开记录，避免「数字变了但空间没变」的误判。")
                                .font(.caption).foregroundStyle(.tertiary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let restored = state.lastRestoreResult, !restored.items.isEmpty {
                    SLCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("最近恢复结果", systemImage: "arrow.uturn.backward").font(.headline)
                            ForEach(Array(restored.items.enumerated()), id: \.offset) { _, item in
                                Text("\(item.message)：\(item.path)").font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                SLCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("两次扫描差异", systemImage: "arrow.left.arrow.right").font(.headline)
                        if !state.diffAvailable {
                            Text("两次扫描范围、覆盖区域和选项一致时，可比较文件变化。")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if state.diffEntries.isEmpty {
                            Text("两次扫描未发现文件变化。")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(state.diffEntries.prefix(30)) { entry in
                                HStack {
                                    Text(entry.change.rawValue).font(.caption2)
                                        .foregroundStyle(SLColor.scan)
                                        .frame(width: 52, alignment: .leading)
                                    Text(entry.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                    if let oldPath = entry.oldPath {
                                        Text("原位置：\(oldPath)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(ByteFormat.string(abs(entry.deltaBytes)))
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
        .confirmationDialog("确认已检查原位置和废纸篓？", isPresented: $showUnverifiedConfirmation) {
            Button("标为无法验证并继续", role: .destructive) { state.markPendingUnverified() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("该项目不会被标记为成功，也不能由疏朗自动恢复。记录会保留，本操作不会移动或删除文件。")
        }
    }
}
