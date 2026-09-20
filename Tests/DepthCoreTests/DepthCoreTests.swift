import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class DepthCoreTests: XCTestCase {
    func testApertureLimitsAndRoundTrip() {
        XCTAssertEqual(Aperture.clamp(-10), 1.4)
        XCTAssertEqual(Aperture.clamp(99), 16)
        XCTAssertEqual(Aperture.clamp(.nan), 2)
        for value in [1.4, 1.8, 2, 2.8, 4, 5.6, 8, 10, 14, 16] {
            XCTAssertEqual(Aperture.value(at: Aperture.position(of: value)), value, accuracy: 0.00001)
        }
    }
    func testBlurDecreasesAsFNumberIncreases() {
        XCTAssertGreaterThan(Aperture.strength(1.4), Aperture.strength(2))
        XCTAssertGreaterThan(Aperture.strength(2), Aperture.strength(14))
        XCTAssertEqual(Aperture.strength(16), 0, accuracy: 0.00001)
    }
    func testInvalidDimensionsAreRejected() {
        XCTAssertThrowsError(try DepthField(width: 2, height: 2, values: [0, 1]))
        XCTAssertThrowsError(try DepthField(width: 0, height: 3, values: []))
        XCTAssertThrowsError(try DepthField(width: Int.max, height: Int.max, values: []))
    }
    func testDepthNormalizationRejectsInvalidData() throws {
        XCTAssertThrowsError(try DepthField.normalizing(width: 2, height: 2, values: [.nan, .infinity, -.infinity, .nan]))
        let depth = try DepthField.normalizing(width: 2, height: 2, values: [10, 20, 30, .nan])
        XCTAssertTrue(depth.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }
    func testConstantDepthDoesNotInventAnArtificialGradient() throws {
        let field = try DepthField.normalizing(width: 3, height: 2, values: Array(repeating: 42, count: 6))
        XCTAssertEqual(Set(field.values).count, 1)
        XCTAssertEqual(field.sample(at: .center), 0.5, accuracy: 0.001)
    }
    func testFocusSamplesNeighborhoodMedianRatherThanSingleOutlier() throws {
        var data = Array(repeating: Float(0.3), count: 25)
        data[12] = 1
        let depth = try DepthField(width: 5, height: 5, values: data)
        XCTAssertEqual(depth.sample(at: .center, radius: 1), 0.3, accuracy: 0.001)
    }
    func testDepthRowsAndCornersHaveTopLeftOrigin() throws {
        let field = try DepthField(width: 2, height: 2, values: [0, 0.25, 0.75, 1])
        XCTAssertEqual(field.sample(at: UnitPoint2D(x: 0, y: 0), radius: 0), 0)
        XCTAssertEqual(field.sample(at: UnitPoint2D(x: 1, y: 0), radius: 0), 0.25)
        XCTAssertEqual(field.sample(at: UnitPoint2D(x: 0, y: 1), radius: 0), 0.75)
        XCTAssertEqual(field.sample(at: UnitPoint2D(x: 1, y: 1), radius: 0), 1)
    }
    func testTapOutsideAspectFitImageIsIgnored() {
        let rect = ImageGeometry.aspectFit(imageWidth: 400, imageHeight: 200, boxWidth: 400, boxHeight: 600)
        XCTAssertNil(ImageGeometry.unitPoint(x: 100, y: 10, inside: rect))
        XCTAssertEqual(ImageGeometry.unitPoint(x: 200, y: 300, inside: rect), .center)
    }
    func testSquareCropMapsBackToOriginalDepth() {
        let crop = CropRatio.square.unitRect(imageWidth: 400, imageHeight: 800)
        XCTAssertEqual(crop.x, 0)
        XCTAssertEqual(crop.y, 0.25)
        XCTAssertEqual(crop.height, 0.5)
        XCTAssertEqual(crop.originalPoint(from: .center), .center)
        XCTAssertEqual(crop.originalPoint(from: UnitPoint2D(x: 0, y: 0)), UnitPoint2D(x: 0, y: 0.25))
        XCTAssertEqual(crop.localPoint(from: UnitPoint2D(x: 1, y: 0.75)), UnitPoint2D(x: 1, y: 1))
        XCTAssertNil(crop.localPoint(from: UnitPoint2D(x: 0.5, y: 0.1)))
    }
    func testSameDepthHasSameBlurRegardlessOfSpatialDistance() {
        let a = DepthMath.blurAmount(depth: 0.5, focus: 0.5, tolerance: 0.035)
        let b = DepthMath.blurAmount(depth: 0.9, focus: 0.5, tolerance: 0.035)
        XCTAssertEqual(a, 0)
        XCTAssertGreaterThan(b, a)
        XCTAssertEqual(DepthMath.blurAmount(depth: 0.1, focus: 0.5, tolerance: 0.035), b, accuracy: 0.001)
    }
    func testExportSizingNeverUpscales() {
        XCTAssertEqual(ImageGeometry.outputSize(width: 1600, height: 1200, longestEdge: 2048), PixelSize(width: 1600, height: 1200))
        XCTAssertEqual(ImageGeometry.outputSize(width: 4032, height: 3024, longestEdge: 2048), PixelSize(width: 2048, height: 1536))
    }
    func testRecipeRoundTripAndSanitization() throws {
        var recipe = EditRecipe()
        recipe.aperture = 1.8
        recipe.focusPoint = UnitPoint2D(x: 0.3, y: 0.7)
        recipe.crop = .square
        let encoded = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: encoded), recipe)
        recipe.aperture = -4
        recipe.effectStrength = 99
        recipe.focusPoint = UnitPoint2D(x: 3, y: -3)
        recipe.sanitize()
        XCTAssertEqual(recipe.aperture, 1.4)
        XCTAssertEqual(recipe.effectStrength, 1.5)
        XCTAssertEqual(recipe.focusPoint, UnitPoint2D(x: 1, y: 0))
    }
}
