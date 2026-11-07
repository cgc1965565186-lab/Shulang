import SwiftUI
import ShulangCore

// 矩形树图与旭日图共享同一棵 ScanNode 树，切换零重扫；布局结果按 key 缓存，
// 不再在 SwiftUI body 内每次重算（P0-E1/E2，切页面卡顿的主因之一）。

struct TreemapView: View {
    @Environment(AppState.self) private var state
    let node: ScanNode

    @State private var tiles: [TreemapTile] = []
    @State private var cacheKey = ""

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Canvas { context, _ in
                    for tile in tiles {
                        let rect = CGRect(x: tile.rect.x * size.width,
                                          y: tile.rect.y * size.height,
                                          width: max(1, tile.rect.width * size.width - 1),
                                          height: max(1, tile.rect.height * size.height - 1))
                        let color = tile.isCluster ? Color.gray.opacity(0.5) : SLColor.category(tile.category)
                        let selected = state.selectedNode?.id == tile.nodeID
                        context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                     with: .color(color.opacity(selected ? 0.95 : 0.72)))
                        if selected {
                            context.stroke(Path(roundedRect: rect, cornerRadius: 2),
                                           with: .color(.white), lineWidth: 2)
                        }
                        if rect.width > 62 && rect.height > 26 {
                            let label = Text(tile.title).font(.caption2.weight(.medium)).foregroundColor(.white)
                            context.draw(label, at: CGPoint(x: rect.minX + 7, y: rect.minY + 13), anchor: .topLeading)
                            let bytes = Text(ByteFormat.string(tile.weight)).font(.caption2).foregroundColor(.white.opacity(0.85))
                            context.draw(bytes, at: CGPoint(x: rect.minX + 7, y: rect.minY + 29), anchor: .topLeading)
                        }
                    }
                }
                if tiles.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .background(SLColor.content)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SLColor.separator))
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let nx = value.location.x / max(1, size.width)
                let ny = value.location.y / max(1, size.height)
                guard let hit = tiles.first(where: {
                    nx >= $0.rect.x && nx <= $0.rect.x + $0.rect.width &&
                    ny >= $0.rect.y && ny <= $0.rect.y + $0.rect.height
                }) else { return }
                if !hit.isCluster, let child = node.children.first(where: { $0.id == hit.nodeID }) {
                    state.drillInto(child)
                }
            })
            .accessibilityLabel("磁盘空间矩形树图，共 \(tiles.count) 个区块")
            .task(id: key(for: size)) { await rebuild(size: size) }
        }
    }

    private func key(for size: CGSize) -> String {
        let revision = state.scanSnapshot.map { "\($0.sessionID)-\($0.revision)" } ?? "modified"
        return "\(revision)-\(node.id)-\(node.children.count)-\(node.aggregatedSize)-\(node.aggregatedAllocatedSize)-\(state.sizeBasis.rawValue)-\(Int(size.width))x\(Int(size.height))"
    }

    private func rebuild(size: CGSize) async {
        let target = key(for: size)
        guard target != cacheKey else { return }
        if let cached = state.treemapLayoutCache[target] {
            tiles = cached
            cacheKey = target
            return
        }
        let allocated = state.sizeBasis == .allocated
        if let snapshot = state.scanSnapshot {
            let rootID = node.id
            let result = await Task.detached(priority: .userInitiated) {
                TreemapLayout.inputs(snapshot: snapshot, rootID: rootID, allocated: allocated).map {
                    TreemapLayout.squarify($0, in: SLRect(x: 0, y: 0, width: 1, height: 1))
                }
            }.value
            guard !Task.isCancelled, target == key(for: size) else { return }
            if let result {
                if state.treemapLayoutCache.count >= 8 { state.treemapLayoutCache.removeAll() }
                state.treemapLayoutCache[target] = result
                tiles = result
                cacheKey = target
                return
            }
        }
        let inputs: [TreemapLayout.Input] = node.children.map { child in
            let bytes = state.sizeBasis == .logical ? child.effectiveSize : child.effectiveAllocatedSize
            return TreemapLayout.Input(nodeID: child.id, weight: bytes,
                                       title: child.name, category: child.category)
        }
        let result = await Task.detached(priority: .userInitiated) {
            TreemapLayout.squarify(inputs, in: SLRect(x: 0, y: 0, width: 1, height: 1))
        }.value
        guard !Task.isCancelled, target == key(for: size) else { return }
        tiles = result
        cacheKey = target
    }
}

struct SunburstView: View {
    @Environment(AppState.self) private var state
    let node: ScanNode

    @State private var arcs: [SunburstArc] = []
    @State private var cacheKey = ""

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = side / 2 - 12
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                Canvas { context, _ in
                    for arc in arcs {
                        let path = wedge(arc: arc, center: center, radius: radius)
                        let selected = state.selectedNode?.id == arc.nodeID
                        context.fill(path, with: .color(SLColor.category(arc.category).opacity(selected ? 1 : 0.78)))
                        context.stroke(path, with: .color(SLColor.content), lineWidth: 1)
                    }
                    let inner = Path(ellipseIn: CGRect(x: center.x - radius * 0.2, y: center.y - radius * 0.2,
                                                       width: radius * 0.4, height: radius * 0.4))
                    context.fill(inner, with: .color(SLColor.content))
                    let title = Text(node.name).font(.caption.weight(.semibold))
                    context.draw(title, at: center, anchor: .center)
                }
                if arcs.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .background(SLColor.content)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SLColor.separator))
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                let dx = value.location.x - center.x
                let dy = value.location.y - center.y
                let distance = sqrt(dx * dx + dy * dy) / radius
                var angle = atan2(dy, dx) + .pi / 2
                if angle < 0 { angle += 2 * .pi }
                guard distance >= 0.2, distance <= 1 else { return }
                guard let hit = arcs.first(where: {
                    angle >= $0.startAngle && angle <= $0.endAngle &&
                    distance >= $0.innerRadius && distance <= $0.outerRadius
                }) else { return }
                if let child = state.findNode(id: hit.nodeID) { state.drillInto(child) }
            })
            .accessibilityLabel("磁盘空间旭日图，共 \(arcs.count) 个扇区")
            .task(id: key(for: geometry.size)) {
                let target = key(for: geometry.size)
                guard target != cacheKey else { return }
                if let cached = state.sunburstLayoutCache[target] {
                    arcs = cached
                    cacheKey = target
                    return
                }
                let allocated = state.sizeBasis == .allocated
                if let snapshot = state.scanSnapshot {
                    let rootID = node.id
                    let computed = await Task.detached(priority: .userInitiated) {
                        SunburstLayout.arcs(snapshot: snapshot, rootID: rootID, allocated: allocated)
                    }.value
                    guard !Task.isCancelled, target == key(for: geometry.size) else { return }
                    if let computed {
                        if state.sunburstLayoutCache.count >= 8 { state.sunburstLayoutCache.removeAll() }
                        state.sunburstLayoutCache[target] = computed
                        arcs = computed
                        cacheKey = target
                        return
                    }
                }
                arcs = SunburstLayout.arcs(root: node, maxDepth: 4, allocated: allocated)
                cacheKey = target
            }
        }
    }

    private func key(for size: CGSize) -> String {
        let revision = state.scanSnapshot.map { "\($0.sessionID)-\($0.revision)" } ?? "modified"
        return "\(revision)-\(node.id)-\(node.aggregatedSize)-\(node.aggregatedAllocatedSize)-\(state.sizeBasis.rawValue)-\(Int(size.width))x\(Int(size.height))"
    }

    private func wedge(arc: SunburstArc, center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let start = Angle.radians(arc.startAngle - .pi / 2)
        let end = Angle.radians(arc.endAngle - .pi / 2)
        path.addArc(center: center, radius: radius * arc.outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: radius * arc.innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

}
