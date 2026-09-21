import Foundation

enum MaskDataError: Error, LocalizedError {
    case invalidDimensions, inconsistentSubjects
    var errorDescription: String? {
        switch self {
        case .invalidDimensions: return "蒙版尺寸或数据长度不正确。"
        case .inconsistentSubjects: return "主体蒙版与主体编号不一致，请重新识别照片。"
        }
    }
}

/// Top-left row order. This is coverage (or an explicitly declared label plane), NOT depth.
/// Data stores one byte per pixel; Codable encodes it compactly instead of as millions of integers.
struct GrayMask: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let bytes: Data

    init(width: Int, height: Int, bytes: Data) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height == bytes.count else { throw MaskDataError.invalidDimensions }
        self.width = width; self.height = height; self.bytes = Data(bytes)
    }
    private enum CodingKeys: String, CodingKey { case width, height, bytes }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: box.decode(Int.self, forKey: .width),
                      height: box.decode(Int.self, forKey: .height),
                      bytes: box.decode(Data.self, forKey: .bytes))
    }
    func value(at point: UnitPoint2D) -> UInt8 {
        let p = point.clamped
        let x = min(width - 1, Int((p.x * Double(width - 1)).rounded()))
        let y = min(height - 1, Int((p.y * Double(height - 1)).rounded()))
        return bytes[bytes.startIndex + y * width + x]
    }
    func inverted() throws -> Self {
        try Self(width: width, height: height, bytes: Data(bytes.map { 255 - $0 }))
    }
}

struct SubjectMask: Codable, Equatable, Sendable {
    let id: UInt8
    let mask: GrayMask
}

struct SubjectSegmentation: Codable, Equatable, Sendable {
    /// UInt8 subject IDs exactly as returned by Vision. 0 means background.
    let labels: GrayMask
    let subjects: [SubjectMask]
    /// If a very crowded image exceeds the cache budget, remaining subjects form one group.
    let groupedSubjectCount: Int

    init(labels: GrayMask, subjects: [SubjectMask], groupedSubjectCount: Int = 0) throws {
        guard !subjects.isEmpty, subjects.count <= 16, let first = subjects.first,
              subjects.allSatisfy({ $0.id > 0 && $0.mask.width == first.mask.width && $0.mask.height == first.mask.height }),
              subjects.reduce(0, { $0 + $1.mask.bytes.count }) <= 32 * 1024 * 1024 else {
            throw MaskDataError.inconsistentSubjects
        }
        let ids = Set(subjects.map(\.id))
        guard ids.count == subjects.count,
              Set(labels.bytes).subtracting([UInt8(0)]).isSubset(of: ids) else {
            throw MaskDataError.inconsistentSubjects
        }
        self.labels = labels; self.subjects = subjects
        self.groupedSubjectCount = max(0, groupedSubjectCount)
    }
    private enum CodingKeys: String, CodingKey { case labels, subjects, groupedSubjectCount }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(labels: box.decode(GrayMask.self, forKey: .labels),
                      subjects: box.decode([SubjectMask].self, forKey: .subjects),
                      groupedSubjectCount: box.decodeIfPresent(Int.self, forKey: .groupedSubjectCount) ?? 0)
    }
    func instance(at point: UnitPoint2D) -> UInt8 { labels.value(at: point) }
    func subject(at point: UnitPoint2D) -> SubjectMask? {
        // Use the same high-resolution coverage that will be assigned; no low-res-label mismatch.
        subjects.filter { $0.mask.value(at: point) >= 128 }
            .max { $0.mask.value(at: point) < $1.mask.value(at: point) }
    }

    func allForegroundMask() throws -> GrayMask {
        guard let first = subjects.first else { throw MaskDataError.inconsistentSubjects }
        var combined = [UInt8](repeating: 0, count: first.mask.bytes.count)
        for subject in subjects {
            try Task.checkCancellation()
            // Maximum coverage avoids summing overlapping soft edges above 1.
            for (index, value) in subject.mask.bytes.enumerated() { combined[index] = max(combined[index], value) }
        }
        return try GrayMask(width: first.mask.width, height: first.mask.height, bytes: Data(combined))
    }

}

enum FocusMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, local
    var id: Self { self }
    var title: String { self == .automatic ? "自动景深（内置模型 / 原生深度）" : "局部虚化（圆形选区）" }
}

/// Never encode subject IDs as continuous disparity. Each rendering path stays explicitly typed.
enum PhotoAnalysis: Codable, Equatable, Sendable {
    case native(DepthField)
    case estimated(InferredDepth)
    case layered(LayeredScene)
    // Legacy cases are decoded for migration only; they never imply depth.
    case subjects(SubjectSegmentation)
    case localFallback(reason: String)

    var sourceDescription: String {
        switch self {
        case .native: return "照片自带深度"
        case .estimated: return "内置模型自动深度（离线）"
        case .layered(let scene): return scene.map.provenance.title
        case .subjects: return "苹果 Vision 主体分割"
        case .localFallback: return "局部虚化（非深度识别）"
        }
    }
    var continuousDepth: DepthField? {
        switch self {
        case .native(let field): return field
        case .estimated(let value): return value.field
        default: return nil
        }
    }
    var isNative: Bool { if case .native = self { return true }; return false }
    var isFallback: Bool { if case .localFallback = self { return true }; return false }
}

struct FocusMaskSet: Equatable, Sendable {
    let blur: GrayMask
    let nearDefocus: GrayMask?
    let protection: GrayMask?
    init(blur: GrayMask, nearDefocus: GrayMask?, protection: GrayMask? = nil) {
        self.blur = blur; self.nearDefocus = nearDefocus; self.protection = protection
    }
}

enum LocalFocusMask {
    /// White means blur. Radius is a fraction of the image's SHORT edge, not screen width.
    static func make(width: Int, height: Int, imageSize: PixelSize,
                     center: UnitPoint2D, radius: Double) throws -> GrayMask {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              imageSize.width > 0, imageSize.height > 0 else { throw MaskDataError.invalidDimensions }
        let p = center.clamped
        let r = radius.isFinite ? min(0.7, max(0.08, radius)) : 0.24
        let short = Double(min(imageSize.width, imageSize.height))
        let sx = Double(imageSize.width) / short, sy = Double(imageSize.height) / short
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let dy = (Double(y) / Double(max(1, height - 1)) - p.y) * sy
            for x in 0..<width {
                let dx = (Double(x) / Double(max(1, width - 1)) - p.x) * sx
                let distance = sqrt(dx * dx + dy * dy)
                let amount = DepthMath.smoothstep(Float(r * 0.65), Float(r * 1.4), Float(distance))
                bytes[y * width + x] = UInt8((amount * 255).rounded())
            }
        }
        return try GrayMask(width: width, height: height, bytes: Data(bytes))
    }
}

enum FocusMaskBuilder {
    static func make(analysis: PhotoAnalysis, recipe: EditRecipe, imageSize: PixelSize) throws -> FocusMaskSet {
        var safe = recipe; safe.sanitize()
        if safe.focusMode == .local {
            let size = ImageGeometry.outputSize(width: imageSize.width, height: imageSize.height, longestEdge: 512)
            return try FocusMaskSet(blur: LocalFocusMask.make(width: size.width, height: size.height,
                                                             imageSize: imageSize, center: safe.focusPoint, radius: safe.localRadius),
                                    nearDefocus: nil)
        }
        switch analysis {
        case .native(let depth):
            return try ContinuousFocusMasks.make(depth: depth, point: safe.focusPoint, tolerance: safe.focusTolerance)
        case .estimated(let value):
            return try ContinuousFocusMasks.make(depth: value.field, point: safe.focusPoint, tolerance: safe.focusTolerance)
        case .layered(let scene):
            return try scene.map.focusMasks(at: safe.focusPoint, tolerance: safe.focusTolerance)
        case .subjects(let segmentation):
            // Old draft without confirmed depths. No instance is assumed near OR far.
            return try FocusMaskSet(blur: GrayMask(width: segmentation.labels.width, height: segmentation.labels.height,
                                                  bytes: Data(repeating: 0, count: segmentation.labels.bytes.count)), nearDefocus: nil)
        case .localFallback:
            return try FocusMaskSet(blur: GrayMask(width: 1, height: 1, bytes: Data([0])), nearDefocus: nil)
        }
    }
}
