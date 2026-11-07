import Foundation

// MARK: - 几何原语（Sendable 值类型，避免 CoreGraphics 跨 actor 传递问题）

public struct SLRect: Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var shortSide: Double { min(width, height) }
}

public struct TreemapTile: Identifiable, Sendable {
    public let id: UUID
    public let nodeID: UUID
    public let rect: SLRect
    public let weight: Int64
    public let title: String
    public let category: CategoryKind
    public let isCluster: Bool
}

public struct SunburstArc: Identifiable, Sendable {
    public let id: UUID
    public let nodeID: UUID
    public let startAngle: Double
    public let endAngle: Double
    public let innerRadius: Double
    public let outerRadius: Double
    public let title: String
    public let category: CategoryKind
}

public enum TreemapLayout {
    public struct Input: Sendable {
        public let nodeID: UUID
        public let weight: Int64
        public let title: String
        public let category: CategoryKind
        public init(nodeID: UUID, weight: Int64, title: String, category: CategoryKind) {
            self.nodeID = nodeID; self.weight = weight; self.title = title; self.category = category
        }
    }

    public static func inputs(snapshot: ScanSnapshot, rootID: UUID, allocated: Bool = false) -> [Input]? {
        guard snapshot.nodes.contains(where: { $0.id == rootID }) else { return nil }
        var result: [Input] = []
        for node in snapshot.nodes where node.parentID == rootID {
            guard let weight = allocated ? node.effectiveAllocatedSize : node.effectiveLogicalSize else { return nil }
            result.append(Input(nodeID: node.id, weight: weight,
                                title: URL(fileURLWithPath: node.path).lastPathComponent,
                                category: node.category ?? .other))
        }
        return result
    }

    /// Squarified Treemaps（Bruls, Huizing & van Wijk, 2000）。
    /// 小于 minTileArea 的项目合并为「小文件簇」，避免十万级矩形的绘制与命中开销（M1-11）。
    public static func squarify(_ inputs: [Input], in bounds: SLRect,
                                minTileArea: Double = 0.0006) -> [TreemapTile] {
        let positive = inputs.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard !positive.isEmpty else { return [] }
        let total = positive.reduce(Int64(0)) { $0 + $1.weight }
        guard total > 0 else { return [] }
        let area = bounds.width * bounds.height
        let scale = area / Double(total)

        var items = positive
        var tiny: [Input] = []
        let threshold = minTileArea / max(scale, .leastNonzeroMagnitude)
        items.removeAll { item in
            if Double(item.weight) < threshold { tiny.append(item); return true }
            return false
        }
        if !tiny.isEmpty {
            let combined = tiny.reduce(Int64(0)) { $0 + $1.weight }
            items.append(Input(nodeID: UUID(), weight: combined,
                               title: "其他 \(tiny.count) 项", category: .other))
            items.sort { $0.weight > $1.weight }
        }

        var tiles: [TreemapTile] = []
        var row: [Input] = []
        var remaining = bounds

        func worst(_ row: [Input], side: Double) -> Double {
            guard !row.isEmpty, side > 0 else { return .greatestFiniteMagnitude }
            let sum = row.reduce(0.0) { $0 + Double($1.weight) * scale }
            let strip = sum / side
            guard strip > 0 else { return .greatestFiniteMagnitude }
            var worstRatio = 1.0
            for item in row {
                let itemArea = Double(item.weight) * scale
                let other = itemArea / strip
                let a = max(strip, other), b = min(strip, other)
                if b > 0 { worstRatio = max(worstRatio, a / b) }
            }
            return worstRatio
        }

        func layoutRow(_ row: [Input], in rect: SLRect) -> SLRect {
            let sum = row.reduce(0.0) { $0 + Double($1.weight) * scale }
            guard sum > 0 else { return rect }
            if rect.width >= rect.height {
                let strip = min(rect.width, sum / rect.height)
                var y = rect.y
                var used: Double = 0
                for (index, item) in row.enumerated() {
                    let height = index == row.count - 1
                        ? rect.height - used
                        : (Double(item.weight) * scale) / max(strip, .leastNonzeroMagnitude)
                    tiles.append(TreemapTile(id: UUID(), nodeID: item.nodeID,
                                             rect: SLRect(x: rect.x, y: y, width: strip, height: max(0, height)),
                                             weight: item.weight, title: item.title,
                                             category: item.category,
                                             isCluster: item.title.hasPrefix("其他 ")))
                    y += height; used += height
                }
                return SLRect(x: rect.x + strip, y: rect.y,
                              width: max(0, rect.width - strip), height: rect.height)
            } else {
                let strip = min(rect.height, sum / rect.width)
                var x = rect.x
                var used: Double = 0
                for (index, item) in row.enumerated() {
                    let width = index == row.count - 1
                        ? rect.width - used
                        : (Double(item.weight) * scale) / max(strip, .leastNonzeroMagnitude)
                    tiles.append(TreemapTile(id: UUID(), nodeID: item.nodeID,
                                             rect: SLRect(x: x, y: rect.y, width: max(0, width), height: strip),
                                             weight: item.weight, title: item.title,
                                             category: item.category,
                                             isCluster: item.title.hasPrefix("其他 ")))
                    x += width; used += width
                }
                return SLRect(x: rect.x, y: rect.y + strip,
                              width: rect.width, height: max(0, rect.height - strip))
            }
        }

        while !items.isEmpty {
            let item = items[0]
            let side = remaining.shortSide
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) {
                row.append(item)
                items.removeFirst()
            } else {
                remaining = layoutRow(row, in: remaining)
                row = []
            }
        }
        if !row.isEmpty { _ = layoutRow(row, in: remaining) }
        return tiles
    }
}

public enum SunburstLayout {
    /// Uses immutable snapshot data so layout can run without touching the mutable UI tree.
    public static func arcs(snapshot: ScanSnapshot, rootID: UUID, maxDepth: Int = 4, allocated: Bool = false) -> [SunburstArc]? {
        var depths: [UUID: Int] = [rootID: 0]
        var children: [UUID: [ScanSnapshot.Node]] = [:]
        var found = false
        for node in snapshot.nodes {
            if node.id == rootID { found = true; continue }
            guard found else { continue }
            guard let parent = node.parentID, let depth = depths[parent] else { break }
            let childDepth = depth + 1
            depths[node.id] = childDepth
            if childDepth <= maxDepth { children[parent, default: []].append(node) }
        }
        guard found else { return nil }
        var result: [SunburstArc] = []
        let inner: Double = 0.2, band = 0.8 / Double(max(1, maxDepth))
        func weight(_ node: ScanSnapshot.Node) -> Int64? {
            allocated ? node.effectiveAllocatedSize : node.effectiveLogicalSize
        }
        func walk(_ id: UUID, start: Double, end: Double, depth: Int) -> Bool {
            guard depth < maxDepth, let nodes = children[id] else { return true }
            guard nodes.allSatisfy({ weight($0) != nil }) else { return false }
            let positive = nodes.filter { weight($0)! > 0 }
            let total = positive.reduce(Int64(0)) { $0 + weight($1)! }
            guard total > 0 else { return true }
            var cursor = start
            for node in positive {
                let next = cursor + (end - start) * Double(weight(node)!) / Double(total)
                result.append(SunburstArc(id: UUID(), nodeID: node.id, startAngle: cursor, endAngle: next,
                                          innerRadius: inner + Double(depth) * band,
                                          outerRadius: min(1, inner + Double(depth + 1) * band),
                                          title: URL(fileURLWithPath: node.path).lastPathComponent,
                                          category: node.category ?? .other))
                guard walk(node.id, start: cursor, end: next, depth: depth + 1) else { return false }
                cursor = next
            }
            return true
        }
        return walk(rootID, start: 0, end: 2 * .pi, depth: 0) ? result : nil
    }

    public static func arcs(root: ScanNode, maxDepth: Int = 4, allocated: Bool = false) -> [SunburstArc] {
        func weight(_ node: ScanNode) -> Int64 { allocated ? node.effectiveAllocatedSize : node.effectiveSize }
        let inner: Double = 0.2, outer: Double = 1.0
        let band = (outer - inner) / Double(max(1, maxDepth))
        var result: [SunburstArc] = []

        func walk(_ node: ScanNode, start: Double, end: Double, depth: Int) {
            guard depth < maxDepth else { return }
            let r0 = inner + Double(depth) * band
            let r1 = min(outer, r0 + band)
            let children = node.children.filter { weight($0) > 0 }
            guard !children.isEmpty else { return }
            let childTotal = children.reduce(Int64(0)) { $0 + weight($1) }
            guard childTotal > 0 else { return }
            var cursor = start
            for child in children {
                let span = (end - start) * Double(weight(child)) / Double(childTotal)
                let next = cursor + span
                result.append(SunburstArc(
                    id: UUID(), nodeID: child.id, startAngle: cursor, endAngle: next,
                    innerRadius: r0, outerRadius: r1, title: child.name,
                    category: child.category
                ))
                walk(child, start: cursor, end: next, depth: depth + 1)
                cursor = next
            }
        }
        walk(root, start: 0, end: 2 * .pi, depth: 0)
        return result
    }
}
