import Foundation
import Vision
import CoreGraphics
import CoreImage

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
    init(context: CIContext) {}
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
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            if faceCount > 0 { throw PersonSegmentationError.incomplete }
            return nil
        }
        let ids = observation.allInstances.sorted()
        guard ids.count <= 4, ids.count >= faceCount, ids.allSatisfy({ $0 > 0 && $0 <= 255 }) else {
            throw PersonSegmentationError.incomplete
        }
        let labels = try PixelBufferReader.labels(observation.instanceMask)
        var subjects: [SubjectMask] = []
        for id in ids {
            try Task.checkCancellation()
            let mask = try autoreleasepool {
                let pixels = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: id), from: handler)
                let coverage = try PixelBufferReader.coverage(pixels)
                do {
                    return try PersonMaskRefinement.refine(coverage)
                } catch PersonMaskRefinementError.incomplete {
                    throw PersonSegmentationError.incomplete
                }
            }
            subjects.append(.init(id: UInt8(id), mask: mask))
        }
        print("[People] 独立人物 \(subjects.count)，软蒙版 \(subjects[0].mask.width)×\(subjects[0].mask.height)")
        return try SubjectSegmentation(labels: labels, subjects: subjects)
    }
}
