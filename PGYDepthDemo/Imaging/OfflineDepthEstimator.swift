import Foundation
import CoreML
import CoreImage
import CoreVideo

protocol DepthEstimating {
    func estimate(_ image: CGImage) throws -> DepthField
}

enum OfflineDepthError: Error, LocalizedError {
    case missingBundledModel
    case incompatibleModel(String)
    case predictionFailed(String)
    case invalidDepth
    var errorDescription: String? {
        switch self {
        case .missingBundledModel:
            return "App 内没有已编译的景深模型。请打开完整 v4 工程，确认 DepthAnythingV2SmallF16.mlpackage 位于 Compile Sources 后重新构建；不需要联网下载。"
        case .incompatibleModel(let reason): return "内置景深模型接口不匹配：\(reason)"
        case .predictionFailed(let reason): return "本机景深计算失败：\(reason)。没有改用空分层或人工样例，请重新分析。"
        case .invalidDepth: return "模型未返回有效的深度变化。请重新分析或更换照片；没有生成虚假的景深。"
        }
    }
}

/// Owned and called only by PhotoPipeline's serial actor. No runtime downloads, no network,
/// no model compilation on the device: Xcode compiles the bundled .mlpackage as a Source.
final class OfflineDepthEstimator: DepthEstimating {
    private let context: CIContext
    private let bundle: Bundle
    private var model: MLModel?
    private var usesCPU = false
    init(context: CIContext, bundle: Bundle = .main) {
        self.context = context; self.bundle = bundle
    }

    private func load(cpuOnly: Bool = false) throws -> MLModel {
        if let model, !cpuOnly || usesCPU { return model }
        guard let url = bundle.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            throw OfflineDepthError.missingBundledModel
        }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = cpuOnly ? .cpuOnly : .all
        #endif
        print("[Model] 加载 App 内置模型 \(url.lastPathComponent)，computeUnits=\(configuration.computeUnits.rawValue)")
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded; usesCPU = configuration.computeUnits == .cpuOnly
        return loaded
    }

    func estimate(_ image: CGImage) throws -> DepthField {
        try autoreleasepool {
            try Task.checkCancellation()
            let start = Date()
            let loaded: MLModel
            do { loaded = try load() }
            catch OfflineDepthError.missingBundledModel { throw OfflineDepthError.missingBundledModel }
            catch {
                try Task.checkCancellation()
                print("[Model] 加速模型加载失败，改用本地 CPU：\(error.localizedDescription)")
                loaded = try load(cpuOnly: true)
            }
            guard let feature = loaded.modelDescription.inputDescriptionsByName["image"],
                  let constraint = feature.imageConstraint,
                  constraint.pixelsWide == 518, constraint.pixelsHigh == 392 else {
                throw OfflineDepthError.incompatibleModel("预期 RGB image 518×392")
            }
            // The uploaded model graph already subtracts RGB mean and divides by std.
            // Supply ordinary 0…255 RGB image data. Do NOT normalize it to 0…1 again.
            let buffer = try makeInput(image, width: constraint.pixelsWide, height: constraint.pixelsHigh,
                                       format: constraint.pixelFormatType)
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            try Task.checkCancellation()
            let output: MLFeatureProvider
            do { output = try loaded.prediction(from: input) }
            catch {
                try Task.checkCancellation()
                guard !usesCPU else { throw OfflineDepthError.predictionFailed(error.localizedDescription) }
                print("[Depth] 加速推理失败，本地 CPU 重试：\(error.localizedDescription)")
                do { output = try load(cpuOnly: true).prediction(from: input) }
                catch { throw OfflineDepthError.predictionFailed(error.localizedDescription) }
            }
            try Task.checkCancellation()
            guard let value = output.featureValue(for: "depth") else {
                throw OfflineDepthError.incompatibleModel("缺少 depth 输出")
            }
            let raw: RawDepth
            if let pixels = value.imageBufferValue { raw = try PixelBufferReader.floats(pixels) }
            else if let array = value.multiArrayValue { raw = try Self.readArray(array) }
            else { throw OfflineDepthError.incompatibleModel("depth 不是浮点图像或数组") }
            guard raw.width == 518, raw.height == 392,
                  raw.values.allSatisfy({ $0.isFinite }),
                  let low = raw.values.min(), let high = raw.values.max(), high - low > 0.000001 else {
                throw OfflineDepthError.invalidDepth
            }
            let depth = try DepthField.normalizing(width: raw.width, height: raw.height, values: raw.values)
            guard let normalizedLow = depth.values.min(), let normalizedHigh = depth.values.max(),
                  normalizedHigh - normalizedLow > 0.000001 else { throw OfflineDepthError.invalidDepth }
            print("[Depth] 自动深度完成 \(depth.width)×\(depth.height)，有效像素 \(depth.values.count)/\(depth.values.count)，raw=\(low)…\(high)，\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
            print("[Depth] 来源=完整内置模型；坐标=原图左上角；数值=相对视差（亮近暗远），不是米数")
            return depth
        }
    }

    /// Full-image scale fill: preserve all source content, matching the model's published
    /// fixed-size evaluation. The output field is mapped back across the full source extent.
    /// No rotation, crop, black padding, reference-image coordinates, or second normalization.
    func makeInput(_ image: CGImage, width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attrs as CFDictionary, &optional) == kCVReturnSuccess,
              let buffer = optional else { throw ImagingError.invalidPixelBuffer }
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / CGFloat(image.width), y: CGFloat(height) / CGFloat(image.height)))
        context.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: ImageSupport.colorSpace)
        return buffer
    }

    static func readArray(_ array: MLMultiArray) throws -> RawDepth {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        guard shape.count >= 2, shape.count == strides.count, shape.dropLast(2).allSatisfy({ $0 == 1 }),
              strides.allSatisfy({ $0 > 0 }) else { throw OfflineDepthError.incompatibleModel("depth 数组形状 \(shape)") }
        let w = shape[shape.count - 1], h = shape[shape.count - 2]
        guard w > 0, h > 0, w <= 2048, h <= 2048 else { throw OfflineDepthError.invalidDepth }
        let sx = strides[strides.count - 1], sy = strides[strides.count - 2]
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                let offset = y * sy + x * sx
                switch array.dataType {
                case .float16: values[y*w+x] = Float(Float16(bitPattern: array.dataPointer.assumingMemoryBound(to: UInt16.self)[offset]))
                case .float32: values[y*w+x] = array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
                case .double: values[y*w+x] = Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
                default: throw OfflineDepthError.incompatibleModel("非浮点 depth 数组")
                }
            }
        }
        return RawDepth(width: w, height: h, values: values)
    }
}
