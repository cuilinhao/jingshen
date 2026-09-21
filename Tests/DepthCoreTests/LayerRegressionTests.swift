import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class LayerRegressionTests: XCTestCase {
    func testUnassignedPixelsAreNotAssumedToBeFarBackground() throws {
        // Vision recognizes monitor=7, misses bottle=0, cabinet=0. IDs contain no depth.
        let labels = try GrayMask(width: 3, height: 1, bytes: Data([7,0,0]))
        let mask = try GrayMask(width: 3, height: 1, bytes: Data([255,0,0]))
        let subjects = try SubjectSegmentation(labels: labels, subjects: [.init(id: 7, mask: mask)])
        var recipe = EditRecipe(); recipe.focusPoint = .center
        let output = try FocusMaskBuilder.make(analysis: .subjects(subjects), recipe: recipe,
                                              imageSize: .init(width: 300, height: 100))
        XCTAssertEqual(Array(output.blur.bytes), [0,0,0],
                       "Unassigned bottle tap must not claim background and blur monitor")
        XCTAssertNil(output.nearDefocus)
    }
}
