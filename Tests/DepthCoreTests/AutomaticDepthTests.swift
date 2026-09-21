import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class AutomaticDepthTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let size = PixelSize(width: 1060, height: 1410)
    private func field() throws -> DepthField {
        // Four separated patches: monitor .68, cabinet .25, bottle .85, toy .97.
        var values = [Float](repeating: 0.25, count: 40 * 20)
        for y in 0..<20 { for x in 0..<40 {
            if x < 10 { values[y*40+x] = 0.68 }
            if (20..<30).contains(x) { values[y*40+x] = 0.85 }
            if x >= 30 { values[y*40+x] = 0.97 }
        } }
        return try DepthField(width: 40, height: 20, values: values)
    }
    private func inferred() throws -> InferredDepth {
        InferredDepth(field: try field(), sourceSHA256: digest, imageSize: size)
    }
    func testValidInferenceCacheCanBeReused() throws {
        let d = try inferred()
        XCTAssertTrue(d.matches(sourceSHA256: digest, imageSize: size))
        XCTAssertEqual(AutomaticDepthCache.reusable(.estimated(d), sourceSHA256: digest, imageSize: size), d)
    }
    func testDifferentPhotoSameDimensionsMustNotReuseDepth() throws {
        XCTAssertFalse(try inferred().matches(sourceSHA256: String(repeating: "b", count: 64), imageSize: size))
    }
    func testDifferentDimensionsAndModelRevisionInvalidateCache() throws {
        var d = try inferred()
        XCTAssertFalse(d.matches(sourceSHA256: digest, imageSize: PixelSize(width: 1060, height: 1400)))
        d.modelID = "old-model"
        XCTAssertFalse(d.matches(sourceSHA256: digest, imageSize: size))
        d.modelID = InferredDepth.currentModelID; d.preprocessingID = "old-letterbox"
        XCTAssertFalse(d.matches(sourceSHA256: digest, imageSize: size))
    }
    func testV3BlankLayerCacheNeverSkipsInference() throws {
        let scene = LayeredScene(map: try .blank(width: 40, height: 20), subjects: nil, notice: nil)
        XCTAssertNil(AutomaticDepthCache.reusable(.layered(scene), sourceSHA256: digest, imageSize: size))
        XCTAssertNil(AutomaticDepthCache.reusable(.localFallback(reason: "old"), sourceSHA256: digest, imageSize: size))
        XCTAssertNil(AutomaticDepthCache.reusable(nil, sourceSHA256: digest, imageSize: size))
    }
    func testSyntheticDepthRangeKeepsSeparatedNearObjectsSharp() throws {
        var r = EditRecipe(); r.focusPoint = .init(x: 0.63, y: 0.5); r.focusTolerance = 0.22
        let masks = try FocusMaskBuilder.make(analysis: .estimated(inferred()), recipe: r, imageSize: size)
        XCTAssertEqual(masks.blur.value(at: .init(x: 0.1, y: 0.5)), 0, "monitor in same focus range")
        XCTAssertEqual(masks.blur.value(at: .init(x: 0.9, y: 0.5)), 0, "toy in same focus range")
        XCTAssertGreaterThan(masks.blur.value(at: .init(x: 0.38, y: 0.5)), 200, "far cabinet blurs")
        XCTAssertEqual(masks.protection?.value(at: .init(x: 0.1, y: 0.5)), 255)
    }
    func testSelectingFarDepthChangesMaskAndBlursAllNearObjects() throws {
        var r = EditRecipe(); r.focusPoint = .init(x: 0.38, y: 0.5)
        let masks = try FocusMaskBuilder.make(analysis: .estimated(inferred()), recipe: r, imageSize: size)
        XCTAssertEqual(masks.blur.value(at: r.focusPoint), 0)
        for x in [0.1, 0.63, 0.9] {
            XCTAssertGreaterThan(masks.blur.value(at: .init(x: x, y: 0.5)), 180)
        }
        XCTAssertNotNil(masks.nearDefocus)
    }
    func testAllPreviousEightTapCoordinatesHaveFiniteDepth() throws {
        let depth = try field()
        for p in Self.reportedPoints {
            XCTAssertTrue(depth.sample(at: p).isFinite)
        }
    }
    func testConstantInferredCacheDoesNotPretendToHaveDepth() throws {
        let flat = try DepthField(width: 4, height: 4, values: [Float](repeating: 0.5, count: 16))
        let cache = InferredDepth(field: flat, sourceSHA256: digest, imageSize: size)
        XCTAssertNil(AutomaticDepthCache.reusable(.estimated(cache), sourceSHA256: digest, imageSize: size))
    }
    func testTypedEstimatedDepthRoundTrip() throws {
        let d = PhotoAnalysis.estimated(try inferred())
        let e = PropertyListEncoder(); e.outputFormat = .binary
        XCTAssertEqual(try PropertyListDecoder().decode(PhotoAnalysis.self, from: e.encode(d)), d)
        XCTAssertFalse(d.isNative); XCTAssertNotNil(d.continuousDepth)
    }
    func testV3RecipeMigratesFocusRangeButRetainsPhotoEdits() throws {
        let old = Data(#"{"schemaVersion":3,"focusTolerance":0.035,"aperture":2.1,"focusMode":"automatic","focusPoint":{"x":0.48,"y":0.85},"crop":"square"}"#.utf8)
        let r = try JSONDecoder().decode(EditRecipe.self, from: old)
        XCTAssertEqual(r.schemaVersion, 4); XCTAssertEqual(r.focusTolerance, 0.22)
        XCTAssertEqual(r.aperture, 2.1); XCTAssertEqual(r.crop, .square)
        XCTAssertEqual(r.focusPoint, .init(x: 0.48, y: 0.85))
    }
    func testV4RecipeRetainsExplicitNarrowRange() throws {
        var r = EditRecipe(); r.focusTolerance = 0.04
        let restored = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(restored.focusTolerance, 0.04)
    }
    static let reportedPoints = [
        UnitPoint2D(x: 0.8393470790378006, y: 0.5483247422680413),
        .init(x: 0.7250859106529209, y: 0.5393041237113402),
        .init(x: 0.47079037800687284, y: 0.8537371134020618),
        .init(x: 0.49140893470790376, y: 0.7712628865979381),
        .init(x: 0.4845360824742268, y: 0.7854381443298968),
        .init(x: 0.7414089347079037, y: 0.5747422680412371),
        .init(x: 0.4845360824742268, y: 0.8698453608247421),
        .init(x: 0.49742268041237114, y: 0.8524484536082474)
    ]
}
