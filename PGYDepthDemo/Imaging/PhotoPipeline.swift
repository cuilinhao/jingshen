import Foundation
import CoreImage
import CoreGraphics

/// CGImage is immutable here. Analysis data is immutable and scoped to this photo ID.
struct PhotoSession: @unchecked Sendable {
    let id: UUID
    let sourceData: Data
    let title: String
    let original: CGImage
    let preview: CGImage
    let analysis: PhotoAnalysis
    let notice: String?
    var sourceSize: PixelSize { PixelSize(width: original.width, height: original.height) }
    func draft(recipe: EditRecipe) -> SavedDraft {
        SavedDraft(sourceData: sourceData, title: title, recipe: recipe, analysis: analysis, imageSize: sourceSize)
    }
}

struct PreviewResult: @unchecked Sendable {
    let rendered: CGImage
    let original: CGImage
    let mask: CGImage
}
struct ExportResult: @unchecked Sendable {
    let image: CGImage
    let jpeg: Data
}

actor PhotoPipeline {
    private let context: CIContext
    private let depthEstimator: any DepthEstimating
    private let renderer: DepthRenderer
    private struct PreviewAuxiliaryKey: Equatable {
        let id: UUID
        let focus: UnitPoint2D
        let mode: FocusMode
        let tolerance: Double
        let estimatedTolerance: Double
        let radius: Double
        let feather: Double
        let crop: CropRatio
    }
    private var auxiliaryKey: PreviewAuxiliaryKey?
    private var auxiliaryImages: (original: CGImage, mask: CGImage)?

    init(depthEstimator: (any DepthEstimating)? = nil) {
        let context = CIContext(options: [.cacheIntermediates: false,
                                          .workingColorSpace: ImageSupport.colorSpace,
                                          .outputColorSpace: ImageSupport.colorSpace])
        self.context = context
        self.depthEstimator = depthEstimator ?? CoreMLDepthEstimator()
        renderer = DepthRenderer(context: context)
    }

    func prepare(data: Data, title: String, cachedAnalysis: PhotoAnalysis? = nil,
                 cachedImageSize: PixelSize? = nil) throws -> PhotoSession {
        try autoreleasepool {
            try Task.checkCancellation()
            let decoded = try PhotoLoader.decode(data, context: context)
            let size = PixelSize(width: decoded.image.width, height: decoded.image.height)
            let analysis: PhotoAnalysis
            var notice: String?
            // The source's oriented native depth is authoritative, even when a draft
            // contains a matching AI estimate. Cache reuse is only for photos without it,
            // and requires matching source dimensions. DraftStore commits the source,
            // analysis and recipe together so stale spatial data can be discarded.
            if let native = decoded.nativeDepth {
                analysis = .native(native)
            } else if let cachedAnalysis, cachedImageSize == size, cachedAnalysis.supportsAutomaticDepthCache {
                analysis = cachedAnalysis
                print("[Depth] 恢复当前版本景深缓存，不重复推理")
            } else {
                do {
                    analysis = .estimated(try depthEstimator.estimate(decoded.image))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    // Not a fatal import error, not a downloaded resource, not pretend depth.
                    let reason = "本机景深分析未完成：\(error.localizedDescription)"
                    analysis = .localFallback(reason: reason)
                    notice = "景深分析失败，已使用局部虚化；可重试景深分析"
                    print("[Depth] \(reason)；明确切换为圆形局部虚化")
                }
            }
            if case .subjects(let s) = analysis, s.groupedSubjectCount > 0 {
                notice = "主体较多，其中 \(s.groupedSubjectCount) 个合并为一组"
            }
            try Task.checkCancellation()
            let preview = try ImageSupport.resized(decoded.image, longestEdge: 1024, context: context)
            return PhotoSession(id: UUID(), sourceData: data, title: title, original: decoded.image,
                                preview: preview, analysis: analysis, notice: notice)
        }
    }

    func preview(photo: PhotoSession, recipe: EditRecipe) throws -> PreviewResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let rendered = try renderer.render(image: photo.preview, photoID: photo.id, analysis: photo.analysis,
                                               sourceSize: photo.sourceSize, recipe: recipe)
            let key = PreviewAuxiliaryKey(id: photo.id, focus: recipe.focusPoint, mode: recipe.focusMode,
                                          tolerance: recipe.focusTolerance, estimatedTolerance: recipe.estimatedFocusTolerance, radius: recipe.localRadius,
                                          feather: recipe.edgeFeather, crop: recipe.crop)
            let original: CGImage, mask: CGImage
            if auxiliaryKey == key, let images = auxiliaryImages {
                original = images.original; mask = images.mask
            } else {
                original = try renderer.original(image: photo.preview, crop: recipe.crop, sourceSize: photo.sourceSize)
                mask = try renderer.maskPreview(image: photo.preview, photoID: photo.id, analysis: photo.analysis,
                                                sourceSize: photo.sourceSize, recipe: recipe)
                auxiliaryKey = key; auxiliaryImages = (original, mask)
            }
            try Task.checkCancellation()
            return PreviewResult(rendered: rendered, original: original, mask: mask)
        }
    }

    func export(photo: PhotoSession, recipe: EditRecipe) throws -> ExportResult {
        print("[Export] 原始输入重新渲染，最长边≤2048；来源=\(photo.analysis.sourceDescription)，f=\(recipe.aperture)")
        return try autoreleasepool {
            let rendered = try renderer.render(image: photo.original, photoID: photo.id, analysis: photo.analysis,
                                               sourceSize: photo.sourceSize, recipe: recipe)
            return ExportResult(image: rendered, jpeg: try ImageSupport.jpegData(rendered))
        }
    }

    func readFile(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let bytes = attributes[.size] as? NSNumber, bytes.intValue > 100 * 1024 * 1024 { throw ImagingError.imageTooLarge }
        return try Data(contentsOf: url)
    }
    func writeTemporaryJPEG(_ data: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PGYDepthExports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Depth-\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return url
    }
    func removeTemporaryFile(_ url: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PGYDepthExports", isDirectory: true)
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
