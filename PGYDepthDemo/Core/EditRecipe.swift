import Foundation

enum Aperture {
    static let minimum = 1.4
    static let maximum = 16.0
    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(maximum, max(minimum, value)) : 2
    }
    /// Generic linear normalization; the on-screen ruler uses its own logarithmic scale.
    static func position(of value: Double) -> Double {
        (clamp(value) - minimum) / (maximum - minimum)
    }
    static func value(at position: Double) -> Double {
        let p = position.isFinite ? min(1, max(0, position)) : 0
        return minimum + p * (maximum - minimum)
    }
    /// A deliberately perceptual mapping, not a claim of a physically calibrated lens.
    static func strength(_ value: Double) -> Double {
        let f = clamp(value)
        return max(0, min(1, (1 / f - 1 / maximum) / (1 / minimum - 1 / maximum)))
    }
}

enum CropRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, square, portrait, landscape, wide, tall
    var id: Self { self }
    var title: String {
        switch self {
        case .original: return "原始"
        case .square: return "1:1"
        case .portrait: return "3:4"
        case .landscape: return "4:3"
        case .wide: return "16:9"
        case .tall: return "9:16"
        }
    }
    var ratio: Double? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .portrait: return 3 / 4
        case .landscape: return 4 / 3
        case .wide: return 16 / 9
        case .tall: return 9 / 16
        }
    }
    func unitRect(imageWidth: Int, imageHeight: Int) -> Rect2D {
        guard let desired = ratio, imageWidth > 0, imageHeight > 0 else { return .unit }
        let actual = Double(imageWidth) / Double(imageHeight)
        if actual > desired {
            let width = desired / actual
            return Rect2D(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = actual / desired
        return Rect2D(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }
}

enum PhotoStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case original, monochrome, warm, cool
    var id: Self { self }
    var title: String {
        switch self {
        case .original: return "原色"
        case .monochrome: return "黑白"
        case .warm: return "暖调"
        case .cool: return "冷调"
        }
    }
}

struct EditRecipe: Codable, Equatable, Sendable {
    var schemaVersion = 5
    var selectedPersonID: UInt8? = nil
    var focusPoint = UnitPoint2D(x: 0.48, y: 0.56)
    var aperture: Double = 1.8
    var depthEnabled = true
    var effectStrength: Double = 1
    var focusTolerance: Double = 0.22
    var exposure: Double = 0
    var crop: CropRatio = .original
    var style: PhotoStyle = .original
    var focusMode: FocusMode = .automatic
    var localRadius: Double = 0.24
    /// Feather radius at a 1024-pixel long edge. Scaled consistently at export.
    var edgeFeather: Double = 1.2

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedPersonID, focusPoint, aperture, depthEnabled, effectStrength, focusTolerance
        case exposure, crop, style, focusMode, localRadius, edgeFeather
    }
    init(from decoder: Decoder) throws {
        self.init()
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let version = try box.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...5).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: box, debugDescription: "不支持的编辑配方版本")
        }
        selectedPersonID = version >= 5 ? try box.decodeIfPresent(UInt8.self, forKey: .selectedPersonID) : nil
        focusPoint = try box.decodeIfPresent(UnitPoint2D.self, forKey: .focusPoint) ?? focusPoint
        aperture = try box.decodeIfPresent(Double.self, forKey: .aperture) ?? aperture
        depthEnabled = try box.decodeIfPresent(Bool.self, forKey: .depthEnabled) ?? depthEnabled
        effectStrength = try box.decodeIfPresent(Double.self, forKey: .effectStrength) ?? effectStrength
        focusTolerance = version < 4 ? 0.22 : (try box.decodeIfPresent(Double.self, forKey: .focusTolerance) ?? focusTolerance)
        exposure = try box.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        crop = try box.decodeIfPresent(CropRatio.self, forKey: .crop) ?? crop
        style = try box.decodeIfPresent(PhotoStyle.self, forKey: .style) ?? style
        focusMode = try box.decodeIfPresent(FocusMode.self, forKey: .focusMode) ?? focusMode
        localRadius = try box.decodeIfPresent(Double.self, forKey: .localRadius) ?? localRadius
        edgeFeather = try box.decodeIfPresent(Double.self, forKey: .edgeFeather) ?? edgeFeather
        sanitize()
    }

    mutating func sanitize() {
        schemaVersion = 5
        if selectedPersonID == 0 { selectedPersonID = nil }
        focusPoint = focusPoint.clamped
        localRadius = localRadius.isFinite ? min(0.7, max(0.08, localRadius)) : 0.24
        edgeFeather = edgeFeather.isFinite ? min(6, max(0, edgeFeather)) : 1.2
        aperture = Aperture.clamp(aperture)
        effectStrength = effectStrength.isFinite ? min(1.5, max(0, effectStrength)) : 1
        focusTolerance = focusTolerance.isFinite ? min(0.4, max(0.01, focusTolerance)) : 0.22
        exposure = exposure.isFinite ? min(1.5, max(-1.5, exposure)) : 0
    }
}

enum DepthMath {
    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
    static func blurAmount(depth: Float, focus: Float, tolerance: Float) -> Float {
        guard depth.isFinite, focus.isFinite else { return 0 }
        let difference = abs(depth - focus)
        return smoothstep(tolerance, min(1, tolerance + 0.42), difference)
    }
}
