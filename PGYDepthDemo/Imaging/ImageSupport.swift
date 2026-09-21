import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// No custom kernels or Metal shader source. All image operations use Apple's native filters.
enum ImagingError: Error, LocalizedError {
    case unreadableImage, imageTooLarge, cannotRender, invalidPixelBuffer
    case noSubjects, unsupportedDepthFormat(UInt32)
    case noPhoto, incompatibleDraft, deniedPhotoPermission

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "无法读取这张照片。请选择 JPEG、PNG 或 HEIC 静态照片。"
        case .imageTooLarge: return "照片文件超过 100 MB，请先缩小文件后再导入。"
        case .cannotRender: return "图片渲染失败，请重试或更换照片。"
        case .invalidPixelBuffer: return "无法创建或读取图像缓冲区。"
        case .noSubjects: return "这张照片没有识别到可分离主体。可以使用局部虚化，或更换主体更清晰的照片。"
        case .unsupportedDepthFormat(let value): return "深度图像素格式不受支持：\(value)"
        case .noPhoto: return "请先导入一张照片。"
        case .incompatibleDraft: return "草稿版本或数据不兼容，请重新导入原图。"
        case .deniedPhotoPermission: return "没有保存照片的权限。可在系统设置中允许添加照片，或使用“分享图片”导出到文件。"
        }
    }
}

enum ImageSupport {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

    static func grayImage(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        guard width > 0, height > 0, width * height == bytes.count,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { throw ImagingError.cannotRender }
        return image
    }

    static func ciCropRect(unit: Rect2D, extent: CGRect) -> CGRect {
        CGRect(x: extent.minX + CGFloat(unit.x) * extent.width,
               y: extent.minY + CGFloat(1 - unit.y - unit.height) * extent.height,
               width: CGFloat(unit.width) * extent.width,
               height: CGFloat(unit.height) * extent.height)
    }

    static func cropped(_ image: CIImage, ratio: CropRatio, originalSize: PixelSize) -> CIImage {
        let unit = ratio.unitRect(imageWidth: originalSize.width, imageHeight: originalSize.height)
        let rect = ciCropRect(unit: unit, extent: image.extent).integral.intersection(image.extent)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    static func resized(_ image: CGImage, longestEdge: Int, context: CIContext) throws -> CGImage {
        let size = ImageGeometry.outputSize(width: image.width, height: image.height, longestEdge: longestEdge)
        if size.width == image.width, size.height == image.height { return image }
        let input = CIImage(cgImage: image)
        let resized = input.transformed(by: CGAffineTransform(scaleX: CGFloat(size.width) / CGFloat(image.width),
                                                             y: CGFloat(size.height) / CGFloat(image.height)))
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        return try cgImage(resized.cropped(to: bounds), context: context)
    }

    static func cgImage(_ image: CIImage, context: CIContext) throws -> CGImage {
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                colorSpace: colorSpace) else { throw ImagingError.cannotRender }
        return result
    }

    static func jpegData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagingError.cannotRender
        }
        // Export is explicitly SDR/sRGB JPEG; no EXIF GPS metadata is copied.
        CGImageDestinationAddImage(destination, image,
                                  [kCGImageDestinationLossyCompressionQuality: 0.95,
                                   kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagingError.cannotRender }
        return data as Data
    }
}
