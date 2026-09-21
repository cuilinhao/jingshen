import XCTest
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
@testable import PGYDepthDemo

final class NativeDepthPriorityTests: XCTestCase {
    /// An actual JPEG auxiliary disparity plane. EXIF right rotation must affect
    /// both the photograph and the native depth before cache selection happens.
    private func nativeJPEG() throws -> Data {
        let photo = try ImageSupport.grayImage(width: 48, height: 32,
                                              bytes: [UInt8](repeating: 128, count: 48 * 32))
        let values: [Float] = [1, 2, 3, 4, 5, 6]
        let raw = values.withUnsafeBytes { Data($0) }
        let description: [CFString: Any] = [kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat32,
            kCGImagePropertyWidth: 3, kCGImagePropertyHeight: 2, kCGImagePropertyBytesPerRow: 12]
        let depth = try AVDepthData(fromDictionaryRepresentation: [
            kCGImageAuxiliaryDataInfoData: raw,
            kCGImageAuxiliaryDataInfoDataDescription: description,
            kCGImageAuxiliaryDataInfoMetadata: CGImageMetadataCreateMutable()
        ])
        var type: NSString?
        let auxiliary = try XCTUnwrap(depth.dictionaryRepresentation(forAuxiliaryDataType: &type))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, photo,
            [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, auxiliary as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testOrientedNativeDepthWinsOverCurrentEstimatedCache() async throws {
        let data = try nativeJPEG()
        let decoded = try PhotoLoader.decode(data, context: CIContext())
        let native = try XCTUnwrap(decoded.nativeDepth, "Fixture must contain real readable native disparity")
        XCTAssertEqual(decoded.image.width, 32)
        XCTAssertEqual(decoded.image.height, 48)
        XCTAssertEqual(native.width, 2)
        XCTAssertEqual(native.height, 3)
        // [1,2,3 / 4,5,6] rotated clockwise is [4,1 / 5,2 / 6,3].
        XCTAssertGreaterThan(native.values[0], native.values[1])
        XCTAssertGreaterThan(native.values[4], native.values[0])
        let cached = try DepthField(width: 2, height: 3, values: [0, 0, 0, 0, 0, 0])
        let pipeline = PhotoPipeline(depthEstimator: UnavailablePriorityEstimator())
        let photo = try await pipeline.prepare(data: data, title: "native priority",
            cachedAnalysis: .estimated(DepthEstimate(field: cached)),
            cachedImageSize: PixelSize(width: 32, height: 48))
        XCTAssertEqual(photo.analysis, .native(native), "Source native depth must supersede a matching AI cache")
        XCTAssertNil(photo.notice)
    }
}

private struct UnavailablePriorityEstimator: DepthEstimating {
    func estimate(_ source: CGImage) throws -> DepthEstimate { throw ImagingError.cannotRender }
}
