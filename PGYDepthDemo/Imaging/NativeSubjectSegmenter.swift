import Foundation
import Vision
import CoreGraphics
import CoreImage

protocol SubjectAnalyzing {
    func analyze(_ source: CGImage) throws -> SubjectSegmentation
}

/// Uses only Apple's system Vision request. No bundled model, SDK dependency, or network code.
/// Owned by PhotoPipeline's actor: request.perform must not block the MainActor.
final class NativeSubjectSegmenter: SubjectAnalyzing {
    private let context: CIContext
    init(context: CIContext) { self.context = context }

    func analyze(_ source: CGImage) throws -> SubjectSegmentation {
        try Task.checkCancellation()
        let started = Date()
        // Limit mask memory and analysis cost. Export scales soft masks to the source (≤2048).
        let image = try ImageSupport.resized(source, longestEdge: 1024, context: context)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        print("[Subjects] 系统 Vision 分析 \(image.width)×\(image.height)，不下载外部资源")
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ImagingError.noSubjects
        }
        let rawLabels = try PixelBufferReader.labels(observation.instanceMask)
        let ids = observation.allInstances.sorted()
        guard ids.allSatisfy({ $0 > 0 && $0 <= 255 }) else { throw ImagingError.invalidPixelBuffer }

        // Bound worst-case memory: up to 15 individual subjects + one group for the rest.
        // Relabel the remaining pixels to that group ID; NEVER silently treat them as background.
        var groups: [(id: UInt8, instances: IndexSet)] = []
        var labels = rawLabels
        let groupedCount: Int
        if ids.count > 16 {
            for id in ids.prefix(15) { groups.append((UInt8(id), IndexSet(integer: id))) }
            let remaining = Array(ids.dropFirst(15)), groupID = UInt8(ids[15])
            let membership = Set(remaining)
            groups.append((groupID, IndexSet(remaining)))
            labels = try GrayMask(width: rawLabels.width, height: rawLabels.height,
                                  bytes: Data(rawLabels.bytes.map { membership.contains(Int($0)) ? groupID : $0 }))
            groupedCount = remaining.count
        } else {
            groups = ids.map { (UInt8($0), IndexSet(integer: $0)) }
            groupedCount = 0
        }
        var subjects: [SubjectMask] = []
        for group in groups {
            try Task.checkCancellation()
            let mask = try autoreleasepool {
                let buffer = try observation.generateScaledMaskForImage(forInstances: group.instances, from: handler)
                return try PixelBufferReader.coverage(buffer)
            }
            guard mask.bytes.contains(where: { $0 > 8 }) else { throw ImagingError.noSubjects }
            subjects.append(SubjectMask(id: group.id, mask: mask))
        }
        let result = try SubjectSegmentation(labels: labels, subjects: subjects, groupedSubjectCount: groupedCount)
        print("[Subjects] 已缓存 \(result.subjects.count) 个主体/组，耗时 \(String(format: "%.3f", Date().timeIntervalSince(started)))s")
        return result
    }
}
