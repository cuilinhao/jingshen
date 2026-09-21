import Foundation
import CoreML
import Vision
import CoreGraphics

protocol DepthEstimating {
    func estimate(_ source: CGImage) throws -> DepthEstimate
}

enum DepthEstimationError: Error, LocalizedError {
    case missingBundledModel, invalidOutput
    var errorDescription: String? {
        switch self {
        case .missingBundledModel: return "App 中缺少内置景深模型，请重新安装完整版本。"
        case .invalidOutput: return "景深模型没有返回有效深度图。"
        }
    }
}

/// Owned by PhotoPipeline. Both the model and photo stay on-device; no download path.
final class CoreMLDepthEstimator: DepthEstimating {
    private let modelURL: URL?
    private var visionModel: VNCoreMLModel?

    init(modelURL: URL? = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    func estimate(_ source: CGImage) throws -> DepthEstimate {
        try Task.checkCancellation()
        let started = Date()
        if visionModel == nil {
            guard let modelURL else { throw DepthEstimationError.missingBundledModel }
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
            // Simulator MPSGraph can report success with an all-zero output after
            // an unsupported GPU backend error. CPU inference uses the real model.
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = .all
            #endif
            visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: configuration))
        }
        guard let visionModel else { throw DepthEstimationError.missingBundledModel }
        let request = VNCoreMLRequest(model: visionModel)
        // This package has a fixed 518 x 392 input. Preserve the entire frame, not a
        // center crop: normalized output coordinates then map back to the same photo.
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: source, orientation: .up, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        guard let output = request.results?.first as? VNPixelBufferObservation else {
            throw DepthEstimationError.invalidOutput
        }
        let raw = try PixelBufferReader.floats(output.pixelBuffer, longestEdge: 1024)
        let field = try Self.normalizedPrediction(width: raw.width, height: raw.height, values: raw.values)
        print("[Depth] 内置模型推理 \(field.width)×\(field.height)，\(String(format: "%.3f", Date().timeIntervalSince(started)))s")
        return DepthEstimate(field: field)
    }

    static func normalizedPrediction(width: Int, height: Int, values: [Float]) throws -> DepthField {
        guard values.allSatisfy({ $0.isFinite }),
              let maximum = values.max(), maximum > 0.000001 else {
            throw DepthEstimationError.invalidOutput
        }
        return try DepthField.normalizing(width: width, height: height, values: values)
    }
}
