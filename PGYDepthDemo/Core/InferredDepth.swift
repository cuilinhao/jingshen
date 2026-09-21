import Foundation

/// A predicted, relative inverse-depth field. It is not native camera metadata or meters.
/// The source digest and preprocessing identity prevent v3 empty masks / wrong-photo caches
/// from being silently reused as completed automatic analysis.
struct InferredDepth: Codable, Equatable, Sendable {
    static let currentModelID = "DepthAnythingV2SmallF16-fa60d9b6a155734f"
    static let currentPreprocessingID = "rgb255-scaleFill518x392-p01p99-v1"
    var modelID: String
    var preprocessingID: String
    let sourceSHA256: String
    let imageSize: PixelSize
    let field: DepthField

    init(field: DepthField, sourceSHA256: String, imageSize: PixelSize) {
        self.field = field
        self.sourceSHA256 = sourceSHA256
        self.imageSize = imageSize
        modelID = Self.currentModelID
        preprocessingID = Self.currentPreprocessingID
    }
    func matches(sourceSHA256: String, imageSize: PixelSize) -> Bool {
        guard let low = field.values.min(), let high = field.values.max(), high - low > 0.000001 else { return false }
        return self.sourceSHA256.count == 64 && self.sourceSHA256 == sourceSHA256 &&
        self.imageSize == imageSize && modelID == Self.currentModelID &&
        preprocessingID == Self.currentPreprocessingID && field.width > 1 && field.height > 1
    }
}

enum AutomaticDepthCache {
    static func reusable(_ analysis: PhotoAnalysis?, sourceSHA256: String, imageSize: PixelSize) -> InferredDepth? {
        guard case .estimated(let value) = analysis,
              value.matches(sourceSHA256: sourceSHA256, imageSize: imageSize) else { return nil }
        return value
    }
}

/// Select by relative distance difference everywhere, never by object ID or screen distance.
/// The configurable sharp interval may contain multiple disconnected objects. No image names,
/// reference annotations, bottle coordinates or foreground IDs take part in this calculation.
enum ContinuousFocusMasks {
    static func make(depth: DepthField, point: UnitPoint2D, tolerance: Double) throws -> FocusMaskSet {
        let focus = depth.sample(at: point)
        let halfWidth = Float(min(0.4, max(0.01, tolerance.isFinite ? tolerance : 0.22)))
        var blur = [UInt8](repeating: 0, count: depth.values.count)
        var near = blur, protection = blur
        for i in depth.values.indices {
            if i % 16384 == 0 { try Task.checkCancellation() }
            let delta = depth.values[i] - focus
            let distance = abs(delta)
            let b = DepthMath.smoothstep(halfWidth, halfWidth + 0.22, distance)
            blur[i] = UInt8((b * 255).rounded())
            near[i] = delta > 0 ? blur[i] : 0
            // Restore same-range detail after foreground diffusion. Blend away smoothly outside
            // the sharp interval; never copy a differently focused object's detail back in.
            let p = 1 - DepthMath.smoothstep(halfWidth, halfWidth + 0.025, distance)
            protection[i] = UInt8((p * 255).rounded())
        }
        return try FocusMaskSet(
            blur: GrayMask(width: depth.width, height: depth.height, bytes: Data(blur)),
            nearDefocus: near.contains(where: { $0 > 20 })
                ? GrayMask(width: depth.width, height: depth.height, bytes: Data(near)) : nil,
            protection: GrayMask(width: depth.width, height: depth.height, bytes: Data(protection)))
    }
}
