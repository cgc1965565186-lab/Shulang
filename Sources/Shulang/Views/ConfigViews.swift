import SwiftUI
import ShulangCore

// MARK: - 规则

struct RulesView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SLSectionTitle("清理规则", detail: "版本 \(state.ruleSet.version) · 规则是纯数据，导入时校验 id 唯一性、路径模式与后果说明")
                HStack {
                    Button("导出规则包") { state.exportRules() }
                    Button("导入规则包…") { state.importRules() }
                    Button("恢复内置规则") { state.ruleSet = .builtin; state.toast = "已恢复 \(RuleSet.builtin.rules.count) 条内置规则" }
                    Spacer()
                    Text("\(state.ruleSet.rules.count) 条 · 启用 \(state.ruleSet.enabledRules().count) 条")
                        .font(.callout).foregroundStyle(.secondary)
                }.buttonStyle(.bordered)

                SLCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("社区规则包", systemImage: "person.3").font(.headline)
                        Text("开源仓库接受规则 PR：纯 JSON、经 Schema 白名单校验、跑同一套 fixture 测试、由维护者签名后才会进入内置集。自行导入的第三方规则不参与「只选可重建项」的自动选择。")
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                ForEach(Array(state.ruleSet.rules.indices), id: \.self) { index in
                    let rule = state.ruleSet.rules[index]
                    SLCard {
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { state.ruleSet.rules[index].enabled },
                                set: { state.ruleSet.rules[index].enabled = $0 }
                            )).labelsHidden()
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(rule.title).font(.callout.weight(.medium))
                                    SLRiskBadge(level: rule.risk)
                                    Text(rule.id).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                                Text("删除后果：\(rule.consequence)").font(.caption).foregroundStyle(.secondary)
                                Text("分类 \(rule.category.title) · 最小年龄 \(rule.minAgeDays) 天 · 最小大小 \(ByteFormat.string(rule.minSizeBytes)) · \(rule.rebuildable ? "会自动重建" : "不会自动重建")")
                                    .font(.caption).foregroundStyle(.tertiary)
                                Text(rule.pathPatterns.joined(separator: "  ·  "))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        }
        .disabled(state.phase == .scanning || state.phase == .deleting)
    }
}

// MARK: - 自动化

struct AutomationView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SLSectionTitle("自动化", detail: "默认关闭；即使开启也只提醒与生成计划，不会在后台自动删除")
                SLCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(get: { state.automationEnabled },
                                             set: { state.automationEnabled = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("空间水位提醒").font(.callout.weight(.medium))
                                Text("可用空间低于 10% 时给出提示").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("立即检查当前卷水位") { state.checkDiskWatermark() }
                            .buttonStyle(.bordered)
                        Divider()
                        Label("设计约束", systemImage: "hand.raised").font(.headline)
                        Text("· 任何自动执行都需要用户显式开启，且先移入废纸篓并留下审计记录。\n· 退出后不留后台进程；不安装 LaunchDaemon。\n· 高频全量重扫会增加 SSD 写入，增量扫描只重算变化区域。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - 设置（独立 Settings 场景）

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var snapshotReport: String?
    @State private var loadingSnapshots = false
    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gear") }
            volumeTab.tabItem { Label("卷与排除", systemImage: "internaldrive") }
            privacyTab.tabItem { Label("隐私", systemImage: "hand.raised") }
            advancedTab.tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 540, height: 380)
        .padding(16)
    }

    private var generalTab: some View {
        Form {
            Picker("扫描枚举器", selection: Binding(get: { state.enumerator },
                                                    set: { state.enumerator = $0 })) {
                ForEach(EnumeratorKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("Foundation 为默认；getattrlistbulk 在不支持的文件系统上自动回落。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("包含隐藏文件", isOn: Binding(get: { state.includeHidden }, set: { state.includeHidden = $0 }))
            Toggle("清理默认先预演", isOn: Binding(get: { state.dryRunDefault }, set: { state.dryRunDefault = $0 }))
            Toggle("显示检查器", isOn: Binding(get: { state.showInspector }, set: { state.showInspector = $0 }))
        }
        .formStyle(.grouped)
    }

    private var volumeTab: some View {
        Form {
            Section("已挂载卷") {
                ForEach(state.volumes) { volume in
                    Button {
                        state.selectVolume(volume)
                    } label: {
                        HStack {
                            Image(systemName: volume.isExternal ? "externaldrive" : "internaldrive")
                            Text(volume.name)
                            Spacer()
                            Text(ByteFormat.string(volume.availableBytes)).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Section("始终排除") {
                Text("云盘与 File Provider 目录、系统目录、签名应用内部、凭据存储、不安全符号链接路径。这些限制在引擎层生效，与界面是否显示无关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Time Machine 本地快照") {
                Button("只读查看当前卷的本地快照") {
                    guard let volume = state.selectedVolume else { return }
                    loadingSnapshots = true
                    snapshotReport = nil
                    Task {
                        let result = await Task.detached { () -> String in
                            do { return try TimeMachineInspector.localSnapshots(volume: volume.mountPoint) }
                            catch { return "读取失败：\(error.localizedDescription)" }
                        }.value
                        snapshotReport = result
                        loadingSnapshots = false
                    }
                }.disabled(loadingSnapshots || state.selectedVolume == nil)
                Text("仅列出系统报告的快照，不删除快照，也不估算可释放空间。")
                    .font(.caption).foregroundStyle(.secondary)
                if loadingSnapshots { ProgressView("正在读取…") }
                if let snapshotReport { Text(snapshotReport).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            LabeledContent("网络请求", value: "默认零")
            LabeledContent("遥测 / 账号", value: "无")
            LabeledContent("数据存储", value: "仅本机 Application Support/Shulang")
            Text("报告、扫描快照与事务日志全部本地生成；更新检查当前版本未启用。")
                .font(.caption).foregroundStyle(.secondary)
            Button("重新检测完全磁盘访问") { state.refreshFDA() }
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            LabeledContent("规则版本", value: state.ruleSet.version)
            LabeledContent("部署目标", value: "macOS 14+ · universal2")
            LabeledContent("许可证", value: "Apache-2.0")
            Button("查看使用说明") { state.showOnboarding = true }
            Text("规则更改后会重新计算候选；切换枚举器或隐藏项设置后，需要重新扫描。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - 首次引导（四步）

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var step = 0

    private let steps: [(symbol: String, title: String, detail: String, action: String)] = [
        ("folder", "选择扫描范围",
         "默认是你的个人文件夹；也可以选整卷，或直接把文件夹拖进窗口。系统保护路径永远不会被清理。", "选择范围"),
        ("lock.shield", "按需授权（可选）",
         "完全磁盘访问可改善对受保护位置的访问；实际覆盖以每次扫描结果为准。不授权也可以扫描可访问的个人文件夹。", "打开系统设置"),
        ("magnifyingglass", "只读扫描",
         "扫描不会修改或删除任何文件。每一项都会标注命中规则、证据、风险等级和删除后果。", "立即扫描"),
        ("checkmark.shield", "勾选 → 预览 → 复核",
         "默认零勾选。先点眼睛图标快速查看内容，再复核移入废纸篓；随时可以用 Shift+Cmd+Z 恢复。", "进入清理清单")
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "leaf.circle.fill").font(.system(size: 44))
                    .foregroundStyle(SLColor.safe)
                Text("疏朗").font(.largeTitle.weight(.semibold))
                Text("看清空间，安心释放").font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(0..<steps.count, id: \.self) { index in
                    stepCard(index)
                }
            }

            HStack {
                Button("以后再说") { state.completeOnboarding() }
                Spacer()
                if step > 0 { Button("上一步") { step -= 1 } }
                if step < steps.count - 1 {
                    Button("下一步") { step += 1 }
                }
                Button("开始使用") {
                    state.completeOnboarding()
                    state.selection = .cleanup
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 620, height: 620)
    }

    private func stepCard(_ index: Int) -> some View {
        let item = steps[index]
        let active = index == step
        let done = index < step
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? SLColor.safe : (active ? SLColor.scan : Color.secondary.opacity(0.15)))
                    .frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Image(systemName: item.symbol).font(.caption.weight(.bold))
                        .foregroundStyle(active ? .white : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.callout.weight(active ? .semibold : .regular))
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if active {
                    Button(item.action) { perform(index) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(active ? SLColor.scan.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
        .opacity(done || active ? 1 : 0.55)
    }

    private func perform(_ index: Int) {
        switch index {
        case 0:
            if state.pickFolder() != nil { step = min(steps.count - 1, step + 1) }
        case 1:
            state.openFDASettings()
            step = min(steps.count - 1, step + 1)
        case 2:
            state.completeOnboarding()
            state.startQuickStart()
        default:
            state.completeOnboarding()
            state.selection = .cleanup
        }
    }
}
