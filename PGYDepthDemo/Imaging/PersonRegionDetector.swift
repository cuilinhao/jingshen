import Foundation
import Vision
import CoreGraphics
import CoreImage

struct DetectedPersonRegion {
    /// Normalized to the original image with a top-left origin, including tile detections.
    let bounds: CGRect
    let confidence: Float
}

/// Finds small or partially occluded people that a whole-image instance mask may omit.
/// These rectangles are candidates for local segmentation, never person masks themselves.
final class PersonRegionDetector {
    private let context: CIContext
    private let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    private enum DetectionError: Error { case cannotPrepareRegion }

    init(context: CIContext) { self.context = context }

    func detect(_ source: CGImage) throws -> [DetectedPersonRegion] {
        try Task.checkCancellation()
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        var regions = [imageBounds]
        let origins: [CGFloat] = [0, 0.275, 0.55]
        for y in origins {
            for x in origins {
                let bounds = CGRect(x: (x * imageBounds.width).rounded(), y: (y * imageBounds.height).rounded(),
                                    width: (0.45 * imageBounds.width).rounded(), height: (0.45 * imageBounds.height).rounded())
                    .intersection(imageBounds)
                if !bounds.isNull, !bounds.isEmpty { regions.append(bounds) }
            }
        }

        var candidates: [DetectedPersonRegion] = []
        for region in regions {
            try Task.checkCancellation()
            let detected: [DetectedPersonRegion] = try autoreleasepool {
                guard let crop = source.cropping(to: region) else { throw DetectionError.cannotPrepareRegion }
                // Match the validated detector input scale for small, blurred background people.
                let scale = 1536.0 / Double(max(crop.width, crop.height))
                let input = CIImage(cgImage: crop).applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
                ])
                guard let scaled = context.createCGImage(input, from: input.extent.integral) else {
                    throw DetectionError.cannotPrepareRegion
                }
                let request = VNDetectHumanRectanglesRequest()
                request.upperBodyOnly = true
                try VNImageRequestHandler(cgImage: scaled, orientation: .up, options: [:]).perform([request])
                try Task.checkCancellation()
                return (request.results ?? []).compactMap { result in
                    guard result.confidence >= 0.55 else { return nil }
                    let box = result.boundingBox
                    // Vision starts at bottom-left; CGImage crop coordinates start at top-left.
                    let mapped = CGRect(x: (region.minX + box.minX * region.width) / imageBounds.width,
                                        y: (region.minY + (1 - box.maxY) * region.height) / imageBounds.height,
                                        width: box.width * region.width / imageBounds.width,
                                        height: box.height * region.height / imageBounds.height)
                        .intersection(unitBounds)
                    guard !mapped.isNull, !mapped.isEmpty else { return nil }
                    return DetectedPersonRegion(bounds: mapped, confidence: result.confidence)
                }
            }
            candidates.append(contentsOf: detected)
        }

        candidates.sort { left, right in
            if left.confidence != right.confidence { return left.confidence > right.confidence }
            if left.bounds.minX != right.bounds.minX { return left.bounds.minX < right.bounds.minX }
            if left.bounds.minY != right.bounds.minY { return left.bounds.minY < right.bounds.minY }
            if left.bounds.width != right.bounds.width { return left.bounds.width < right.bounds.width }
            return left.bounds.height < right.bounds.height
        }
        var distinct: [DetectedPersonRegion] = []
        for candidate in candidates {
            try Task.checkCancellation()
            guard !distinct.contains(where: { isDuplicate(candidate.bounds, $0.bounds) }) else { continue }
            distinct.append(candidate)
            // This bounds local re-segmentation work; it is not a limit on accepted scene people.
            if distinct.count == 24 { break }
        }
        return distinct
    }

    private func isDuplicate(_ left: CGRect, _ right: CGRect) -> Bool {
        let overlap = left.intersection(right)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        let area = overlap.width * overlap.height
        let leftArea = left.width * left.height, rightArea = right.width * right.height
        if area / (leftArea + rightArea - area) > 0.45 { return true }
        let smallArea = min(leftArea, rightArea), largeArea = max(leftArea, rightArea)
        // A large foreground rectangle must not absorb a small background person's candidate.
        return area / smallArea > 0.8 && smallArea / largeArea > 0.5
    }
}
