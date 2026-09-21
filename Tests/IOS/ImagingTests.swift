import XCTest
import CoreImage
import CoreVideo
import ImageIO
@testable import PGYDepthDemo

/// Apple SDK tests included for Command-U. These are NOT claimed as executed on Linux.
final class ImagingTests: XCTestCase {
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
        var recipe = EditRecipe(); recipe.focusMode = .local; recipe.aperture = 1.4; recipe.focusPoint = .center; recipe.localRadius = 0.12
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
    func testOrdinaryImportPreparesRealTypedDepthBeforeExport() async throws {
        let data = try ImageSupport.jpegData(checker())
        let estimator = CountingDepthEstimator()
        let pipeline = PhotoPipeline(depthEstimator: estimator)
        let photo = try await pipeline.prepare(data: data, title: "ordinary image")
        guard case .estimated(let depth) = photo.analysis else { return XCTFail("Must infer instead of blank layers") }
        XCTAssertEqual(estimator.calls, 1); XCTAssertEqual(depth.sourceSHA256.count, 64)
        XCTAssertNotNil(photo.analysis.continuousDepth)
        let preview = try await pipeline.preview(photo: photo, recipe: EditRecipe())
        let export = try await pipeline.export(photo: photo, recipe: EditRecipe())
        XCTAssertEqual(preview.rendered.width, 128); XCTAssertEqual(export.image.width, 128)
        XCTAssertFalse(export.jpeg.isEmpty)
        XCTAssertEqual(estimator.calls, 1, "Rendering must not repeat inference")
    }
    func testValidAutomaticCacheBypassesEstimator() async throws {
        let data = try ImageSupport.jpegData(checker())
        let estimator = CountingDepthEstimator(), pipeline = PhotoPipeline(depthEstimator: CountingDepthEstimator())
        let first = try await pipeline.prepare(data: data, title: "first")
        let secondPipeline = PhotoPipeline(depthEstimator: estimator)
        let second = try await secondPipeline.prepare(data: data, title: "restored", cachedAnalysis: first.analysis, cachedImageSize: first.sourceSize)
        XCTAssertEqual(estimator.calls, 0)
        XCTAssertEqual(first.analysis, second.analysis)
    }
    func testV3BlankCacheRecomputedInsteadOfReturningUnknown() async throws {
        let estimator = CountingDepthEstimator()
        let blank = try SceneLayerMap.blank(width: 128, height: 128)
        let actual = PhotoPipeline(depthEstimator: estimator)
        let photo = try await actual.prepare(data: ImageSupport.jpegData(checker()), title: "v3 draft",
            cachedAnalysis: .layered(.init(map: blank, subjects: nil, notice: nil)), cachedImageSize: .init(width: 128, height: 128))
        XCTAssertEqual(estimator.calls, 1)
        guard case .estimated = photo.analysis else { return XCTFail("Old unknown state leaked") }
    }
    func testWrongImageSameDimensionsCacheIsNotReused() async throws {
        let estimator = CountingDepthEstimator(), pipeline = PhotoPipeline(depthEstimator: CountingDepthEstimator())
        let first = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "A")
        let different = try ImageSupport.grayImage(width: 128, height: 128, bytes: [UInt8](repeating: 120, count: 128*128))
        let actual = PhotoPipeline(depthEstimator: estimator)
        let second = try await actual.prepare(data: ImageSupport.jpegData(different), title: "B", cachedAnalysis: first.analysis, cachedImageSize: first.sourceSize)
        XCTAssertEqual(estimator.calls, 1)
        guard case .estimated(let a) = first.analysis, case .estimated(let b) = second.analysis else { return XCTFail() }
        XCTAssertNotEqual(a.sourceSHA256, b.sourceSHA256)
    }
    func testInferenceFailureDoesNotReturnFakeReadyPhoto() async throws {
        let pipeline = PhotoPipeline(depthEstimator: FailingDepthEstimator())
        do {
            _ = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "failure")
            XCTFail("Inference failure must not return empty layers or circular fallback")
        } catch OfflineDepthError.invalidDepth { /* expected */ }
    }
    func testDepthChangeInvalidatesBothRenderAndDiagnosticCache() async throws {
        let pipeline = PhotoPipeline(depthEstimator: CountingDepthEstimator())
        let photo = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "cache")
        let d = try DepthField(width: 4, height: 2, values: [0.2,0.8,0.2,0.8,0.2,0.8,0.2,0.8])
        let changed = photo.replacingAnalysis(.native(d))
        XCTAssertNotEqual(photo.id, changed.id)
        var r = EditRecipe(); r.focusPoint = .init(x: 0.4, y: 0.5); r.aperture = 1.4
        let a = try await pipeline.preview(photo: photo, recipe: r)
        let b = try await pipeline.preview(photo: changed, recipe: r)
        let context = CIContext()
        XCTAssertNotEqual(rgba(a.mask, context: context), rgba(b.mask, context: context))
    }
    func testLayeredRenderPreservesSameLayerInteriors() throws {
        let context = CIContext(),source = try checker(256)
        let labels = try GrayMask(width:4,height:1,bytes:Data([3,3,1,3]))
        let map = try SceneLayerMap(labels:labels,provenance:.user)
        var r = EditRecipe();r.focusPoint = .init(x:0.35,y:0.5);r.aperture = 1.4;r.edgeFeather = 0
        let result = try DepthRenderer(context:context).render(image:source,photoID:UUID(),
                    analysis:.layered(.init(map:map,subjects:nil,notice:nil)),sourceSize:.init(width:256,height:256),recipe:r)
        let input = rgba(source,context:context), output = rgba(result,context:context)
        // Far from label boundaries: both separated near groups must retain original details.
        for x in [10,30,80,240] {
            for y in 32..<224 { for c in 0..<3 {
                let index = (y*256+x)*4+c
                XCTAssertEqual(output[index],input[index])
            } }
        }
    }
}

/// Test doubles only. The separate CoreMLSmokeTests use the actual bundled model.
private final class CountingDepthEstimator: DepthEstimating {
    private(set) var calls = 0
    func estimate(_ image: CGImage) throws -> DepthField {
        calls += 1
        var values = [Float](repeating: 0.2, count: 40*20)
        for y in 0..<20 { for x in 20..<40 { values[y*40+x] = 0.85 } }
        return try DepthField(width: 40, height: 20, values: values)
    }
}
private struct FailingDepthEstimator: DepthEstimating {
    func estimate(_ image: CGImage) throws -> DepthField { throw OfflineDepthError.invalidDepth }
}
