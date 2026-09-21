import Foundation
import CoreImage
import CoreGraphics

/// Each person has an independent premultiplied layer. Background color extension removes
/// the original silhouette before blur; it approximates hidden pixels, not scene reconstruction.
final class PortraitRenderer {
    private let context: CIContext
    private struct Prepared {
        let photoID: UUID
        let width: Int
        let height: Int
        let background: CIImage
        let layers: [UInt8: CIImage]
    }
    private var cached: Prepared?
    init(context: CIContext) { self.context = context }

    static func maskImage(_ mask: GrayMask, extent: CGRect) throws -> CIImage {
        let cg = try ImageSupport.grayImage(width: mask.width, height: mask.height, bytes: Array(mask.bytes))
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(mask.width),
                                              y: extent.height / CGFloat(mask.height))).cropped(to: extent)
    }

    func render(input: CIImage, photoID: UUID, portrait: PortraitAnalysis, depth: DepthField,
                recipe: EditRecipe, radius: Double) throws -> CIImage {
        guard let selectedID = portrait.person(id: recipe.selectedPersonID)?.id else { return input }
        let prepared = try prepare(input: input, photoID: photoID, portrait: portrait)
        let focus = portrait.focusDepth(depth: depth, selectedID: selectedID, point: recipe.focusPoint)
        let control = try GrayMask(width: depth.width, height: depth.height, bytes: Data(depth.values.map {
            UInt8((255 * max(0.4, DepthMath.smoothstep(0.03, 0.55, abs($0 - focus)))).rounded())
        }))
        let mask = try Self.maskImage(control, extent: input.extent)
        var result = prepared.background.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
            "inputMask": mask.clampedToExtent(), kCIInputRadiusKey: radius
        ]).cropped(to: input.extent)
        for layer in portrait.layers(depth: depth, selectedID: selectedID, focusPoint: recipe.focusPoint) {
            try Task.checkCancellation()
            guard var image = prepared.layers[layer.subject.id] else { continue }
            if layer.blurAmount > 0 {
                image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * Double(layer.blurAmount)])
            }
            result = image.composited(over: result).cropped(to: input.extent)
        }
        return result
    }

    private func pixels(_ image: CIImage, width: Int, height: Int, colorSpace: CGColorSpace?) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4,
                       bounds: image.extent, format: .RGBA8, colorSpace: colorSpace)
        return bytes
    }

    private func linearPixels(_ image: CIImage, width: Int, height: Int) -> [UInt16] {
        var bits = [UInt16](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bits, rowBytes: width * 8,
                       bounds: image.extent, format: .RGBAh, colorSpace: ImageSupport.linearColorSpace)
        return bits
    }

    private func prepare(input: CIImage, photoID: UUID, portrait: PortraitAnalysis) throws -> Prepared {
        let width = Int(input.extent.width), height = Int(input.extent.height)
        if let cached, cached.photoID == photoID, cached.width == width, cached.height == height { return cached }
        let source = linearPixels(input, width: width, height: height)
        let union = try Self.maskImage(portrait.segmentation.allForegroundMask(), extent: input.extent)
        let coverage = pixels(union, width: width, height: height, colorSpace: nil)
        let count = width * height
        var background = source
        var distance = [UInt16](repeating: 0, count: count)
        var queue = [Int](); queue.reserveCapacity(count / 3)
        // Maximum aperture × effect strength × three Gaussian sigmas, plus resampling margin.
        let limit = UInt16(ceil(3 * 48 * Double(max(width, height)) / 1024 + 8))
        func neighbors(_ index: Int) -> [Int] {
            let x = index % width, y = index / width
            var result = [Int](); result.reserveCapacity(4)
            if x > 0 { result.append(index - 1) }; if x + 1 < width { result.append(index + 1) }
            if y > 0 { result.append(index - width) }; if y + 1 < height { result.append(index + width) }
            return result
        }
        func copyPixel(from: Int, to: Int) {
            for c in 0..<4 { background[to * 4 + c] = background[from * 4 + c] }
        }
        // Seed only with actual background; the immutable coverage prevents using person colors.
        for index in 0..<count where coverage[index * 4] > 8 {
            if index % (width * 32) == 0 { try Task.checkCancellation() }
            if let seed = neighbors(index).first(where: { coverage[$0 * 4] <= 8 }) {
                distance[index] = 1; copyPixel(from: seed, to: index); queue.append(index)
            }
        }
        var head = 0
        while head < queue.count {
            if head % 16384 == 0 { try Task.checkCancellation() }
            let index = queue[head]; head += 1
            guard distance[index] < limit else { continue }
            for next in neighbors(index) where coverage[next * 4] > 8 && distance[next] == 0 {
                distance[next] = distance[index] + 1
                copyPixel(from: index, to: next); queue.append(next)
            }
        }
        let size = CGSize(width: width, height: height)
        let backgroundImage = CIImage(bitmapData: background.withUnsafeBytes { Data($0) }, bytesPerRow: width * 8,
                                      size: size, format: .RGBAh, colorSpace: ImageSupport.linearColorSpace)
        var layers: [UInt8: CIImage] = [:]
        for subject in portrait.segmentation.subjects {
            try Task.checkCancellation()
            let mask = try Self.maskImage(subject.mask, extent: input.extent)
            let alpha = pixels(mask, width: width, height: height, colorSpace: nil)
            var bytes = [UInt16](repeating: 0, count: source.count)
            for index in 0..<count {
                let a = Float(alpha[index * 4]) / 255
                guard a > 0 else { continue }
                bytes[index * 4 + 3] = Float16(a).bitPattern
                for c in 0..<3 {
                    // Matting is linear-light arithmetic. Doing this on gamma-encoded sRGB
                    // leaves a bright fringe even with an otherwise correct fractional alpha.
                    let color = Float(Float16(bitPattern: source[index * 4 + c]))
                    let underlay = Float(Float16(bitPattern: background[index * 4 + c]))
                    let value = color - (1 - a) * underlay
                    bytes[index * 4 + c] = Float16(min(a, max(0, value))).bitPattern
                }
            }
            layers[subject.id] = CIImage(bitmapData: bytes.withUnsafeBytes { Data($0) }, bytesPerRow: width * 8,
                                         size: size, format: .RGBAh, colorSpace: ImageSupport.linearColorSpace)
        }
        let result = Prepared(photoID: photoID, width: width, height: height, background: backgroundImage, layers: layers)
        cached = result
        return result
    }
}
