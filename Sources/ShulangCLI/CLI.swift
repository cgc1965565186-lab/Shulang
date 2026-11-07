import Foundation
import ShulangCore

// 疏朗 CLI —— 与 GUI 共用 ShulangCore，dry-run 默认、风险项默认隐藏、稳定退出码。
// exit code: 0 成功 / 1 参数错误 / 2 扫描失败 / 3 权限或路径拒绝 / 4 导出失败 / 5 规则校验失败

private let arguments = Array(CommandLine.arguments.dropFirst())

private func usage() -> String {
    """
    疏朗 shulang \(ShulangVersion.current) — 可解释的空间回收

    用法:
      shulang volumes                          列出已挂载卷
      shulang fda                             检测完全磁盘访问状态
      shulang scan <路径> [--hidden] [--enumerator bulk|foundation] [--json <文件>] [--snapshot-out <文件>]
      shulang duplicates <路径> [--hidden]
      shulang candidates <路径> [--markdown <文件>] [--include-risky]
      shulang rules export <文件> | rules import <文件>
      shulang diff <路径> --snapshot <文件>   与上次快照对比
      shulang benchmark <路径>                对比两种枚举器耗时

    默认只报告安全级候选；风险项需 --include-risky 显式开启。
    """
}

private func flag(_ name: String) -> Bool { arguments.contains(name) }
private func value(after name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
private func path(at index: Int) -> String? { arguments.indices.contains(index) ? arguments[index] : nil }

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("错误：\(message)\n").utf8))
    exit(code)
}

@main
struct ShulangCLI {
    static func main() {
        guard let command = arguments.first else { print(usage()); exit(0) }

        switch command {
        case "--help", "-h", "help": print(usage())
        case "version": print(ShulangVersion.current)

        case "volumes":
            for volume in VolumeProvider.currentVolumes() {
                print("\(volume.name)\t\(ByteFormat.string(volume.totalBytes))\t可用 \(ByteFormat.string(volume.availableBytes))\t\(volume.mountPoint.path)")
            }

        case "fda":
            print("受保护目录探测：\(PermissionProbe.fullDiskAccess().title)（仅检查样本目录，实际覆盖以扫描结果为准）")

        case "rules":
            guard let sub = path(at: 1), let file = path(at: 2) else { fail("用法: shulang rules export|import <文件>", code: 1) }
            if sub == "export" {
                guard let data = try? RuleSet.builtin.exportJSON() else { fail("规则导出失败", code: 4) }
                do { try data.write(to: URL(fileURLWithPath: file)); print("已导出 \(RuleSet.builtin.rules.count) 条规则 → \(file)") }
                catch { fail("写入失败：\(error)", code: 4) }
            } else if sub == "import" {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: file))
                    let set = try RuleSet.importJSON(data)
                    print("规则校验通过：\(set.rules.count) 条，版本 \(set.version)")
                } catch { fail("规则校验失败：\(error)", code: 5) }
            } else { fail("未知子命令 \(sub)", code: 1) }

        case "scan", "duplicates", "candidates", "diff", "benchmark":
            guard let rawPath = path(at: 1) else { fail("缺少扫描路径", code: 1) }
            let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { fail("路径不存在：\(url.path)", code: 3) }

            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    var limits = ScanLimits()
                    limits.includeHidden = flag("--hidden")
                    limits.enumerator = value(after: "--enumerator") == "bulk" ? .bulk : .foundation
                    let outcome = try await ScanEngine().scan(url: url, limits: limits) { _ in }
                    let report = outcome.report

                    switch command {
                    case "scan":
                        print("扫描结束：\(report.totalNodes) 项 / 文件 \(report.totalFiles) 项 / 逻辑 \(ByteFormat.string(report.scannedLogicalBytes)) / 已分配估算 \(ByteFormat.string(report.scannedAllocatedBytes))")
                        print("耗时 \(String(format: "%.2f", report.duration))s · 枚举器 \(report.enumeratorName) · 无法访问 \(report.inaccessibleCount) 处")
                        print("覆盖状态：\(report.completionStatus ?? "unknown")")
                        if let snapshotPath = value(after: "--snapshot-out") {
                            do {
                                let data = try JSONEncoder().encode(ScanSnapshot(outcome: outcome))
                                try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
                                print("扫描快照 → \(snapshotPath)")
                            } catch { fail("快照导出失败：\(error)", code: 4) }
                        }
                        if let jsonPath = value(after: "--json") {
                            let candidates = RiskEngine.makeCandidates(root: outcome.root)
                            do {
                                let data = try Reporting.json(report: report, candidates: candidates)
                                try data.write(to: URL(fileURLWithPath: jsonPath))
                                print("报告 → \(jsonPath)")
                            } catch { fail("报告导出失败：\(error)", code: 4) }
                        }
                    case "duplicates":
                        let groups = DuplicateEngine.find(root: outcome.root)
                        print("重复组 \(groups.count) 组，副本逻辑大小 \(ByteFormat.string(groups.reduce(0) { $0 + $1.reclaimableBytes }))")
                        for group in groups.prefix(30) {
                            print("  [\(ByteFormat.string(group.reclaimableBytes))] \(group.candidates.first?.url.lastPathComponent ?? "") ×\(group.candidates.count) · \(group.digest.prefix(12))")
                        }
                        if groups.count > 30 { print("仅显示前 30 组，共 \(groups.count) 组") }
                    case "candidates":
                        var candidates = RiskEngine.makeCandidates(root: outcome.root)
                        if !flag("--include-risky") { candidates = candidates.filter { $0.risk == .safe } }
                        let summary = RiskEngine.summary(candidates)
                        print("候选 \(candidates.count) 项：安全 \(ByteFormat.string(summary.safe)) / 复核 \(ByteFormat.string(summary.review)) / 谨慎 \(ByteFormat.string(summary.caution))")
                        if let markdownPath = value(after: "--markdown") {
                            let text = Reporting.markdown(report: report, candidates: candidates)
                            do { try text.write(toFile: markdownPath, atomically: true, encoding: .utf8); print("报告 → \(markdownPath)") }
                            catch { fail("报告导出失败：\(error)", code: 4) }
                        } else {
                            for candidate in candidates.prefix(20) {
                                print("  \(candidate.risk.title)\t\(ByteFormat.string(candidate.logicalSize))\t\(candidate.path)")
                            }
                            if candidates.count > 20 { print("仅显示前 20 项，共 \(candidates.count) 项") }
                        }
                    case "diff":
                        guard let snapshot = value(after: "--snapshot") else { fail("diff 需要 --snapshot <文件>", code: 1) }
                        let data = try Data(contentsOf: URL(fileURLWithPath: snapshot))
                        let previous = try JSONDecoder().decode(ScanSnapshot.self, from: data)
                        let current = ScanSnapshot(outcome: outcome)
                        guard previous.canCompare(to: current) else {
                            fail("快照版本、范围或扫描覆盖不一致，无法可靠比较", code: 2)
                        }
                        let changes = DiffEngine.compare(old: previous, new: current)
                        print("文件变化：\(changes.count) 项")
                        for entry in changes {
                            let previousPath = entry.oldPath.map { "\($0) → " } ?? ""
                            print("\(entry.change.rawValue)\t\(entry.deltaBytes)\t\(previousPath)\(entry.path)")
                        }
                    case "benchmark":
                        for kind in EnumeratorKind.allCases {
                            var runLimits = limits
                            runLimits.enumerator = kind
                            let start = Date()
                            let result = try await ScanEngine().scan(url: url, limits: runLimits) { _ in }
                            print("\(kind.title)：\(String(format: "%.2f", Date().timeIntervalSince(start)))s，\(result.report.totalNodes) 项")
                        }
                    default: break
                    }
                } catch {
                    FileHandle.standardError.write(Data(("扫描失败：\(error)\n").utf8))
                    exit(2)
                }
                semaphore.signal()
            }
            semaphore.wait()

        default:
            fail("未知命令 \(command)\n\n\(usage())", code: 1)
        }
        // 显式结束，避免 Swift 运行时的主调度循环让 CLI 保持常驻。
        exit(0)
    }
}
