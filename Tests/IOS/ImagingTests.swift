import XCTest
import CoreImage
import CoreVideo
import ImageIO
import UIKit
@testable import PGYDepthDemo

/// Apple SDK tests included for Command-U. These are NOT claimed as executed on Linux.
final class ImagingTests: XCTestCase {
    func testInvalidModelPredictionsDoNotBecomeSuccessfulFlatDepth() throws {
        for values: [Float] in [[0, 0, 0, 0], [.nan, 1, 2, 3], [1, .infinity, 2, 3]] {
            XCTAssertThrowsError(try CoreMLDepthEstimator.normalizedPrediction(width: 2, height: 2, values: values))
        }
        let valid = try CoreMLDepthEstimator.normalizedPrediction(width: 2, height: 2, values: [1, 2, 3, 4])
        XCTAssertLessThan(valid.values[0], valid.values[3])
    }
    private func checker(_ side: Int = 128) throws -> CGImage {
        var data = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side { data[y * side + x] = ((x / 2 + y / 2) % 2 == 0) ? 0 : 255 } }
        return try ImageSupport.grayImage(width: side, height: side, bytes: data)
    }
    private func rgba(_ image: CGImage, context: CIContext) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { data in
            context.render(CIImage(cgImage: image), toBitmap: data.baseAddress!, rowBytes: image.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                           format: .RGBA8, colorSpace: ImageSupport.colorSpace)
        }
        return bytes
    }
    private func render(_ image: CGImage, recipe: EditRecipe, context: CIContext) throws -> CGImage {
        try DepthRenderer(context: context).render(image: image, photoID: UUID(), analysis: .localFallback(reason: "test"),
                    sourceSize: PixelSize(width: image.width, height: image.height), recipe: recipe)
    }
    func testGrayImageRetainsTopLeftRowOrder() throws {
        let image = try ImageSupport.grayImage(width: 2, height: 2, bytes: [0, 64, 192, 255])
        let bytes = try XCTUnwrap(image.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(bytes))
        XCTAssertEqual(pointer[0], 0); XCTAssertEqual(pointer[1], 64)
        XCTAssertEqual(pointer[image.bytesPerRow], 192); XCTAssertEqual(pointer[image.bytesPerRow + 1], 255)
    }
    func testCICropConvertsTopLeftOrigin() {
        let rect = ImageSupport.ciCropRect(unit: Rect2D(x: 0.1, y: 0.2, width: 0.5, height: 0.3),
                                          extent: CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(rect.origin.x, 10, accuracy: 0.001); XCTAssertEqual(rect.origin.y, 100, accuracy: 0.001)
        XCTAssertEqual(rect.width, 50, accuracy: 0.001); XCTAssertEqual(rect.height, 60, accuracy: 0.001)
    }
    func testNativeFilterParametersExist() throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIMaskedVariableBlur"))
        XCTAssertTrue(filter.inputKeys.contains("inputMask")); XCTAssertTrue(filter.inputKeys.contains("inputRadius"))
        XCTAssertNotNil(CIFilter(name: "CIBlendWithMask"))
    }
    func testDisabledEffectReallyPreservesPixelsNotJustDimensions() throws {
        let context = CIContext(), source = try checker()
        var recipe = EditRecipe(); recipe.depthEnabled = false
        let output = try render(source, recipe: recipe, context: context)
        XCTAssertEqual(rgba(output, context: context), rgba(source, context: context))
    }
    func testMaximumFNumberRemovesBlur() throws {
        let context = CIContext(), source = try checker()
        var recipe = EditRecipe(); recipe.aperture = 16
        let output = try render(source, recipe: recipe, context: context)
        XCTAssertEqual(rgba(output, context: context), rgba(source, context: context))
    }
    func testEnabledLocalBlurReducesHighFrequencyDetail() throws {
        let context = CIContext(), source = try checker()
        var recipe = EditRecipe(); recipe.aperture = 1.4; recipe.focusPoint = .center; recipe.localRadius = 0.12
        let output = try render(source, recipe: recipe, context: context)
        func variation(_ bytes: [UInt8]) -> Double {
            let values = stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) }
            let mean = values.reduce(0,+) / Double(values.count)
            return values.map { ($0 - mean) * ($0 - mean) }.reduce(0,+) / Double(values.count)
        }
        XCTAssertLessThan(variation(rgba(output, context: context)), variation(rgba(source, context: context)) * 0.8)
    }
    func testPixelBufferLabelsRespectPaddedRows() throws {
        var optional: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_OneComponent8, attributes, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let row = CVPixelBufferGetBytesPerRow(buffer)
        base.initializeMemory(as: UInt8.self, repeating: 99, count: row * 2)
        for y in 0..<2 { for x in 0..<3 { base.assumingMemoryBound(to: UInt8.self)[y * row + x] = UInt8(y * 3 + x) } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertEqual(Array(try PixelBufferReader.labels(buffer).bytes), [0,1,2,3,4,5])
    }
    func testFloatCoverageClampsInvalidValuesAndRetainsSoftEdge() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_OneComponent32Float, nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let values: [Float] = [0, 0.5, 1, .nan, -2, 3]
        for y in 0..<2 {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<3 { row[x] = values[y * 3 + x] }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertEqual(Array(try PixelBufferReader.coverage(buffer).bytes), [0,128,255,0,0,255])
    }
    func testFailedSystemRecognitionStillPreparesAndExportsPhoto() async throws {
        let data = try ImageSupport.jpegData(checker())
        let pipeline = PhotoPipeline(depthEstimator: FailingDepthEstimator())
        let photo = try await pipeline.prepare(data: data, title: "offline fixture")
        XCTAssertTrue(photo.analysis.isFallback); XCTAssertNotNil(photo.notice)
        let preview = try await pipeline.preview(photo: photo, recipe: EditRecipe())
        let export = try await pipeline.export(photo: photo, recipe: EditRecipe())
        XCTAssertEqual(preview.rendered.width, 128); XCTAssertEqual(export.image.width, 128)
        XCTAssertFalse(export.jpeg.isEmpty)
    }
    func testLegacySubjectCacheIsReplacedByEstimatedDepth() async throws {
        let label = try GrayMask(width: 2, height: 2, bytes: Data([0,1,0,1]))
        let mask = try GrayMask(width: 2, height: 2, bytes: Data([0,255,0,255]))
        let subjects = try SubjectSegmentation(labels: label, subjects: [SubjectMask(id: 1, mask: mask)])
        let field = try DepthField(width: 2, height: 2, values: [0.1,0.8,0.1,0.8])
        let pipeline = PhotoPipeline(depthEstimator: FixedDepthEstimator(field: field))
        let photo = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "cached",
                            cachedAnalysis: .subjects(subjects), cachedImageSize: PixelSize(width: 128, height: 128))
        XCTAssertEqual(photo.analysis, .estimated(DepthEstimate(field: field))); XCTAssertNil(photo.notice)
    }
    func testWrongSizeCacheIsIgnored() async throws {
        let pipeline = PhotoPipeline(depthEstimator: FailingDepthEstimator())
        let depth = try DepthField(width: 2, height: 2, values: [0,1,0,1])
        let photo = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "wrong size",
                         cachedAnalysis: .native(depth), cachedImageSize: PixelSize(width: 33, height: 44))
        XCTAssertTrue(photo.analysis.isFallback)
    }
    func testCurrentEstimatedCacheBypassesModel() async throws {
        let field = try DepthField(width: 2, height: 2, values: [0.1,0.8,0.1,0.8])
        let analysis = PhotoAnalysis.estimated(DepthEstimate(field: field))
        let pipeline = PhotoPipeline(depthEstimator: FailingDepthEstimator())
        let photo = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "cached depth",
                          cachedAnalysis: analysis, cachedImageSize: PixelSize(width: 128, height: 128))
        XCTAssertEqual(photo.analysis, analysis)
    }

    func testBundledModelSeparatesUserPhotoFocusPlanes() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "FocusScene", withExtension: "png"))
        let pipeline = PhotoPipeline()
        let photo = try await pipeline.prepare(data: Data(contentsOf: url), title: "FocusScene")
        guard case .estimated(let estimate) = photo.analysis else {
            return XCTFail("Expected bundled depth model, got \(photo.analysis.sourceDescription): \(photo.notice ?? "")")
        }
        let bottle = UnitPoint2D(x: 0.457, y: 0.715)
        let monitor = UnitPoint2D(x: 0.15, y: 0.45)
        let cabinet = UnitPoint2D(x: 0.826, y: 0.568)
        XCTAssertGreaterThan(DepthFocus.focus(in: estimate.field, at: bottle), DepthFocus.focus(in: estimate.field, at: cabinet) + 0.35)
        var recipe = EditRecipe(); recipe.aperture = 2.1; recipe.focusPoint = bottle
        let nearMasks = try FocusMaskBuilder.make(analysis: photo.analysis, recipe: recipe, imageSize: photo.sourceSize)
        XCTAssertEqual(nearMasks.blur.value(at: bottle), 0)
        XCTAssertLessThan(nearMasks.blur.value(at: monitor), 15, "Same clear depth band must preserve monitor")
        XCTAssertGreaterThan(nearMasks.blur.value(at: cabinet), 220)
        let near = try await pipeline.preview(photo: photo, recipe: recipe)
        try saveEvidence(near.rendered, name: "near-focus")
        try saveEvidence(near.mask, name: "estimated-depth")
        let nearExport = try await pipeline.export(photo: photo, recipe: recipe)
        try saveEvidence(nearExport.image, name: "near-export")
        XCTAssertEqual(nearExport.image.width, photo.original.width)
        XCTAssertEqual(nearExport.image.height, photo.original.height)
        let context = CIContext()
        let reducedExport = try ImageSupport.resized(nearExport.image, longestEdge: 1024, context: context)
        let previewBytes = rgba(near.rendered, context: context)
        let exportBytes = rgba(reducedExport, context: context)
        XCTAssertEqual(previewBytes.count, exportBytes.count)
        let meanDifference = zip(previewBytes, exportBytes).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(previewBytes.count)
        XCTAssertLessThan(meanDifference, 8, "Preview/export must use the same aligned focal region")
        var noBlur = recipe; noBlur.aperture = 16
        let noBlurResult = try await pipeline.preview(photo: photo, recipe: noBlur)
        XCTAssertEqual(rgba(noBlurResult.rendered, context: context), rgba(noBlurResult.original, context: context))
        noBlur.aperture = 2.1; noBlur.depthEnabled = false
        let disabled = try await pipeline.preview(photo: photo, recipe: noBlur)
        XCTAssertEqual(rgba(disabled.rendered, context: context), rgba(disabled.original, context: context))
        var narrow = recipe; narrow.estimatedFocusTolerance = 0.02
        let narrowResult = try await pipeline.preview(photo: photo, recipe: narrow)
        XCTAssertNotEqual(rgba(narrowResult.rendered, context: context), previewBytes)
        let restoredBand = try await pipeline.preview(photo: photo, recipe: recipe)
        XCTAssertEqual(rgba(restoredBand.rendered, context: context), previewBytes, "Changing clear band must invalidate the mask cache")
        recipe.focusPoint = cabinet
        let farMasks = try FocusMaskBuilder.make(analysis: photo.analysis, recipe: recipe, imageSize: photo.sourceSize)
        XCTAssertEqual(farMasks.blur.value(at: cabinet), 0)
        XCTAssertGreaterThan(farMasks.blur.value(at: bottle), 220)
        XCTAssertGreaterThan(farMasks.blur.value(at: monitor), 200)
        let far = try await pipeline.preview(photo: photo, recipe: recipe)
        try saveEvidence(far.rendered, name: "far-focus")
        let farExport = try await pipeline.export(photo: photo, recipe: recipe)
        try saveEvidence(farExport.image, name: "far-export")
        XCTAssertNotEqual(nearMasks.blur, farMasks.blur)
        // Cached model depth must survive draft round-trip without re-running inference.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(root: root)
        try await store.save(photo.draft(recipe: recipe))
        let saved = try await store.load()
        XCTAssertEqual(saved?.analysis, photo.analysis)
    }

    private func saveEvidence(_ image: CGImage, name: String) throws {
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DepthVerification", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(folder.appendingPathComponent(name + ".png") as CFURL,
                                                                     "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private struct FailingDepthEstimator: DepthEstimating {
    func estimate(_ source: CGImage) throws -> DepthEstimate { throw ImagingError.cannotRender }
}
private struct FixedDepthEstimator: DepthEstimating {
    let field: DepthField
    func estimate(_ source: CGImage) throws -> DepthEstimate { DepthEstimate(field: field) }
}
