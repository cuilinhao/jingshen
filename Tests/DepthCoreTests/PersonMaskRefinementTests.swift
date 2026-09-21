import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class PersonMaskRefinementTests: XCTestCase {
    func testReliableBodyBecomesOpaqueAndAdjacentEdgesStaySoft() throws {
        var bytes = [UInt8](repeating: 0, count: 9 * 9)
        bytes[4 * 9 + 4] = 250
        for index in [3 * 9 + 4, 4 * 9 + 3, 4 * 9 + 5, 5 * 9 + 4] { bytes[index] = 131 }
        let result = try PersonMaskRefinement.refine(GrayMask(width: 9, height: 9, bytes: Data(bytes)))
        XCTAssertEqual(result.width, 9)
        XCTAssertEqual(result.height, 9)
        XCTAssertEqual(result.bytes[4 * 9 + 4], 255, "可靠的人体核心不能残留半透明背景")
        for index in [3 * 9 + 4, 4 * 9 + 3, 4 * 9 + 5, 5 * 9 + 4] {
            XCTAssertEqual(result.bytes[index], 128, "紧邻核心的软边应保留，不能二值化")
        }
    }

    func testWeakDetachedChairAndDistantIslandsAreRemoved() throws {
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes[100] = 230
        bytes[104] = 131
        bytes[106] = 131
        bytes[108] = 229
        bytes[300] = 180
        bytes[700] = 229
        let result = try PersonMaskRefinement.refine(GrayMask(width: 1024, height: 1, bytes: Data(bytes)))
        XCTAssertEqual(result.bytes[100], 255)
        XCTAssertEqual(result.bytes[104], 128)
        XCTAssertEqual(result.bytes[106], 64, "软边随离可靠核心的距离逐渐衰减")
        XCTAssertEqual(result.bytes[108], 0)
        XCTAssertEqual(result.bytes[300], 0, "弱椅子轮廓不能作为人物保留")
        XCTAssertEqual(result.bytes[700], 0, "远离人体核心的高覆盖孤岛也应剔除")
    }

    func testDistanceUsesBothAxesAndDoesNotWrapAtRowBoundary() throws {
        var bytes = [UInt8](repeating: 0, count: 9 * 9)
        bytes[4 * 9] = 255
        bytes[3 * 9 + 8] = 229
        bytes[3 * 9] = 131
        bytes[3 * 9 + 1] = 131
        let result = try PersonMaskRefinement.refine(GrayMask(width: 9, height: 9, bytes: Data(bytes)))
        XCTAssertEqual(result.bytes[3 * 9], 128, "反向扫描需要找到下一行的可靠核心")
        XCTAssertEqual(result.bytes[3 * 9 + 1], 0, "对角点的 Manhattan 距离为 2")
        XCTAssertEqual(result.bytes[3 * 9 + 8], 0, "上行末尾不应误当作本行开头的邻居")
    }

    func testMaskWithoutReliableCoreFailsInsteadOfReturningEmptyPerson() throws {
        let mask = try GrayMask(width: 3, height: 2, bytes: Data([0, 32, 128, 224, 229, 0]))
        XCTAssertThrowsError(try PersonMaskRefinement.refine(mask)) { error in
            XCTAssertEqual(error as? PersonMaskRefinementError, .incomplete)
        }
    }
}
