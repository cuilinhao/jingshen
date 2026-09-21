import Foundation
import Vision
import CoreGraphics
import CoreImage
import CoreVideo

protocol SubjectAnalyzing {
    func analyze(_ source: CGImage) throws -> SubjectSegmentation?
}

enum PersonSegmentationError: Error, LocalizedError {
    case crowded, incomplete
    var errorDescription: String? {
        switch self {
        case .crowded: return "检测到超过4个人，当前无法逐人选择，已使用普通景深。"
        case .incomplete: return "未能可靠分开所有人物，已使用普通景深；可更换照片后重试。"
        }
    }
}

/// Per-person soft mattes at the decoded image resolution, not the 504px depth resolution.
/// Called on PhotoPipeline's serial actor, off the main thread.
final class NativeSubjectSegmenter: SubjectAnalyzing {
    private let context: CIContext
    private let detector: PersonRegionDetector
    init(context: CIContext) { self.context = context; detector = PersonRegionDetector(context: context) }
    func analyze(_ source: CGImage) throws -> SubjectSegmentation? {
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: source, orientation: .up, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        try handler.perform([faces])
        let faceCount = faces.results?.count ?? 0
        guard faceCount <= 4 else { throw PersonSegmentationError.crowded }
        let request = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([request])
        try Task.checkCancellation()
        var masks: [GrayMask] = []
        if let observation = request.results?.first {
            guard observation.allInstances.count <= 4 else { throw PersonSegmentationError.crowded }
            for id in observation.allInstances.sorted() {
                try Task.checkCancellation()
                do {
                    let mask = try autoreleasepool {
                        let pixels = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: id), from: handler)
                        return try PersonMaskRefinement.refine(PixelBufferReader.coverage(pixels))
                    }
                    masks.append(mask)
                } catch PersonMaskRefinementError.incomplete {
                    // A small weak instance can be recovered from its own region below.
                }
            }
        }
        let fullCount = masks.count
        let regions = try detector.detect(source)
        for region in regions {
            try Task.checkCancellation()
            let anchor = headAnchor(region.bounds)
            // Rectangles may overlap heavily during occlusion. Test visible coverage, not
            // bounding-box containment, so a large foreground body cannot swallow small people.
            if masks.contains(where: { $0.value(at: anchor) >= 128 }) { continue }
            if let mask = try recover(region, source: source, occupied: masks) {
                guard masks.count < 4 else { throw PersonSegmentationError.crowded }
                masks.append(mask)
            }
        }
        guard !masks.isEmpty else {
            if faceCount > 0 || !regions.isEmpty { throw PersonSegmentationError.incomplete }
            return nil
        }
        // Count after recovery. A whole-frame omission must not prevent a local attempt.
        guard masks.count >= faceCount else { throw PersonSegmentationError.incomplete }
        print("[People] 整图 \(fullCount)，局部补充 \(masks.count - fullCount)，独立人物 \(masks.count)，软蒙版 \(masks[0].width)×\(masks[0].height)")
        return try PersonMaskAssembly.segmentation(masks: masks)
    }

    private func headAnchor(_ bounds: CGRect) -> UnitPoint2D {
        UnitPoint2D(x: bounds.midX, y: bounds.minY + bounds.height * 0.25)
    }

    private func recover(_ region: DetectedPersonRegion, source: CGImage, occupied: [GrayMask]) throws -> GrayMask? {
        try autoreleasepool {
            let size = PixelSize(width: source.width, height: source.height)
            let box = CGRect(x: region.bounds.minX * Double(size.width), y: region.bounds.minY * Double(size.height),
                             width: region.bounds.width * Double(size.width), height: region.bounds.height * Double(size.height))
            // Tight context matters: a large crop can make the small person insignificant again
            // and cause nearby furniture to dominate the matte. Detection boxes never become masks.
            let cropRect = box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.15).integral
                .intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let crop = source.cropping(to: cropRect) else { return nil }
            // Give small heads a consistent input scale. Feeding the tiny crop directly
            // can make a connected chair frame look like part of the portrait silhouette.
            let scale = 768.0 / Double(max(crop.width, crop.height))
            let input = CIImage(cgImage: crop).applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
            ])
            guard let scaled = context.createCGImage(input, from: input.extent.integral) else { return nil }
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try VNImageRequestHandler(cgImage: scaled, orientation: .up, options: [:]).perform([request])
            try Task.checkCancellation()
            guard let pixels = request.results?.first?.pixelBuffer else { return nil }
            let projected = try PersonMaskAssembly.project(PixelBufferReader.coverage(pixels),
                left: Int(cropRect.minX), top: Int(cropRect.minY), width: Int(cropRect.width), height: Int(cropRect.height), imageSize: size)
            let refined: GrayMask
            do { refined = try PersonMaskRefinement.refine(projected) }
            catch PersonMaskRefinementError.incomplete { return nil }
            let novel = try PersonMaskAssembly.removingOverlap(from: refined, occupied: occupied)
            let radius = max(1, Int(min(box.width, box.height) * 0.15))
            guard let component = try PersonMaskAssembly.component(in: novel, near: headAnchor(region.bounds), searchRadius: radius),
                  component.bytes.contains(where: { $0 >= 224 }) else { return nil }
            return component
        }
    }
}
