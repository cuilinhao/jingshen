import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class SubjectMaskTests: XCTestCase {
    private func sample() throws -> SubjectSegmentation {
        // Three rows of background / subject 7 / subject 2. IDs are labels, NOT distances.
        let labels = try GrayMask(width: 3, height: 3, bytes: Data([0,7,2, 0,7,2, 0,7,2]))
        let seven = try GrayMask(width: 3, height: 3, bytes: Data([0,255,0, 0,255,0, 0,255,0]))
        let two = try GrayMask(width: 3, height: 3, bytes: Data([0,0,255, 0,0,255, 0,0,255]))
        return try SubjectSegmentation(labels: labels, subjects: [SubjectMask(id: 7, mask: seven), SubjectMask(id: 2, mask: two)])
    }
    func testInvalidMaskDimensionsAndByteCountAreRejected() {
        XCTAssertThrowsError(try GrayMask(width: 0, height: 3, bytes: Data()))
        XCTAssertThrowsError(try GrayMask(width: 2, height: 2, bytes: Data([0])))
        XCTAssertThrowsError(try GrayMask(width: Int.max, height: Int.max, bytes: Data()))
    }
    func testMaskDecoderValidatesDimensions() throws {
        let corrupt = Data(#"{"width":2,"height":2,"bytes":"AA=="}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(GrayMask.self, from: corrupt))
    }
    func testHitTestKeepsTopLeftOriginAndClampsBorders() throws {
        let s = try sample()
        XCTAssertEqual(s.instance(at: UnitPoint2D(x: 0, y: 0)), 0)
        XCTAssertEqual(s.instance(at: .center), 7)
        XCTAssertEqual(s.instance(at: UnitPoint2D(x: 1, y: 1)), 2)
        XCTAssertEqual(s.instance(at: UnitPoint2D(x: 4, y: 1)), 2)
    }
    func testCoverageSelectionDoesNotAssumeLabelOrderingIsDepth() throws {
        let s = try sample()
        XCTAssertEqual(s.subject(at: .center)?.id, 7)
        XCTAssertEqual(s.subject(at: .init(x:1,y:0.5))?.id, 2)
    }
    func testBackgroundDoesNotReturnAnInverseSelection() throws {
        XCTAssertNil(try sample().subject(at: .init(x:0,y:0.5)))
    }
    func testUnknownOrDuplicateSubjectIDsAreRejected() throws {
        let s = try sample()
        XCTAssertThrowsError(try SubjectSegmentation(labels: s.labels, subjects: [s.subjects[0]]))
        XCTAssertThrowsError(try SubjectSegmentation(labels: s.labels, subjects: [s.subjects[0],s.subjects[0],s.subjects[1]]))
        XCTAssertThrowsError(try SubjectSegmentation(labels: s.labels, subjects: []))
    }
    func testSoftMaskValuesAreRetained() throws {
        let labels = try GrayMask(width: 3, height: 1, bytes: Data([0,4,4]))
        let mask = try GrayMask(width: 3, height: 1, bytes: Data([0,96,255]))
        let s = try SubjectSegmentation(labels: labels, subjects: [SubjectMask(id: 4, mask: mask)])
        XCTAssertEqual(Array(s.subjects[0].mask.bytes), [0,96,255])
        XCTAssertNil(s.subject(at: .center)) // Coverage below 0.5 is not a confident hit.
        XCTAssertEqual(s.subject(at: .init(x:1,y:0))?.id,4)
    }
    func testLocalFallbackIsCircularInImagePixelsNotStretched() throws {
        let m = try LocalFocusMask.make(width: 201, height: 101, imageSize: PixelSize(width: 200, height: 100),
                                        center: .center, radius: 0.20)
        // x+0.10 and y+0.20 both equal 20 image pixels from the center.
        XCTAssertEqual(m.value(at: UnitPoint2D(x: 0.60, y: 0.50)),
                       m.value(at: UnitPoint2D(x: 0.50, y: 0.70)))
        XCTAssertEqual(m.value(at: .center), 0)
        XCTAssertEqual(m.value(at: UnitPoint2D(x: 1, y: 1)), 255)
    }
    func testBiggerLocalRadiusPreservesMoreArea() throws {
        let p = UnitPoint2D(x: 0.68, y: 0.5)
        let small = try LocalFocusMask.make(width: 101, height: 101, imageSize: PixelSize(width: 100, height: 100), center: .center, radius: 0.12)
        let large = try LocalFocusMask.make(width: 101, height: 101, imageSize: PixelSize(width: 100, height: 100), center: .center, radius: 0.30)
        XCTAssertGreaterThan(small.value(at: p), large.value(at: p))
    }
    func testSubjectMaskBuilderDoesNotConvertLabelsIntoDepth() throws {
        let s = try sample()
        var r = EditRecipe(); r.focusPoint = .center
        let output = try FocusMaskBuilder.make(analysis: .subjects(s), recipe: r, imageSize: PixelSize(width: 300, height: 300))
        XCTAssertEqual(Array(output.blur.bytes), [0,0,0, 0,0,0, 0,0,0])
        XCTAssertNil(output.nearDefocus)
        r.focusPoint = UnitPoint2D(x: 0, y: 0.5)
        let background = try FocusMaskBuilder.make(analysis: .subjects(s), recipe: r, imageSize: PixelSize(width: 300, height: 300))
        XCTAssertNil(background.nearDefocus)
        XCTAssertEqual(Array(background.blur.bytes), [0,0,0, 0,0,0, 0,0,0])
    }
    func testApertureDoesNotChangeSelectionMask() throws {
        let s = try sample(); var recipe = EditRecipe()
        recipe.focusPoint = .center; recipe.aperture = 1.4
        let a = try FocusMaskBuilder.make(analysis: .subjects(s), recipe: recipe, imageSize: PixelSize(width: 100, height: 100))
        recipe.aperture = 16
        let b = try FocusMaskBuilder.make(analysis: .subjects(s), recipe: recipe, imageSize: PixelSize(width: 100, height: 100))
        XCTAssertEqual(a, b)
    }
    func testExplicitLocalModeOverridesDetectedSubjects() throws {
        let s = try sample(); var r = EditRecipe(); r.focusMode = .local; r.focusPoint = .center
        let m = try FocusMaskBuilder.make(analysis: .subjects(s), recipe: r, imageSize: PixelSize(width: 300, height: 300))
        XCTAssertEqual(m.blur.value(at: .center), 0)
        XCTAssertNil(m.nearDefocus)
    }
    func testTypedAnalysisRoundTripsWithoutInventingDepth() throws {
        let s = try sample()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        for analysis: PhotoAnalysis in [.subjects(s), .localFallback(reason: "无主体"),
                                       .native(try DepthField(width: 2, height: 2, values: [0,1,0,1]))] {
            let data = try encoder.encode(analysis)
            XCTAssertEqual(try PropertyListDecoder().decode(PhotoAnalysis.self, from: data), analysis)
        }
    }
    func testLegacyRecipeRetainsEditsAndAddsNewDefaults() throws {
        let legacy = Data(#"{"schemaVersion":1,"focusPoint":{"x":0.1,"y":0.2},"aperture":4,"depthEnabled":false,"effectStrength":1.2,"focusTolerance":0.07,"exposure":0.5,"crop":"square","style":"warm"}"#.utf8)
        let r = try JSONDecoder().decode(EditRecipe.self, from: legacy)
        XCTAssertEqual(r.schemaVersion, 4)
        XCTAssertEqual(r.focusMode, .automatic)
        XCTAssertEqual(r.focusPoint, UnitPoint2D(x:0.1,y:0.2))
        XCTAssertEqual(r.aperture,4); XCTAssertEqual(r.crop,.square); XCTAssertFalse(r.depthEnabled)
    }
    func testRecipeSanitizesNewValues() {
        var r = EditRecipe(); r.localRadius = .nan; r.edgeFeather = .infinity; r.sanitize()
        XCTAssertTrue(r.localRadius.isFinite); XCTAssertTrue(r.edgeFeather.isFinite)
        r.localRadius = -100; r.edgeFeather = 100; r.sanitize()
        XCTAssertEqual(r.localRadius, 0.08); XCTAssertEqual(r.edgeFeather, 6)
    }
    func testFutureRecipeVersionIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"schemaVersion":9000}"#.utf8)))
    }
}
