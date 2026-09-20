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
    private let segmenter: any SubjectAnalyzing
    private let renderer: DepthRenderer
    private struct PreviewAuxiliaryKey: Equatable {
        let id: UUID
        let focus: UnitPoint2D
        let mode: FocusMode
        let tolerance: Double
        let radius: Double
        let feather: Double
        let crop: CropRatio
    }
    private var auxiliaryKey: PreviewAuxiliaryKey?
    private var auxiliaryImages: (original: CGImage, mask: CGImage)?

    init(subjectAnalyzer: (any SubjectAnalyzing)? = nil) {
        let context = CIContext(options: [.cacheIntermediates: false,
                                          .workingColorSpace: ImageSupport.colorSpace,
                                          .outputColorSpace: ImageSupport.colorSpace])
        self.context = context
        segmenter = subjectAnalyzer ?? NativeSubjectSegmenter(context: context)
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
            // Matching source size is mandatory for cached spatial data. DraftStore commits
            // original data, analysis and recipe as one snapshot; a corrupt cache is discarded.
            if let cachedAnalysis, cachedImageSize == size, !cachedAnalysis.isFallback {
                analysis = cachedAnalysis
                print("[Subjects] 恢复已保存的原生分析缓存，不重复识别")
            } else if let native = decoded.nativeDepth {
                analysis = .native(native)
            } else {
                do {
                    analysis = .subjects(try segmenter.analyze(decoded.image))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    // Not a fatal import error, not a downloaded resource, not pretend depth.
                    let reason = "系统主体识别未完成：\(error.localizedDescription)"
                    analysis = .localFallback(reason: reason)
                    notice = "未识别到主体，已使用局部虚化；可在细调中调整范围"
                    print("[Subjects] \(reason)；明确切换为圆形局部虚化")
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
                                          tolerance: recipe.focusTolerance, radius: recipe.localRadius,
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
