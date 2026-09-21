import Foundation
import CoreImage
import CoreGraphics
import CryptoKit

/// CGImage is immutable here. Analysis data is immutable and scoped to this photo ID.
struct PhotoSession: @unchecked Sendable {
    let id: UUID
    let sourceData: Data
    let title: String
    let original: CGImage
    let preview: CGImage
    let analysis: PhotoAnalysis
    let notice: String?
    var portrait: PortraitAnalysis? = nil
    var portraitCacheReused = false
    var sourceSize: PixelSize { PixelSize(width: original.width, height: original.height) }
    func replacingAnalysis(_ analysis: PhotoAnalysis) -> PhotoSession {
        // New identity invalidates BOTH renderer and auxiliary caches after any layer edit.
        PhotoSession(id: UUID(), sourceData: sourceData, title: title, original: original,
                     preview: preview, analysis: analysis, notice: nil, portrait: portrait, portraitCacheReused: true)
    }
    func draft(recipe: EditRecipe) -> SavedDraft {
        SavedDraft(sourceData: sourceData, title: title, recipe: recipe, analysis: analysis, imageSize: sourceSize, portrait: portrait)
    }
}

struct PreviewResult: @unchecked Sendable {
    let rendered: CGImage
    let original: CGImage
    let mask: CGImage
    var selectionOutline: CGImage? = nil
}
struct ExportResult: @unchecked Sendable {
    let image: CGImage
    let jpeg: Data
}

actor PhotoPipeline {
    private let context: CIContext
    private var depthEstimator: any DepthEstimating
    private let injectedEstimator: Bool
    private var loadedModelChoice: DepthModelChoice = .v3
    private let subjectAnalyzer: (any SubjectAnalyzing)?
    private let renderer: DepthRenderer
    private struct PreviewAuxiliaryKey: Equatable {
        let id: UUID
        let focus: UnitPoint2D
        let mode: FocusMode
        let selectedID: UInt8?
        let tolerance: Double
        let radius: Double
        let feather: Double
        let crop: CropRatio
    }
    private var auxiliaryKey: PreviewAuxiliaryKey?
    private var auxiliaryImages: (original: CGImage, mask: CGImage, outline: CGImage?)?

    init(depthEstimator: (any DepthEstimating)? = nil, subjectAnalyzer: (any SubjectAnalyzing)? = nil, analyzePeople: Bool = true) {
        let context = CIContext(options: [.cacheIntermediates: false,
                                          .workingColorSpace: ImageSupport.linearColorSpace,
                                          .outputColorSpace: ImageSupport.colorSpace])
        self.context = context
        self.depthEstimator = depthEstimator ?? OfflineDepthEstimator(context: context)
        injectedEstimator = depthEstimator != nil
        self.subjectAnalyzer = analyzePeople ? (subjectAnalyzer ?? NativeSubjectSegmenter(context: context)) : nil
        renderer = DepthRenderer(context: context)
    }

    func prepare(data: Data, title: String, cachedAnalysis: PhotoAnalysis? = nil,
                 cachedImageSize: PixelSize? = nil, cachedPortrait: PortraitAnalysis? = nil,
                 modelChoice: DepthModelChoice = .v3) throws -> PhotoSession {
        try autoreleasepool {
            try Task.checkCancellation()
            if !injectedEstimator, loadedModelChoice != modelChoice {
                depthEstimator = OfflineDepthEstimator(context: context, modelChoice: modelChoice)
                loadedModelChoice = modelChoice
            }
            let decoded = try PhotoLoader.decode(data, context: context)
            let size = PixelSize(width: decoded.image.width, height: decoded.image.height)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let analysis: PhotoAnalysis
            var notice: String?
            if let native = decoded.nativeDepth {
                // Re-read authoritative camera metadata. Never trust a v1 AI cache tagged native.
                analysis = .native(native)
            } else if cachedImageSize == size,
                      let cached = AutomaticDepthCache.reusable(cachedAnalysis, sourceSHA256: digest, imageSize: size, modelChoice: modelChoice) {
                analysis = .estimated(cached)
                print("[Depth] 恢复已校验的自动深度缓存；source SHA256、模型版本、预处理及尺寸均一致")
            } else {
                if cachedAnalysis != nil {
                    print("[Depth] 旧/失效分析缓存不含当前有效自动深度；保留原图和编辑参数，重新本地推理")
                }
                let field = try depthEstimator.estimate(decoded.image)
                try Task.checkCancellation()
                analysis = .estimated(InferredDepth(field: field, sourceSHA256: digest, imageSize: size, modelChoice: modelChoice))
                notice = "离线自动深度已生成，点击照片选择清晰景深范围"
            }
            try Task.checkCancellation()
            var portrait: PortraitAnalysis?
            var portraitCacheReused = false
            if let subjectAnalyzer {
                if let cachedPortrait, cachedPortrait.matches(sourceSHA256: digest, imageSize: size) {
                    portrait = cachedPortrait; portraitCacheReused = true
                } else {
                    do {
                        if let people = try subjectAnalyzer.analyze(decoded.image) {
                            portrait = try PortraitAnalysis(segmentation: people, sourceSHA256: digest, imageSize: size)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        notice = "人物识别未完成，当前为普通景深：\(error.localizedDescription)"
                        print("[People] \(notice!)")
                    }
                }
                if let portrait { notice = "已识别\(portrait.segmentation.subjects.count)个人，点击人物切换清晰主体" }
                else if notice == nil || notice == "离线自动深度已生成，点击照片选择清晰景深范围" {
                    notice = "未识别到可独立选择的人物，当前使用普通景深"
                }
            }
            try Task.checkCancellation()
            let preview = try ImageSupport.resized(decoded.image, longestEdge: 1024, context: context)
            // No intermediate blank-layer PhotoSession is ever returned as ready.
            return PhotoSession(id: UUID(), sourceData: data, title: title, original: decoded.image,
                                preview: preview, analysis: analysis, notice: notice,
                                portrait: portrait, portraitCacheReused: portraitCacheReused)
        }
    }

    func preview(photo: PhotoSession, recipe: EditRecipe) throws -> PreviewResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let rendered = try renderer.render(image: photo.preview, photoID: photo.id, analysis: photo.analysis,
                                               sourceSize: photo.sourceSize, recipe: recipe, portrait: photo.portrait)
            let key = PreviewAuxiliaryKey(id: photo.id, focus: recipe.focusPoint, mode: recipe.focusMode, selectedID: recipe.selectedPersonID,
                                          tolerance: recipe.focusTolerance, radius: recipe.localRadius,
                                          feather: recipe.edgeFeather, crop: recipe.crop)
            let original: CGImage, mask: CGImage, outline: CGImage?
            if auxiliaryKey == key, let images = auxiliaryImages {
                original = images.original; mask = images.mask; outline = images.outline
            } else {
                original = try renderer.original(image: photo.preview, crop: recipe.crop, sourceSize: photo.sourceSize)
                mask = try renderer.maskPreview(image: photo.preview, photoID: photo.id, analysis: photo.analysis,
                                                sourceSize: photo.sourceSize, recipe: recipe, portrait: photo.portrait)
                outline = try renderer.selectionOutline(image: photo.preview, sourceSize: photo.sourceSize,
                                                        recipe: recipe, portrait: photo.portrait)
                auxiliaryKey = key; auxiliaryImages = (original, mask, outline)
            }
            try Task.checkCancellation()
            return PreviewResult(rendered: rendered, original: original, mask: mask, selectionOutline: outline)
        }
    }

    func export(photo: PhotoSession, recipe: EditRecipe) throws -> ExportResult {
        print("[Export] 原始输入重新渲染，最长边≤2048；来源=\(photo.analysis.sourceDescription)，f=\(recipe.aperture)")
        return try autoreleasepool {
            let rendered = try renderer.render(image: photo.original, photoID: photo.id, analysis: photo.analysis,
                                               sourceSize: photo.sourceSize, recipe: recipe, portrait: photo.portrait)
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
