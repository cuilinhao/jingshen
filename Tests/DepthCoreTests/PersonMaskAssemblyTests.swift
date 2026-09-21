import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class PersonMaskAssemblyTests: XCTestCase {
    func testComponentKeepsLocalSoftPersonWithoutDistantStrongerIsland() throws {
        let mask = try GrayMask(width: 7, height: 2, bytes: Data([
            0,180,64,0,0,255,255,
            0,32,31,0,0,255,255
        ]))
        let result = try XCTUnwrap(PersonMaskAssembly.component(in: mask, near: .init(x: 1.0/6, y: 0), searchRadius: 1))
        XCTAssertEqual(Array(result.bytes), [0,180,64,0,0,0,0, 0,32,0,0,0,0,0])
    }

    func testComponentSeedPrefersHighestCoverageThenNearestPoint() throws {
        let tied = try GrayMask(width: 7, height: 1, bytes: Data([0,200,0,0,0,200,0]))
        let closest = try XCTUnwrap(PersonMaskAssembly.component(in: tied, near: .init(x: 4.0/6, y: 0), searchRadius: Int.max))
        XCTAssertEqual(Array(closest.bytes), [0,0,0,0,0,200,0])
        let stronger = try GrayMask(width: 7, height: 1, bytes: Data([0,220,0,0,0,200,0]))
        let maximum = try XCTUnwrap(PersonMaskAssembly.component(in: stronger, near: .init(x: 4.0/6, y: 0), searchRadius: Int.max))
        XCTAssertEqual(Array(maximum.bytes), [0,220,0,0,0,0,0])
    }

    func testComponentDoesNotConnectAcrossRowBoundaryOrDiagonally() throws {
        let mask = try GrayMask(width: 3, height: 3, bytes: Data([0,0,255, 255,0,0, 0,64,0]))
        let result = try XCTUnwrap(PersonMaskAssembly.component(in: mask, near: .init(x: 1, y: 0), searchRadius: 0))
        XCTAssertEqual(Array(result.bytes), [0,0,255, 0,0,0, 0,0,0])
        let left = try XCTUnwrap(PersonMaskAssembly.component(in: mask, near: .init(x: 0, y: 0.5), searchRadius: -1))
        XCTAssertEqual(Array(left.bytes), [0,0,0, 255,0,0, 0,0,0])
    }

    func testComponentWithoutReliableSeedReturnsNilAndClampsPoint() throws {
        let mask = try GrayMask(width: 3, height: 1, bytes: Data([127,32,128]))
        XCTAssertNil(try PersonMaskAssembly.component(in: mask, near: .init(x: 0, y: 0), searchRadius: 1))
        let result = try XCTUnwrap(PersonMaskAssembly.component(in: mask, near: .init(x: 9, y: -8), searchRadius: Int.min))
        XCTAssertEqual(Array(result.bytes), [127,32,128], "连通区域可保留低于种子门槛的软边")
    }

    func testProjectionPreservesTopLeftCoordinatesAndZeroOutsideROI() throws {
        let source = try GrayMask(width: 2, height: 2, bytes: Data([255, 0, 64, 128]))
        let result = try PersonMaskAssembly.project(source, left: 1, top: 2, width: 2, height: 2,
                                                     imageSize: .init(width: 5, height: 6))
        var expected = [UInt8](repeating: 0, count: 30)
        expected[11] = 255; expected[12] = 0; expected[16] = 64; expected[17] = 128
        XCTAssertEqual(Array(result.bytes), expected)
    }

    func testProjectionUsesBilinearPixelCentersAndClampsSourceEdges() throws {
        let source = try GrayMask(width: 2, height: 2, bytes: Data([0, 100, 100, 200]))
        let result = try PersonMaskAssembly.project(source, left: 0, top: 0, width: 4, height: 4,
                                                     imageSize: .init(width: 4, height: 4))
        XCTAssertEqual(Array(result.bytes), [0,25,75,100, 25,50,100,125, 75,100,150,175, 100,125,175,200])
        let reduced = try PersonMaskAssembly.project(source, left: 0, top: 0, width: 1, height: 1,
                                                      imageSize: .init(width: 1, height: 1))
        XCTAssertEqual(Array(reduced.bytes), [100])
        let single = try GrayMask(width: 1, height: 1, bytes: Data([131]))
        XCTAssertEqual(Array(try PersonMaskAssembly.project(single, left: 0, top: 0, width: 3, height: 2,
                                                            imageSize: .init(width: 3, height: 2)).bytes),
                       [131,131,131,131,131,131])
    }

    func testOverlapUsesMaximumCoverageAndPreservesFractionalEdges() throws {
        let candidate = try GrayMask(width: 4, height: 1, bytes: Data([255,255,128,100]))
        let first = try GrayMask(width: 4, height: 1, bytes: Data([255,128,128,0]))
        let second = try GrayMask(width: 4, height: 1, bytes: Data([64,64,64,0]))
        let result = try PersonMaskAssembly.removingOverlap(from: candidate, occupied: [first, second])
        XCTAssertEqual(Array(result.bytes), [0,127,63,100])
        XCTAssertEqual(try PersonMaskAssembly.removingOverlap(from: candidate, occupied: []), candidate)
    }

    func testSegmentationRebuildsIndependentIDsAndStableCoverageLabels() throws {
        let first = try GrayMask(width: 5, height: 1, bytes: Data([255,64,128,63,0]))
        let second = try GrayMask(width: 5, height: 1, bytes: Data([0,64,200,63,255]))
        // Separate requests may both call their only subject "1"; assembly assigns global IDs.
        let result = try PersonMaskAssembly.segmentation(masks: [first, second])
        XCTAssertEqual(result.subjects.map(\.id), [1,2])
        XCTAssertEqual(result.subjects.map(\.mask), [first,second])
        XCTAssertEqual(Array(result.labels.bytes), [1,1,2,0,2])
        XCTAssertEqual(result.groupedSubjectCount, 0)
        let empty = try GrayMask(width: 1, height: 1, bytes: Data([0]))
        XCTAssertEqual(try PersonMaskAssembly.segmentation(masks: [empty]).subjects.count, 1,
                       "是否具备可靠核心由调用方判断，组装不能静默改变人物索引")
    }

    func testInvalidDimensionsROIsAndCountsAreRejected() throws {
        let mask = try GrayMask(width: 1, height: 1, bytes: Data([255]))
        let wide = try GrayMask(width: 2, height: 1, bytes: Data([255,255]))
        for (left,top,width,height) in [(-1,0,1,1), (0,-1,1,1), (0,0,0,1), (0,0,1,0),
                                       (2,0,1,1), (0,2,1,1), (1,0,2,1), (0,1,1,2),
                                       (Int.max,0,1,1), (0,0,Int.max,1)] {
            XCTAssertThrowsError(try PersonMaskAssembly.project(mask,left:left,top:top,width:width,height:height,
                                                                imageSize:.init(width:2,height:2)))
        }
        for size in [PixelSize(width:0,height:2), .init(width:2,height:-1), .init(width:4097,height:1)] {
            XCTAssertThrowsError(try PersonMaskAssembly.project(mask,left:0,top:0,width:1,height:1,imageSize:size))
        }
        XCTAssertThrowsError(try PersonMaskAssembly.removingOverlap(from:mask,occupied:[wide]))
        XCTAssertThrowsError(try PersonMaskAssembly.segmentation(masks:[]))
        XCTAssertThrowsError(try PersonMaskAssembly.segmentation(masks:Array(repeating:mask,count:5)))
        XCTAssertThrowsError(try PersonMaskAssembly.segmentation(masks:[mask,wide]))
    }
}
