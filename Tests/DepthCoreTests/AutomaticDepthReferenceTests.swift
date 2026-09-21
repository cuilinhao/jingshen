import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

/// Actual uploaded MLProgram weights evaluated outside Apple Core ML. This fixture is for
/// numeric regression ONLY and is never bundled into the shipping App or loaded by its pipeline.
final class AutomaticDepthReferenceTests: XCTestCase {
    private func field() throws -> DepthField {
        #if canImport(DepthCore)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Fixtures/AutomaticReference.f32")
        #else
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AutomaticReference", withExtension: "f32"))
        #endif
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 518*392*4)
        let values: [Float] = data.withUnsafeBytes { buffer in
            stride(from: 0, to: buffer.count, by: 4).map { offset in
                Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        return try DepthField.normalizing(width: 518, height: 392, values: values)
    }
    func testActualReferenceHasDenseFiniteNonConstantDepth() throws {
        let d = try field()
        XCTAssertEqual(d.values.count, 203056); XCTAssertTrue(d.values.allSatisfy(\.isFinite))
        XCTAssertLessThan(try XCTUnwrap(d.values.min()), 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(d.values.max()), 0.99)
    }
    func testEveryReportedTapNowSamplesMeasuredModelOutput() throws {
        let d = try field()
        for (index, p) in AutomaticDepthTests.reportedPoints.enumerated() {
            let z = d.sample(at: p)
            print("[ReferenceCPU] actual original tap \(index + 1), depth=\(z)")
            if [0,1,5].contains(index) { XCTAssertLessThan(z, 0.4) }
            else { XCTAssertGreaterThan(z, 0.65) }
        }
    }
    func testActualBottleFocusKeepsMonitorBottleAndToyClear() throws {
        let d = try field()
        let masks = try ContinuousFocusMasks.make(depth: d, point: .init(x: 0.4845360824742268,y: 0.7854381443298968), tolerance: 0.22)
        for p in [UnitPoint2D(x: 0.15,y: 0.52), .init(x: 0.4845,y: 0.7854), .init(x: 0.21,y: 0.9)] {
            XCTAssertEqual(masks.blur.value(at: p), 0)
            XCTAssertEqual(masks.protection?.value(at: p), 255)
        }
        XCTAssertEqual(masks.blur.value(at: .init(x: 0.8393470790378006,y: 0.5483247422680413)), 255)
    }
    func testActualCabinetFocusBlursAllThreeNearObjects() throws {
        let d = try field()
        let p = UnitPoint2D(x: 0.8393470790378006,y: 0.5483247422680413)
        let masks = try ContinuousFocusMasks.make(depth: d, point: p, tolerance: 0.22)
        XCTAssertEqual(masks.blur.value(at: p), 0)
        for q in [UnitPoint2D(x: 0.15,y: 0.52), .init(x: 0.4845,y: 0.7854), .init(x: 0.21,y: 0.9)] {
            XCTAssertGreaterThan(masks.blur.value(at: q), 210)
        }
    }
}
