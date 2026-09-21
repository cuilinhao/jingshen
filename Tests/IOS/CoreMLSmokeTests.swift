import XCTest
import UIKit
import CoreML
import CoreImage
import CoreVideo
@testable import PGYDepthDemo

/// These tests require an actual Apple runtime. They are intentionally NOT mocks and are
/// not marked skipped when the model is absent. Run Command-U with the complete v4 target.
final class CoreMLSmokeTests: XCTestCase {
    func testCompiledModelIsActuallyInAppBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc"), "Model must be compiled into App, not downloaded later")
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let image = try XCTUnwrap(model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint)
        XCTAssertEqual(image.pixelsWide, 518); XCTAssertEqual(image.pixelsHigh, 392)
        XCTAssertNotNil(model.modelDescription.outputDescriptionsByName["depth"])
    }

    func testNormalOriginalImportRecomputesOldBlankDraftAndRefocuses() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ReferencePhoto", withExtension: "png"))
        let data = try Data(contentsOf: url)
        let pipeline = PhotoPipeline() // Real OfflineDepthEstimator, no injected map or predictor.
        let blank = try SceneLayerMap.blank(width: 770, height: 1024)
        let photo = try await pipeline.prepare(data: data, title: "normal imported PNG",
             cachedAnalysis: .layered(.init(map: blank, subjects: nil, notice: nil)),
             cachedImageSize: .init(width: 1060, height: 1410))
        guard case .estimated(let estimated) = photo.analysis else { return XCTFail("Automatic depth missing") }
        let depth = estimated.field
        XCTAssertEqual(depth.width, 518); XCTAssertEqual(depth.height, 392)
        XCTAssertTrue(depth.values.allSatisfy(\.isFinite))
        for p in AutomaticDepthTests.reportedPoints {
            let z = depth.sample(at: p)
            print("[CoreMLSmoke] original tap=\(p) depth=\(z)")
            XCTAssertTrue(z.isFinite)
        }
        let bottle = UnitPoint2D(x: 0.4845360824742268, y: 0.7854381443298968)
        let cabinet = UnitPoint2D(x: 0.8393470790378006, y: 0.5483247422680413)
        XCTAssertGreaterThan(depth.sample(at: bottle) - depth.sample(at: cabinet), 0.25,
                             "瓶子与柜子远近应分开；失败时检查预处理/坐标/模型输出")
        var nearRecipe = EditRecipe(); nearRecipe.focusPoint = bottle; nearRecipe.aperture = 1.4
        var farRecipe = nearRecipe; farRecipe.focusPoint = cabinet
        let nearMask = try FocusMaskBuilder.make(analysis: photo.analysis, recipe: nearRecipe, imageSize: photo.sourceSize)
        let farMask = try FocusMaskBuilder.make(analysis: photo.analysis, recipe: farRecipe, imageSize: photo.sourceSize)
        XCTAssertNotEqual(nearMask.blur, farMask.blur)
        for p in [bottle, UnitPoint2D(x: 0.15, y: 0.52), .init(x: 0.21, y: 0.90)] {
            XCTAssertLessThan(nearMask.blur.value(at: p), 24, "近焦时不应单独重度虚化同范围主体")
            XCTAssertGreaterThan(farMask.blur.value(at: p), 160, "远焦时近处主体应一起虚化")
        }
        XCTAssertGreaterThan(nearMask.blur.value(at: cabinet), 160)
        XCTAssertLessThan(farMask.blur.value(at: cabinet), 16)
        let a = try await pipeline.preview(photo: photo, recipe: nearRecipe)
        let b = try await pipeline.preview(photo: photo, recipe: farRecipe)
        XCTAssertNotEqual(try ImageSupport.jpegData(a.rendered), try ImageSupport.jpegData(b.rendered))
        let exported = try await pipeline.export(photo: photo, recipe: nearRecipe)
        XCTAssertEqual(max(exported.image.width, exported.image.height), 1410)
        XCTAssertFalse(exported.jpeg.isEmpty)
        let attachment = XCTAttachment(image: UIImage(cgImage: a.rendered))
        attachment.name = "Actual-CoreImage-near-focus"; attachment.lifetime = .keepAlways; add(attachment)
        let farAttachment = XCTAttachment(image: UIImage(cgImage: b.rendered))
        farAttachment.name = "Actual-CoreImage-far-focus"; farAttachment.lifetime = .keepAlways; add(farAttachment)
    }

    func testInputKeepsTopLeftRowsAndRaw255Values() throws {
        let bytes = [UInt8](repeating: 0, count: 32*16) + [UInt8](repeating: 255, count: 32*16)
        let original = try ImageSupport.grayImage(width: 32, height: 32, bytes: bytes)
        let estimator = OfflineDepthEstimator(context: CIContext())
        let input = try estimator.makeInput(original, width: 518, height: 392, format: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(input, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(input)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(input)
        XCTAssertLessThan(base[30*stride+200*4], 5, "Top row must not flip to bottom")
        XCTAssertGreaterThan(base[350*stride+200*4], 250, "No double 0...1 normalization")
    }

    func testHalfFloatDepthReaderKeepsFractionalValues() throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 3, 2, kCVPixelFormatType_OneComponent16Half,
             [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<2 { for x in 0..<3 {
            base.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self)[x] = Float16(Float(y*3+x)/8).bitPattern
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertEqual(try PixelBufferReader.floats(buffer).values, [0,0.125,0.25,0.375,0.5,0.625])
    }
}
