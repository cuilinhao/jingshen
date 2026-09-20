import Foundation
import CoreVideo

struct RawDepth {
    var width: Int
    var height: Int
    var values: [Float]
}

/// CVPixelBuffer memory is top-left row order. Respect bytesPerRow; never assume tight rows.
enum PixelBufferReader {
    static func labels(_ buffer: CVPixelBuffer) throws -> GrayMask {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              !CVPixelBufferIsPlanar(buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ImagingError.invalidPixelBuffer
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= 4096, height <= 4096, rowBytes >= width,
              let base = CVPixelBufferGetBaseAddress(buffer) else { throw ImagingError.invalidPixelBuffer }
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { bytes[y * width + x] = row[x] }
        }
        return try GrayMask(width: width, height: height, bytes: Data(bytes))
    }

    static func floats(_ buffer: CVPixelBuffer, longestEdge: Int = 2048) throws -> RawDepth {
        guard !CVPixelBufferIsPlanar(buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw ImagingError.invalidPixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), format = CVPixelBufferGetPixelFormatType(buffer)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              let base = CVPixelBufferGetBaseAddress(buffer) else { throw ImagingError.invalidPixelBuffer }
        let bytesPerPixel: Int
        switch format {
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            bytesPerPixel = 4
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16, kCVPixelFormatType_DisparityFloat16:
            bytesPerPixel = 2
        case kCVPixelFormatType_OneComponent8: bytesPerPixel = 1
        default: throw ImagingError.unsupportedDepthFormat(format)
        }
        guard rowBytes >= width * bytesPerPixel else { throw ImagingError.invalidPixelBuffer }
        let size = ImageGeometry.outputSize(width: width, height: height, longestEdge: min(2048, max(1, longestEdge)))
        var values = [Float](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let sourceY = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(size.height)))
            let row = base.advanced(by: sourceY * rowBytes)
            for x in 0..<size.width {
                let sourceX = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(size.width)))
                let value: Float
                if bytesPerPixel == 4 { value = row.assumingMemoryBound(to: Float.self)[sourceX] }
                else if bytesPerPixel == 2 { value = Float(Float16(bitPattern: row.assumingMemoryBound(to: UInt16.self)[sourceX])) }
                else { value = Float(row.assumingMemoryBound(to: UInt8.self)[sourceX]) / 255 }
                values[y * size.width + x] = value
            }
        }
        return RawDepth(width: size.width, height: size.height, values: values)
    }

    static func coverage(_ buffer: CVPixelBuffer) throws -> GrayMask {
        let raw = try floats(buffer)
        let bytes = raw.values.map { value -> UInt8 in
            guard value.isFinite else { return 0 }
            return UInt8((min(1, max(0, value)) * 255).rounded())
        }
        return try GrayMask(width: raw.width, height: raw.height, bytes: Data(bytes))
    }
}
