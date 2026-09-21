import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class ModelGeometryTests: XCTestCase {
    func testLetterboxRestoresPortraitAndLandscapeWithoutPaddingPixels() throws {
        let portrait = DepthInputGeometry(imageSize:.init(width:100,height:200),width:504,height:504)
        XCTAssertEqual(portrait.contentWidth,252); XCTAssertEqual(portrait.contentHeight,504)
        XCTAssertEqual(portrait.left,126); XCTAssertEqual(portrait.top,0)
        let landscape = DepthInputGeometry(imageSize:.init(width:200,height:100),width:504,height:504)
        XCTAssertEqual(landscape.top,126); XCTAssertEqual(landscape.contentHeight,252)
        var values = [Float](repeating:999,count:504*504)
        for y in 126..<378 { for x in 0..<504 { values[y*504+x] = Float(y-125) } }
        let crop = try landscape.unpad(values)
        XCTAssertEqual(crop.count,504*252)
        XCTAssertEqual(crop.first,1); XCTAssertEqual(crop.last,252)
        XCTAssertFalse(crop.contains(999))
    }
    func testV3InverseDepthIsNearBrightAndRejectsNonpositive() throws {
        let d = try DepthModelChoice.v3.normalize(width:3,height:1,values:[1,2,4])
        XCTAssertEqual(d.values[0],1); XCTAssertEqual(d.values[2],0)
        XCTAssertGreaterThan(d.values[1],0)
        XCTAssertThrowsError(try DepthModelChoice.v3.normalize(width:3,height:1,values:[1,0,4]))
    }
    func testV2CacheCannotBeUsedWhenV3Selected() throws {
        let d = try DepthField(width:2,height:2,values:[0,1,0,1])
        let cached = InferredDepth(field:d,sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:100,height:200),modelChoice:.v2)
        XCTAssertFalse(cached.matches(sourceSHA256:cached.sourceSHA256,imageSize:cached.imageSize))
        XCTAssertTrue(cached.matches(sourceSHA256:cached.sourceSHA256,imageSize:cached.imageSize,modelChoice:.v2))
    }
}
