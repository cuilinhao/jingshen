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
        let pipeline = PhotoPipeline(subjectAnalyzer: FailingSubjectAnalyzer())
        let photo = try await pipeline.prepare(data: data, title: "offline fixture")
        XCTAssertTrue(photo.analysis.isFallback); XCTAssertNotNil(photo.notice)
        let preview = try await pipeline.preview(photo: photo, recipe: EditRecipe())
        let export = try await pipeline.export(photo: photo, recipe: EditRecipe())
        XCTAssertEqual(preview.rendered.width, 128); XCTAssertEqual(export.image.width, 128)
        XCTAssertFalse(export.jpeg.isEmpty)
    }
    func testValidSubjectCacheBypassesAnalyzer() async throws {
        let label = try GrayMask(width: 2, height: 2, bytes: Data([0,1,0,1]))
        let mask = try GrayMask(width: 2, height: 2, bytes: Data([0,255,0,255]))
        let subjects = try SubjectSegmentation(labels: label, subjects: [SubjectMask(id: 1, mask: mask)])
        let pipeline = PhotoPipeline(subjectAnalyzer: FailingSubjectAnalyzer())
        let photo = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "cached",
                            cachedAnalysis: .subjects(subjects), cachedImageSize: PixelSize(width: 128, height: 128))
        XCTAssertEqual(photo.analysis, .subjects(subjects)); XCTAssertNil(photo.notice)
    }
    func testWrongSizeCacheIsIgnored() async throws {
        let pipeline = PhotoPipeline(subjectAnalyzer: FailingSubjectAnalyzer())
        let depth = try DepthField(width: 2, height: 2, values: [0,1,0,1])
        let photo = try await pipeline.prepare(data: ImageSupport.jpegData(checker()), title: "wrong size",
                         cachedAnalysis: .native(depth), cachedImageSize: PixelSize(width: 33, height: 44))
        XCTAssertTrue(photo.analysis.isFallback)
    }
}

private struct FailingSubjectAnalyzer: SubjectAnalyzing {
    func analyze(_ source: CGImage) throws -> SubjectSegmentation { throw ImagingError.noSubjects }
}
