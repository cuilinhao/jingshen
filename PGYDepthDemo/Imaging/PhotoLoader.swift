import Foundation
import AVFoundation
import CoreImage
import ImageIO
import CoreVideo

struct DecodedPhoto {
    let image: CGImage
    let nativeDepth: DepthField?
}

/// This type is only used from PhotoPipeline's actor, never from the main thread.
enum PhotoLoader {
    static func decode(_ data: Data, context: CIContext) throws -> DecodedPhoto {
        guard data.count <= 100 * 1024 * 1024 else { throw ImagingError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImagingError.unreadableImage
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 2048
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 2048
        let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        // ImageIO decodes only the required pixels and applies all EXIF rotations / mirrors.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(2048, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImagingError.unreadableImage
        }
        let ci = CIImage(cgImage: thumbnail)
        let background = CIImage(color: CIColor.white).cropped(to: ci.extent)
        // Transparent PNGs are composited over white, consistently in preview and export.
        let image = try ImageSupport.cgImage(ci.composited(over: background), context: context)
        let native = readNativeDepth(source: source, orientation: orientation)
        return DecodedPhoto(image: image, nativeDepth: native)
    }

    private static func readNativeDepth(source: CGImageSource,
                                        orientation: CGImagePropertyOrientation) -> DepthField? {
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any] else {
                continue
            }
            do {
                let original = try AVDepthData(fromDictionaryRepresentation: info)
                let depth = original.applyingExifOrientation(orientation)
                    .converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
                var raw = try PixelBufferReader.floats(depth.depthDataMap, longestEdge: 1024)
                // Zero/negative physical disparity is invalid. Only native depth uses this reader.
                raw.values = raw.values.map { $0.isFinite && $0 > 0 ? $0 : .nan }
                let result = try DepthField.normalizing(width: raw.width, height: raw.height, values: raw.values)
                print("[Depth] 原生深度 \(raw.width)×\(raw.height)，已应用 EXIF \(orientation.rawValue)")
                return result
            } catch {
                print("[Depth] 原生辅助深度不可用，改用系统主体识别：\(error.localizedDescription)")
            }
        }
        return nil
    }
}
