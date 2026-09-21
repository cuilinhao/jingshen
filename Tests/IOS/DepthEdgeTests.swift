import XCTest
import CoreImage
@testable import PGYDepthDemo

final class DepthEdgeTests: XCTestCase {
    private func edgeFixture() throws -> (CGImage, DepthField) {
        let width = 512, height = 256
        var pixels = [UInt8](repeating: 0, count: width * height)
        var depths = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            if x < 256 { pixels[y * width + x] = 255; depths[y * width + x] = 1 }
            else if x >= 384 { pixels[y * width + x] = x % 4 < 2 ? 255 : 0 }
        } }
        return (try ImageSupport.grayImage(width: width, height: height, bytes: pixels),
                try DepthField(width: width, height: height, values: depths))
    }

    func testFarFocusDiffusesForegroundWithoutOriginalSilhouette() throws {
        let context = CIContext(), (source, depth) = try edgeFixture()
        var recipe = EditRecipe()
        recipe.aperture = 1.4; recipe.edgeFeather = 0
        recipe.focusPoint = UnitPoint2D(x: 0.65, y: 0.5)
        let output = try DepthRenderer(context: context).render(image: source, photoID: UUID(),
            analysis: .native(depth), sourceSize: PixelSize(width: 512, height: 256), recipe: recipe)
        var bytes = [UInt8](repeating: 0, count: 512 * 256 * 4)
        bytes.withUnsafeMutableBytes { data in
            context.render(CIImage(cgImage: output), toBitmap: data.baseAddress!, rowBytes: 512 * 4,
                bounds: CGRect(x: 0, y: 0, width: 512, height: 256), format: .RGBA8,
                colorSpace: ImageSupport.colorSpace)
        }
        func red(_ x: Int) -> Int { Int(bytes[(128 * 512 + x) * 4]) }
        let largestStep = (244..<268).map { abs(red($0 + 1) - red($0)) }.max()!
        print("DepthEdge largest adjacent step=\(largestStep), boundary=\(red(255))/\(red(256)), outside=\(red(266))")
        // A blurred edge must transition continuously across the old silhouette.
        // Reintroducing the old RGB+alpha overlay leaves an abrupt step here.
        XCTAssertLessThan(largestStep, 24)
        XCTAssertGreaterThan(red(266), 5, "Defocused foreground must spread outside its old edge")
        XCTAssertGreaterThan(abs(red(400) - red(402)), 240, "Distant focused detail must remain sharp")
        XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 })
        if let path = ProcessInfo.processInfo.environment["DEPTH_EDGE_OUTPUT"] {
            try context.writePNGRepresentation(of: CIImage(cgImage: output), to: URL(fileURLWithPath: path),
                format: .RGBA8, colorSpace: ImageSupport.colorSpace)
        }
    }
}
