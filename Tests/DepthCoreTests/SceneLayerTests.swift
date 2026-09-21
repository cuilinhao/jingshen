import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class SceneLayerTests: XCTestCase {
    private func map(_ values: [UInt8], width: Int? = nil) throws -> SceneLayerMap {
        let w = width ?? values.count
        return try SceneLayerMap(labels: GrayMask(width: w, height: values.count / w, bytes: Data(values)), provenance: .user)
    }
    func testAllObjectsOnTheSelectedLayerStaySharp() throws {
        // monitor, bottle, cabinet, toy: monitor/bottle/toy share one layer, NOT one object.
        let m = try map([3,3,1,3])
        let output = try m.focusMasks(at: .init(x: 1.0/3, y: 0), tolerance: 0.035)
        XCTAssertEqual(Array(output.blur.bytes), [0,0,255,0])
        XCTAssertEqual(Array(output.protection!.bytes), [255,255,0,255])
        XCTAssertNil(output.nearDefocus)
        XCTAssertEqual(output, try m.focusMasks(at: .init(x: 0, y: 0), tolerance: 0.035))
        XCTAssertEqual(output, try m.focusMasks(at: .init(x: 1, y: 0), tolerance: 0.035))
    }
    func testFarFocusBlursAllNearObjectsTogether() throws {
        let output = try map([3,3,1,3]).focusMasks(at: .init(x: 2.0/3, y: 0), tolerance: 0.035)
        XCTAssertEqual(Array(output.blur.bytes), [255,255,0,255])
        XCTAssertEqual(output.nearDefocus?.bytes, output.blur.bytes)
    }
    func testUnknownPixelsAreNotFarAndAreProtected() throws {
        let m = try map([3,0,1,3])
        XCTAssertEqual(m.layer(at: .init(x: 1.0/3,y: 0)), .unknown)
        let unknown = try m.focusMasks(at: .init(x: 1.0/3,y: 0), tolerance: 0.035)
        XCTAssertEqual(Array(unknown.blur.bytes), [0,0,0,0])
        XCTAssertNil(unknown.nearDefocus)
        let far = try m.focusMasks(at: .init(x: 2.0/3,y: 0), tolerance: 0.035)
        XCTAssertEqual(Array(far.blur.bytes), [255,0,0,255])
        XCTAssertEqual(far.protection!.bytes[1], 255)
    }
    func testMiddleFocusDoesNotBecomeBackgroundInverse() throws {
        let m = try map([3,2,1,2])
        let result = try m.focusMasks(at: .init(x: 1.0/3,y: 0), tolerance: 0.035)
        XCTAssertEqual(Array(result.blur.bytes), [255,0,255,0])
        XCTAssertEqual(Array(result.nearDefocus!.bytes), [255,0,0,0])
    }
    func testVisionIDsDoNotOrderOrAssignDepth() throws {
        let m = try SceneLayerMap.blank(width: 4, height: 1)
        XCTAssertEqual(m.knownLayers, [])
        XCTAssertEqual(m.assignedFraction, 0)
        let mask = try GrayMask(width: 4, height: 1, bytes: Data([255,0,0,255]))
        let changed = try m.assigning(mask: mask, to: .near)
        XCTAssertEqual(Array(changed.labels.bytes), [3,0,0,3])
        XCTAssertEqual(changed.knownLayers, [.near])
        XCTAssertEqual(changed.provenance, .user)
    }
    func testAssigningMaskUsesTopLeftNormalizedCoordinatesAtDifferentResolution() throws {
        let m = try SceneLayerMap.blank(width: 4, height: 4)
        let mask = try GrayMask(width: 2, height: 2, bytes: Data([255,0,0,0]))
        let result = try m.assigning(mask: mask, to: .middle)
        XCTAssertEqual(result.layer(at: .init(x:0,y:0)), .middle)
        XCTAssertEqual(result.layer(at: .init(x:1,y:0)), .unknown)
        XCTAssertEqual(result.layer(at: .init(x:0,y:1)), .unknown)
    }
    func testInvalidLayerValuesAreRejectedRatherThanUsedAsDistances() throws {
        XCTAssertThrowsError(try map([0,1,7,3]))
        let corrupt = Data(#"{"labels":{"width":1,"height":1,"bytes":"/w=="},"provenance":"user"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SceneLayerMap.self, from: corrupt))
    }
    func testPolygonMarksMissedTransparentObjectWithoutVision() throws {
        let m = try SceneLayerMap.blank(width: 21, height: 21)
        let p = [UnitPoint2D(x:0.3,y:0.3), .init(x:0.7,y:0.3), .init(x:0.7,y:0.9), .init(x:0.3,y:0.9)]
        let result = try m.filling(polygon: p, with: .near)
        XCTAssertEqual(result.layer(at: .center), .near)
        XCTAssertEqual(result.layer(at: .init(x:0.1,y:0.5)), .unknown)
        XCTAssertEqual(result.layer(at: .init(x:0.5,y:0.1)), .unknown)
        XCTAssertThrowsError(try m.filling(polygon: [.center], with: .near))
    }
    func testBrushInterpolatesFullStrokeAndCanEraseToUnknown() throws {
        let m = try SceneLayerMap.blank(width: 101, height: 101)
        let points = [UnitPoint2D(x:0.1,y:0.5), .init(x:0.9,y:0.5)]
        let painted = try m.painting(points: points, radius: 0.03, layer: .near)
        for x in [0.1,0.2,0.5,0.8,0.9] { XCTAssertEqual(painted.layer(at: .init(x:x,y:0.5)), .near) }
        XCTAssertEqual(painted.layer(at: .init(x:0.5,y:0.6)), .unknown)
        let erased = try painted.painting(points: [.center], radius: 0.05, layer: .unknown)
        XCTAssertEqual(erased.layer(at: .center), .unknown)
        XCTAssertEqual(erased.layer(at: .init(x:0.1,y:0.5)), .near)
    }
    func testBrushRadiusUsesShortEdgeInsteadOfDistortingPortrait() throws {
        let m = try SceneLayerMap.blank(width: 101, height: 201)
        let result = try m.painting(points: [.center], radius: 0.1, layer: .near)
        XCTAssertEqual(result.layer(at: .init(x:0.59,y:0.5)), .near)
        XCTAssertEqual(result.layer(at: .init(x:0.5,y:0.545)), .near)
        XCTAssertEqual(result.layer(at: .init(x:0.5,y:0.57)), .unknown)
    }
    func testExplicitFillUnknownDoesNotOverwriteAlreadyAssignedSubjects() throws {
        let result = try map([3,0,2,0]).fillingUnknown(with: .far)
        XCTAssertEqual(Array(result.labels.bytes), [3,1,2,1])
    }
    func testUndoRedoAndNewBranchAreBoundedAndDeterministic() throws {
        let a = try map([0,0]), b = try map([3,0]), c = try map([3,1])
        var history = LayerEditingHistory(initial: a, limit: 2)
        history.apply(b); history.apply(c)
        XCTAssertEqual(history.current,c)
        history.undo(); XCTAssertEqual(history.current,b)
        history.undo(); XCTAssertEqual(history.current,a)
        history.redo(); XCTAssertEqual(history.current,b)
        history.apply(a); XCTAssertFalse(history.canRedo)
        history.undo(); XCTAssertEqual(history.current,b)
    }
    func testReassignmentChangesLayerOfAllFutureFocusMasks() throws {
        let m = try map([3,3,1])
        let mask = try GrayMask(width: 3,height: 1,bytes: Data([255,0,0]))
        let updated = try m.assigning(mask: mask, to: .far)
        let result = try updated.focusMasks(at: .center, tolerance: 0.035)
        XCTAssertEqual(Array(result.blur.bytes), [255,0,255])
    }
    func testSceneRoundTripRetainsUnknownAndProvenance() throws {
        let scene = LayeredScene(map: try map([0,3,1,3]), subjects: nil, notice: "test")
        let analysis = PhotoAnalysis.layered(scene)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let restored = try PropertyListDecoder().decode(PhotoAnalysis.self, from: encoder.encode(analysis))
        XCTAssertEqual(analysis,restored)
    }
    func testCropInverseMapsFocusToSameSceneLayer() throws {
        let m = try map([1,3,3,1])
        let crop = CropRatio.square.unitRect(imageWidth: 400, imageHeight: 100)
        XCTAssertEqual(m.layer(at: crop.originalPoint(from: .center)), .near)
        let original = UnitPoint2D(x:0.6,y:0.5)
        XCTAssertEqual(m.layer(at: crop.originalPoint(from: crop.localPoint(from: original)!)), m.layer(at: original))
    }
    func testEveryPixelOnFocusedLayerHasZeroBlurForAllLayerChoices() throws {
        // Deterministic generated coverage includes disconnected components and unknown pixels.
        var values: [UInt8] = []
        for index in 0..<1024 {
            let mixed: Int = index * 13 + index / 17
            values.append(UInt8((mixed % 19) % 4))
        }
        let m = try map(values,width:32)
        for layer in [SceneLayer.near,.middle,.far] {
            let point = try XCTUnwrap(m.firstPoint(in:layer))
            let masks = try m.focusMasks(at:point,tolerance:0.035)
            for (index,byte) in values.enumerated() {
                if byte == layer.rawValue || byte == 0 {
                    XCTAssertEqual(masks.blur.bytes[index],0)
                    XCTAssertEqual(masks.protection?.bytes[index],255)
                } else { XCTAssertGreaterThan(masks.blur.bytes[index],0) }
            }
        }
    }

}
