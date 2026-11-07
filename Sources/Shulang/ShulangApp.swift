import SwiftUI
import AppKit
import ShulangCore

@main
struct ShulangApp: App {
    @State private var state: AppState
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    private static var instanceLock: SingleInstanceLock?

    init() {
        let current = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != current }) {
            existing.activate(options: [])
            exit(0)
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let lock = SingleInstanceLock(directory: base.appendingPathComponent("Shulang", isDirectory: true)) else {
            let alert = NSAlert()
            alert.messageText = "无法启动疏朗"
            alert.informativeText = "另一个实例可能正在运行，或无法访问本地历史目录。请关闭其他实例并检查目录权限。"
            alert.runModal()
            exit(1)
        }
        Self.instanceLock = lock
        _state = State(initialValue: AppState())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1240, height: 800)
        .commands {
            // 保留「新建窗口」：多窗口可以同时看不同范围。
            CommandMenu("扫描") {
                Button("开始 / 重新扫描") { state.startScan(destination: .cleanup) }
                    .keyboardShortcut("r", modifiers: .command)
                Button("选择扫描范围…") { state.pickFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("暂停 / 继续") { state.pauseScan() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("取消扫描") { state.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            CommandMenu("清理") {
                Button("全选当前列表") { state.selectAllVisible() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("只选择可重建项") { state.selectSafeOnly() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("反选") { state.invertVisibleSelection() }
                Button("清空选择") { state.deselectAll() }
                Divider()
                Button("预览选中项") { state.previewSelected() }
                Button("复核并清理…") { state.cleanSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(after: .undoRedo) {
                Button("恢复上次清理") { state.restoreLastCleanup() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("显示") {
                Button("搜索清理清单") { state.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("检查器") { state.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
                Divider()
                Button("矩形树图") { state.displayMode = .treemap }
                    .keyboardShortcut("1", modifiers: .option)
                Button("旭日图") { state.displayMode = .sunburst }
                    .keyboardShortcut("2", modifiers: .option)
                Button("列表") { state.displayMode = .list }
                    .keyboardShortcut("3", modifiers: .option)
            }
            CommandGroup(replacing: .help) {
                Button("查看使用引导") { state.reopenOnboarding() }
                Button("导出空间报告") { state.exportMarkdown() }
                    .disabled(state.report == nil)
            }
        }

        Settings {
            SettingsView().environment(state)
        }
    }
}

final class AppLifecycle: NSObject, NSApplicationDelegate, @unchecked Sendable {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 轻量启动诊断：记录启动时间、可见窗口数与激活策略，便于在无图形会话时也能确认启动链路。
        // 仅写本机 Application Support，不含任何用户数据。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let windows = NSApp.windows.filter { $0.isVisible }.count
            let line = "\(ISO8601DateFormatter().string(from: Date())) visibleWindows=\(windows) policy=\(NSApp.activationPolicy().rawValue)\n"
            let fm = FileManager.default
            guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let dir = base.appendingPathComponent("Shulang", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? line.data(using: .utf8)?.write(to: dir.appendingPathComponent("launch.log"))
        }
    }

    /// 关闭最后一个窗口时不退出：用户常把窗口关掉去处理别的事，
    /// 再次点 Dock 图标应能直接回到工作状态，而不是重新启动。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows { window.makeKeyAndOrderFront(nil) }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
