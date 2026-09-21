import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class ReferenceSceneTests: XCTestCase {
    private func fixture() throws -> ReferenceLayerFixture {
        #if canImport(DepthCore)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Tests/Fixtures/ReferenceLayers.json")
        #else
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ReferenceLayers", withExtension: "json"))
        #endif
        return try JSONDecoder().decode(ReferenceLayerFixture.self,from: Data(contentsOf: url))
    }
    func testFixtureIsDeclaredHumanAnnotatedNotAutomatic() throws {
        let f = try fixture()
        XCTAssertTrue(f.description.contains("人工")); XCTAssertEqual(f.imageSize,.init(width:1060,height:1410))
        XCTAssertEqual(try f.makeMap().provenance,.reference)
    }
    func testBottleMonitorToyAndTableShareNearLayer() throws {
        let map = try fixture().makeMap()
        for p in [UnitPoint2D(x:0.16,y:0.45),.init(x:0.47,y:0.77),.init(x:0.2,y:0.9),.init(x:0.1,y:0.84)] {
            XCTAssertEqual(map.layer(at: p),.near,"Incorrect reference near point: \(p)")
        }
        XCTAssertEqual(map.layer(at: .init(x:0.463,y:0.64)),.near,"Transparent bottle spray trigger")
    }
    func testCabinetCheckerboardAndFloorAreFarLayer() throws {
        let map = try fixture().makeMap()
        for p in [UnitPoint2D(x:0.79,y:0.58),.init(x:0.675,y:0.486),.init(x:0.82,y:0.85)] {
            XCTAssertEqual(map.layer(at: p),.far)
        }
    }
    func testNearFocusMatchesRequestedGrouping() throws {
        let map = try fixture().makeMap()
        let masks = try map.focusMasks(at: .init(x:0.47,y:0.77),tolerance:0.035)
        for p in [UnitPoint2D(x:0.16,y:0.45),.init(x:0.47,y:0.77),.init(x:0.2,y:0.9)] {
            XCTAssertEqual(masks.blur.value(at:p),0)
        }
        XCTAssertEqual(masks.blur.value(at: .init(x:0.79,y:0.58)),255)
    }
    func testFarFocusBlursAllNearObjectsNotJustDisplay() throws {
        let map = try fixture().makeMap()
        let masks = try map.focusMasks(at: .init(x:0.79,y:0.58),tolerance:0.035)
        for p in [UnitPoint2D(x:0.16,y:0.45),.init(x:0.47,y:0.77),.init(x:0.2,y:0.9)] {
            XCTAssertEqual(masks.blur.value(at:p),255)
        }
        XCTAssertEqual(masks.blur.value(at: .init(x:0.79,y:0.58)),0)
    }
    func testReferenceMasksRemainSameInPreviewAndExportCoordinates() throws {
        let f = try fixture(), a = try f.makeMap(longestEdge:512), b = try f.makeMap(longestEdge:1024)
        for p in [UnitPoint2D(x:0.16,y:0.45),.init(x:0.47,y:0.77),.init(x:0.2,y:0.9),.init(x:0.79,y:0.58)] {
            XCTAssertEqual(a.layer(at:p),b.layer(at:p))
        }
    }
    func testNativeAndLayeredMasksUseDifferentExplicitSources() throws {
        let map = try fixture().makeMap(longestEdge:128)
        var r = EditRecipe();r.focusPoint = .init(x:0.47,y:0.77)
        let result = try FocusMaskBuilder.make(analysis:.layered(.init(map:map,subjects:nil,notice:nil)),recipe:r,imageSize:.init(width:1060,height:1410))
        XCTAssertEqual(result.blur.value(at:.init(x:0.16,y:0.45)),0)
        XCTAssertEqual(result.blur.value(at:.init(x:0.79,y:0.58)),255)
    }
}
