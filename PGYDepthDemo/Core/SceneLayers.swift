import Foundation

/// These are USER-CONFIRMED depth groups, not Vision instance IDs or measured meters.
/// Zero explicitly means unknown; it never automatically means far/background.
enum SceneLayer: UInt8, Codable, CaseIterable, Identifiable, Sendable {
    case unknown = 0, far = 1, middle = 2, near = 3
    var id: Self { self }
    var title: String {
        switch self {
        case .unknown: return "未标记"
        case .near: return "近景"
        case .middle: return "中景"
        case .far: return "远景"
        }
    }
    var relativeDisparity: Float? {
        switch self {
        case .unknown: return nil
        case .far: return 0
        case .middle: return 0.5
        case .near: return 1
        }
    }
}

enum LayerProvenance: String, Codable, Sendable {
    case unassigned, user, reference
    var title: String {
        switch self {
        case .unassigned: return "待确认景深分层"
        case .user: return "用户校正分层"
        case .reference: return "人工分层验证样例"
        }
    }
}

enum LayerDataError: Error, LocalizedError {
    case invalidLabel, invalidPolygon, invalidStroke, mismatchedReference
    var errorDescription: String? {
        switch self {
        case .invalidLabel: return "分层数据不正确，请重新标记。"
        case .invalidPolygon: return "请至少标记三个有效顶点，再闭合选区。"
        case .invalidStroke: return "画笔路径或大小不正确。"
        case .mismatchedReference: return "参考分层与参考原图不匹配，未套用任何预设。"
        }
    }
}

struct LayeredScene: Codable, Equatable, Sendable {
    let map: SceneLayerMap
    /// Optional selection assistance ONLY. It does not assign depth to any region.
    let subjects: SubjectSegmentation?
    let notice: String?
}

struct SceneLayerMap: Codable, Equatable, Sendable {
    let labels: GrayMask
    let provenance: LayerProvenance
    private let populations: [Int]
    init(labels: GrayMask, provenance: LayerProvenance) throws {
        var counts = [Int](repeating: 0, count: 4)
        for byte in labels.bytes {
            guard byte <= 3 else { throw LayerDataError.invalidLabel }
            counts[Int(byte)] += 1
        }
        self.labels = labels; self.provenance = provenance; self.populations = counts
    }
    private enum CodingKeys: String, CodingKey { case labels, provenance }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(labels: box.decode(GrayMask.self, forKey: .labels),
                      provenance: box.decode(LayerProvenance.self, forKey: .provenance))
    }
    static func blank(width: Int, height: Int) throws -> Self {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw MaskDataError.invalidDimensions }
        return try Self(labels: GrayMask(width: width, height: height, bytes: Data(repeating: 0, count: width * height)), provenance: .unassigned)
    }
    func layer(at point: UnitPoint2D) -> SceneLayer { SceneLayer(rawValue: labels.value(at: point)) ?? .unknown }
    // Cached at construction so moving the aperture slider never scans a million labels on MainActor.
    var knownLayers: [SceneLayer] { (1...3).compactMap { populations[$0] > 0 ? SceneLayer(rawValue: UInt8($0)) : nil } }
    var assignedFraction: Double { 1 - Double(populations[0]) / Double(labels.bytes.count) }
    func firstPoint(in layer: SceneLayer) -> UnitPoint2D? {
        // Prefer an interior point, not the first edge pixel. Search closest to image center.
        var best: (index: Int, distance: Int)?
        for (index, byte) in labels.bytes.enumerated() where byte == layer.rawValue {
            let x = index % labels.width, y = index / labels.width
            let dx = x - labels.width / 2, dy = y - labels.height / 2, distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best else { return nil }
        return .init(x: Double(best.index % labels.width) / Double(max(1, labels.width - 1)),
                     y: Double(best.index / labels.width) / Double(max(1, labels.height - 1)))
    }
    func focusMasks(at point: UnitPoint2D, tolerance: Double) throws -> FocusMaskSet {
        let count = labels.bytes.count
        guard let focus = layer(at: point).relativeDisparity else {
            return try FocusMaskSet(blur: GrayMask(width: labels.width, height: labels.height, bytes: Data(repeating: 0, count: count)),
                                    nearDefocus: nil,
                                    protection: GrayMask(width: labels.width, height: labels.height, bytes: Data(repeating: 255, count: count)))
        }
        let t = Float(tolerance.isFinite ? min(0.2, max(0.01,tolerance)) : 0.035)
        var blur = [UInt8](repeating: 0, count: count), near = blur, protection = blur
        for (index, label) in labels.bytes.enumerated() {
            if index % 32768 == 0 { try Task.checkCancellation() }
            guard let value = SceneLayer(rawValue: label)?.relativeDisparity else { protection[index] = 255; continue }
            let amount = DepthMath.blurAmount(depth: value, focus: focus, tolerance: t)
            blur[index] = UInt8((amount * 255).rounded())
            if value > focus + t { near[index] = blur[index] }
            if abs(value - focus) <= t { protection[index] = 255 }
        }
        func mask(_ bytes: [UInt8]) throws -> GrayMask { try GrayMask(width: labels.width,height: labels.height,bytes: Data(bytes)) }
        return try FocusMaskSet(blur: mask(blur), nearDefocus: near.contains(where: { $0 > 0 }) ? mask(near) : nil,
                                protection: mask(protection))
    }
    func assigning(mask: GrayMask, to layer: SceneLayer) throws -> Self {
        var bytes = Array(labels.bytes)
        for y in 0..<labels.height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let sy = min(mask.height-1, Int((Double(y) / Double(max(1,labels.height-1)) * Double(mask.height-1)).rounded()))
            for x in 0..<labels.width {
                let sx = min(mask.width-1, Int((Double(x) / Double(max(1,labels.width-1)) * Double(mask.width-1)).rounded()))
                if mask.bytes[sy * mask.width + sx] >= 128 { bytes[y*labels.width+x] = layer.rawValue }
            }
        }
        return try replacing(bytes)
    }
    func fillingUnknown(with layer: SceneLayer) throws -> Self {
        try replacing(labels.bytes.map { $0 == 0 ? layer.rawValue : $0 })
    }
    func filling(polygon: [UnitPoint2D], with layer: SceneLayer) throws -> Self {
        guard (3...4096).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw LayerDataError.invalidPolygon
        }
        let points = polygon.map(\.clamped)
        var bytes = Array(labels.bytes)
        // Even/odd scanline fill. Coordinates share EXACTLY the same top-left convention as hit testing.
        for y in 0..<labels.height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let py = Double(y) / Double(max(1, labels.height-1))
            var intersections: [Double] = []
            for i in points.indices {
                let a = points[i], b = points[(i+1) % points.count]
                if (a.y <= py && b.y > py) || (b.y <= py && a.y > py) {
                    intersections.append(a.x + (py-a.y) * (b.x-a.x) / (b.y-a.y))
                }
            }
            intersections.sort()
            var i = 0
            while i + 1 < intersections.count {
                let left = max(0, Int(ceil(intersections[i] * Double(max(1,labels.width-1)))))
                let right = min(labels.width-1, Int(floor(intersections[i+1] * Double(max(1,labels.width-1)))))
                if left <= right { for x in left...right { bytes[y*labels.width+x] = layer.rawValue } }
                i += 2
            }
        }
        return try replacing(bytes)
    }
    func painting(points: [UnitPoint2D], radius: Double, layer: SceneLayer) throws -> Self {
        guard !points.isEmpty, points.count <= 20000, radius.isFinite, radius > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw LayerDataError.invalidStroke }
        let r = min(0.35, max(0.001, radius)) * Double(max(1,min(labels.width-1,labels.height-1)))
        let r2 = r*r
        let path = points.map { (x: $0.clamped.x * Double(max(1,labels.width-1)), y: $0.clamped.y * Double(max(1,labels.height-1))) }
        var bytes = Array(labels.bytes)
        for i in path.indices {
            if i % 16 == 0 { try Task.checkCancellation() }
            let a = path[max(0,i-1)], b = path[i]
            let dx = b.x-a.x, dy = b.y-a.y, length2 = dx*dx+dy*dy
            let minX = max(0,Int(floor(min(a.x,b.x)-r))), maxX = min(labels.width-1,Int(ceil(max(a.x,b.x)+r)))
            let minY = max(0,Int(floor(min(a.y,b.y)-r))), maxY = min(labels.height-1,Int(ceil(max(a.y,b.y)+r)))
            if minX > maxX || minY > maxY { continue }
            for y in minY...maxY { for x in minX...maxX {
                let px = Double(x)-a.x, py = Double(y)-a.y
                let t = length2 > 0 ? min(1,max(0,(px*dx+py*dy)/length2)) : 0
                let distance2 = pow(px-t*dx,2)+pow(py-t*dy,2)
                if distance2 <= r2 { bytes[y*labels.width+x] = layer.rawValue }
            } }
        }
        return try replacing(bytes)
    }
    private func replacing(_ bytes: [UInt8]) throws -> Self {
        try Self(labels: GrayMask(width: labels.width,height: labels.height,bytes: Data(bytes)), provenance: .user)
    }
}

struct LayerEditingHistory {
    private(set) var current: SceneLayerMap
    private var previous: [SceneLayerMap] = [], next: [SceneLayerMap] = []
    private let limit: Int
    init(initial: SceneLayerMap, limit: Int = 16) { current = initial; self.limit = max(1,min(32,limit)) }
    var canUndo: Bool { !previous.isEmpty }
    var canRedo: Bool { !next.isEmpty }
    mutating func apply(_ map: SceneLayerMap) {
        guard current != map else { return }
        previous.append(current)
        if previous.count > limit { previous.removeFirst(previous.count-limit) }
        current = map; next.removeAll()
    }
    mutating func undo() { guard let last = previous.popLast() else { return }; next.append(current); current = last }
    mutating func redo() { guard let last = next.popLast() else { return }; previous.append(current); current = last }
}

/// Explicit human-authored QA fixture. Only the "open reference example" action loads this.
/// It is never matched to arbitrary imported photographs or claimed to be automatic depth.
struct ReferenceLayerFixture: Codable {
    struct Region: Codable { let name: String; let layer: SceneLayer; let polygon: [UnitPoint2D] }
    let version: Int
    let sourceSHA256: String
    let imageSize: PixelSize
    let description: String
    let baseLayer: SceneLayer
    let regions: [Region]
    func makeMap(longestEdge: Int = 1024) throws -> SceneLayerMap {
        guard version == 1, imageSize.width > 0, imageSize.height > 0, regions.count <= 128 else { throw LayerDataError.mismatchedReference }
        let size = ImageGeometry.outputSize(width: imageSize.width,height: imageSize.height,longestEdge: longestEdge)
        var map = try SceneLayerMap.blank(width: size.width,height: size.height).fillingUnknown(with: baseLayer)
        for region in regions { map = try map.filling(polygon: region.polygon, with: region.layer) }
        return try SceneLayerMap(labels: map.labels,provenance: .reference)
    }
}
