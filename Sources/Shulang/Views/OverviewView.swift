import SwiftUI
import ShulangCore

/// 开始页：只回答三个问题——现在在哪一步、下一步点什么、点了会发生什么。
struct OverviewView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("从这里开始").font(.title2.weight(.semibold))
                    Text("四步：选范围 → 扫描 → 在清单里勾选 → 复核后移入废纸篓。扫描是只读的，清理后可尝试恢复。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WorkflowSteps(current: state.workflowStep)
                    .padding(.vertical, 4)

                startCard

                if state.fdaStatus != .granted {
                    fdaBanner
                }

                if let volume = state.selectedVolume {
                    volumeCard(volume)
                }

                HStack(alignment: .top, spacing: 14) {
                    entryCard(
                        title: "空间地图",
                        detail: "矩形树图看清每个文件夹占多少",
                        symbol: "square.grid.2x2",
                        badge: state.hasResults ? "已就绪" : "需先扫描",
                        enabled: state.hasResults
                    ) { state.selection = .space }

                    entryCard(
                        title: "重复文件",
                        detail: "内容完全一致的副本，字节级核对",
                        symbol: "doc.on.doc",
                        badge: state.duplicatesPhase == .running ? "检测中…" : (state.duplicateGroups.isEmpty ? "未检测" : "\(state.duplicateGroups.count) 组"),
                        enabled: state.hasResults
                    ) { state.selection = .duplicates }

                    entryCard(
                        title: "疑似残留",
                        detail: "检查可能与应用有关的目录",
                        symbol: "app.badge.checkmark",
                        badge: state.leftoversPhase == .running ? "检测中…" : (state.leftovers.isEmpty ? "未检测" : "\(state.leftovers.count) 项"),
                        enabled: true
                    ) { state.selection = .uninstall }
                }
            }
            .padding(24)
        }
    }

    // MARK: - 主操作卡

    private var startCard: some View {
        SLCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("扫描范围").font(.caption).foregroundStyle(.secondary)
                        Text(rangeTitle).font(.title3.weight(.semibold))
                        Text(state.currentRangeLabel)
                            .font(.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Menu {
                        Button("个人文件夹（推荐，快）") {
                            state.setRange(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
                        }
                        Button("下载文件夹") {
                            state.setRange(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads", isDirectory: true))
                        }
                        Divider()
                        ForEach(state.volumes) { volume in
                            Button("\(volume.name)（整卷，较慢）") { state.selectVolume(volume) }
                        }
                        Divider()
                        Button("选择其他文件夹…") { state.pickFolder() }
                    } label: {
                        Label("更换范围", systemImage: "folder")
                    }
                    .frame(width: 140)
                }

                if state.phase == .scanning {
                    scanningBlock
                } else {
                    HStack(spacing: 10) {
                        Button {
                            state.startQuickStart()
                        } label: {
                            Label(state.hasResults ? "重新扫描" : "一键开始扫描", systemImage: "play.fill")
                                .frame(minWidth: 130)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if state.hasResults {
                            Button {
                                state.selection = .cleanup
                            } label: {
                                Label("去清理清单（\(state.candidates.count) 项）", systemImage: "checklist")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        Spacer()
                        Text("只读扫描，不会修改或删除任何文件")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }

                if let report = state.report, state.phase != .scanning {
                    Divider()
                    HStack(spacing: 16) {
                        summaryMetric("扫描条目", "\(report.totalNodes)")
                        summaryMetric("已分配空间估算", ByteFormat.string(report.scannedAllocatedBytes))
                        summaryMetric("候选", "\(state.candidates.count) 项")
                        summaryMetric("候选逻辑大小", ByteFormat.string(state.candidateTotalBytes))
                        Spacer()
                    }
                }
            }
        }
    }

    private var scanningBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().progressViewStyle(.linear)
            if let progress = state.progress {
                HStack {
                    Text("已扫描 \(progress.scannedItems) 项 · 已分配空间估算 \(ByteFormat.string(progress.scannedAllocatedBytes))")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Text(progress.currentPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if progress.isPaused {
                    Text("已暂停，已扫描结果会保留").font(.caption).foregroundStyle(SLColor.notice)
                }
            }
            HStack {
                Button(state.progress?.isPaused == true ? "继续" : "暂停") { state.pauseScan() }
                    .disabled(state.isIncrementalUpdate)
                Button("取消扫描") { state.cancelScan() }
                Spacer()
                Text("可以切到其他页面，扫描会继续")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .buttonStyle(.bordered)
        }
    }

    private func summaryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
    }

    private var fdaBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").foregroundStyle(SLColor.notice)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.fdaStatus == .denied ? "部分受保护目录无法访问" : "尚无法确认受保护目录的访问范围").font(.callout.weight(.medium))
                Text("仍可扫描当前可访问的区域；授权可能改善覆盖，实际范围以扫描结果为准。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("去授权") { state.openFDASettings() }
            Button("重新检测") { state.refreshFDA() }
        }
        .buttonStyle(.bordered)
        .padding(14)
        .background(SLColor.notice.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SLColor.notice.opacity(0.25)))
    }

    private func volumeCard(_ volume: VolumeInfo) -> some View {
        SLCard {
            HStack(spacing: 24) {
                CapacityRing(fraction: volume.usageFraction)
                    .frame(width: 116, height: 116)
                VStack(alignment: .leading, spacing: 8) {
                    Text(volume.name).font(.title3.weight(.semibold))
                    MetricRow(label: "总容量", value: ByteFormat.string(volume.totalBytes))
                    MetricRow(label: "已使用", value: ByteFormat.string(volume.usedBytes))
                    MetricRow(label: "可用", value: ByteFormat.string(volume.availableBytes))
                    MetricRow(label: "可用（含可清除）", value: ByteFormat.string(volume.importantAvailableBytes))
                    if let freed = state.lastFreedBytes, let at = state.lastCleanupAt {
                        Text("上次移入废纸篓 \(ByteFormat.string(freed)) · \(at.formatted(date: .omitted, time: .shortened))（清空废纸篓后可用空间可能增加）")
                            .font(.caption).foregroundStyle(SLColor.safe)
                    } else {
                        Text("容量取自系统卷信息；已分配空间之和不能代表唯一物理占用或确定可释放的空间。")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
        }
    }

    private func entryCard(title: String, detail: String, symbol: String, badge: String,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.title3).foregroundStyle(SLColor.scan)
                    Spacer()
                    Text(badge).font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(SLColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(SLColor.separator))
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var rangeTitle: String {
        guard let range = state.currentRange else { return "未选择" }
        let home = NSHomeDirectory()
        if range.path == home { return "个人文件夹" }
        if range.path == home + "/Downloads" { return "下载文件夹" }
        if range.path == "/" { return "整卷" }
        return range.lastPathComponent
    }
}

struct WorkflowSteps: View {
    let current: Int
    private let labels = ["选范围", "扫描", "复核", "清理"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let step = index + 1
                let done = step < current
                let active = step == current
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(done ? SLColor.safe : (active ? SLColor.scan : Color.secondary.opacity(0.16)))
                            .frame(width: 22, height: 22)
                        if done {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        } else {
                            Text("\(step)").font(.caption2.weight(.bold))
                                .foregroundStyle(active ? .white : .secondary)
                        }
                    }
                    Text(label)
                        .font(.caption.weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? .primary : .secondary)
                }
                if index < labels.count - 1 {
                    Rectangle()
                        .fill(done ? SLColor.safe.opacity(0.5) : SLColor.separator)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前第 \(current) 步，共 4 步：选范围、扫描、复核、清理")
    }
}

// MARK: - 通用小组件

struct MetricRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    var body: some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(color)
        }
    }
}

struct CapacityRing: View {
    let fraction: Double
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 10
            let track = Path { path in
                path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
            }
            context.stroke(track, with: .color(SLColor.separator), lineWidth: 13)
            let clamped = min(1, max(0, fraction))
            let end = Angle.degrees(-90 + 360 * clamped)
            let value = Path { path in
                path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: end, clockwise: false)
            }
            context.stroke(value, with: .color(SLColor.scan), style: StrokeStyle(lineWidth: 13, lineCap: .round))
            let percent = Text("\(Int(clamped * 100))%").font(.title2.weight(.semibold))
            context.draw(percent, at: CGPoint(x: center.x, y: center.y - 6), anchor: .center)
            let caption = Text("已使用").font(.caption).foregroundColor(.secondary)
            context.draw(caption, at: CGPoint(x: center.x, y: center.y + 16), anchor: .center)
        }
        .accessibilityLabel("磁盘使用率 \(Int(min(1, max(0, fraction)) * 100))%")
    }
}
