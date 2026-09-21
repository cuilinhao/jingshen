import Foundation
import CoreGraphics

/// Diagnostic coloring only. The renderer consumes categorical labels, never these RGB colors.
enum LayerOverlay {
    static func image(_ map: SceneLayerMap) throws -> CGImage {
        var rgba = [UInt8](repeating: 0, count: map.labels.bytes.count * 4)
        for (index, value) in map.labels.bytes.enumerated() {
            let rgb: (UInt8,UInt8,UInt8)
            switch SceneLayer(rawValue: value) {
            case .near: rgb = (255,82,35)
            case .middle: rgb = (24,220,140)
            case .far: rgb = (55,143,255)
            default: continue
            }
            // Premultiplied RGBA, alpha approximately 0.45.
            let alpha: UInt16 = 115
            rgba[index*4] = UInt8(UInt16(rgb.0)*alpha/255)
            rgba[index*4+1] = UInt8(UInt16(rgb.1)*alpha/255)
            rgba[index*4+2] = UInt8(UInt16(rgb.2)*alpha/255)
            rgba[index*4+3] = UInt8(alpha)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: map.labels.width, height: map.labels.height,
                bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: map.labels.width*4,
                space: ImageSupport.colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent) else {
            throw ImagingError.cannotRender
        }
        return image
    }
}
