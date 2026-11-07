import SwiftUI
import AppKit
import ShulangCore

// 计划 5.4 节的设计令牌：浅/深双主题、系统强调色、4/8pt 基线。
enum SLColor {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let window = dynamic(light: NSColor(calibratedWhite: 0.96, alpha: 1),
                                dark: NSColor(calibratedWhite: 0.118, alpha: 1))
    static let sidebar = dynamic(light: NSColor(calibratedWhite: 0.98, alpha: 1),
                                 dark: NSColor(calibratedWhite: 0.098, alpha: 1))
    static let content = dynamic(light: .white, dark: NSColor(calibratedWhite: 0.141, alpha: 1))
    static let card = dynamic(light: NSColor(calibratedWhite: 0.995, alpha: 1),
                              dark: NSColor(calibratedWhite: 0.165, alpha: 1))
    static let separator = dynamic(light: NSColor(calibratedWhite: 0, alpha: 0.08),
                                   dark: NSColor(calibratedWhite: 1, alpha: 0.09))

    static let scan = Color(hex: 0x2E7CF6)
    static let safe = Color(hex: 0x34A853)
    static let notice = Color(hex: 0xF2A33C)
    static let danger = Color(hex: 0xE35A54)
    static let accentPurple = Color(hex: 0xBF5AF2)

    static func risk(_ level: RiskLevel) -> Color {
        switch level { case .safe: return safe; case .review: return notice; case .caution: return danger }
    }

    /// 最多 12 个语义色相，用于树图分类，配合 7.5% 明度分层。
    private static let palette: [Color] = [
        Color(hex: 0x2E7CF6), Color(hex: 0x34A853), Color(hex: 0xF2A33C),
        Color(hex: 0xE35A54), Color(hex: 0xBF5AF2), Color(hex: 0x64D2CB),
        Color(hex: 0x5E8CE6), Color(hex: 0xFF7B9C), Color(hex: 0x9AB64C),
        Color(hex: 0xE0A24A), Color(hex: 0x7B7FE0), Color(hex: 0x4FA8A1)
    ]
    /// 显式映射，不依赖 hashValue 的随机 seed：同分类跨启动颜色恒定、不同分类不撞色（P0-A5）。
    static func category(_ kind: CategoryKind) -> Color {
        switch kind {
        case .caches: return palette[0]
        case .logs: return palette[1]
        case .temporary: return palette[2]
        case .downloads: return palette[3]
        case .developer: return palette[4]
        case .applications: return palette[5]
        case .trash: return palette[6]
        case .mediaMail: return palette[7]
        case .largeFiles: return palette[8]
        case .duplicates: return palette[9]
        case .other: return palette[10]
        case .protected: return palette[11]
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

enum SLMetrics {
    static let sidebarWidth: CGFloat = 220
    static let inspectorWidth: CGFloat = 300
    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 16
    static let cardCorner: CGFloat = 12
}

struct SLCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(SLMetrics.padding)
            .background(SLColor.card)
            .clipShape(RoundedRectangle(cornerRadius: SLMetrics.cardCorner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SLMetrics.cardCorner, style: .continuous)
                .stroke(SLColor.separator, lineWidth: 1))
    }
}

struct SLSectionTitle: View {
    let title: String
    let detail: String?
    init(_ title: String, detail: String? = nil) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title2).fontWeight(.semibold)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

/// 空状态必须包含对象、动作、限制原因与主按钮（计划 5.4 节）。
struct SLEmptyState: View {
    let title: String
    let reason: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash").font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3).fontWeight(.medium)
            Text(reason).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SLRiskBadge: View {
    let level: RiskLevel
    var body: some View {
        Label(level.title, systemImage: level.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(SLColor.risk(level).opacity(0.14))
            .foregroundStyle(SLColor.risk(level))
            .clipShape(Capsule())
    }
}
