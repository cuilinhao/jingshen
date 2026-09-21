import Foundation
import CoreImage
import CoreGraphics

/// Shared Core Image renderer. Predicted relative depth and native depth remain explicitly typed.
/// This does not reconstruct occluded backgrounds or recover details missing from the input.
final class DepthRenderer {
    private let context: CIContext
    private let portraitRenderer: PortraitRenderer
    private struct MaskKey: Equatable {
        let photoID: UUID
        let point: UnitPoint2D
        let mode: FocusMode
        let tolerance: Double
        let radius: Double
        let imageSize: PixelSize
    }
    private var cachedKey: MaskKey?
    private var cachedMasks: FocusMaskSet?
    init(context: CIContext) { self.context = context; portraitRenderer = PortraitRenderer(context: context) }

    private func masks(photoID: UUID, analysis: PhotoAnalysis, recipe: EditRecipe,
                       sourceSize: PixelSize) throws -> FocusMaskSet {
        let key = MaskKey(photoID: photoID, point: recipe.focusPoint, mode: recipe.focusMode,
                          tolerance: recipe.focusTolerance, radius: recipe.localRadius, imageSize: sourceSize)
        if key == cachedKey, let cachedMasks { return cachedMasks }
        let result = try FocusMaskBuilder.make(analysis: analysis, recipe: recipe, imageSize: sourceSize)
        cachedKey = key; cachedMasks = result
        return result
    }

    func render(image: CGImage, photoID: UUID, analysis: PhotoAnalysis,
                sourceSize: PixelSize, recipe: EditRecipe, portrait: PortraitAnalysis? = nil) throws -> CGImage {
        try autoreleasepool {
            try Task.checkCancellation()
            var safe = recipe; safe.sanitize()
            let input = CIImage(cgImage: image), extent = CIImage(cgImage: image).extent
            let pixelScale = Double(max(image.width, image.height)) / 1024
            let maxRadius = 32 * Aperture.strength(safe.aperture) * safe.effectStrength * pixelScale
            var result = input
            if safe.depthEnabled, maxRadius > 0.15, safe.focusMode == .automatic,
               let portrait, portrait.person(id: safe.selectedPersonID) != nil, let depth = analysis.continuousDepth {
                result = try portraitRenderer.render(input: input, photoID: photoID, portrait: portrait,
                                                     depth: depth, recipe: safe, radius: maxRadius)
            } else if safe.depthEnabled, maxRadius > 0.15 {
                let selections = try masks(photoID: photoID, analysis: analysis, recipe: safe, sourceSize: sourceSize)
                let mask = try maskImage(selections.blur, extent: extent, feather: safe.edgeFeather * pixelScale)
                result = input.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
                    "inputMask": mask.clampedToExtent(), "inputRadius": maxRadius
                ]).cropped(to: extent)
                try Task.checkCancellation()

                // When the background is selected, the foreground should diffuse beyond its old
                // silhouette. Blur the premultiplied foreground RGB+alpha before compositing.
                // This remains an approximation; it is not hidden-background reconstruction.
                if let near = selections.nearDefocus {
                    let nearImage = try maskImage(near, extent: extent, feather: safe.edgeFeather * pixelScale)
                    let clear = CIImage(color: .clear).cropped(to: extent)
                    let layer = input.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: clear, "inputMaskImage": nearImage
                    ])
                    let expanded = layer.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: maxRadius * 0.65])
                        .cropped(to: extent)
                    result = expanded.composited(over: result).cropped(to: extent)
                }
                // Reinsert the clear depth interval (and explicit legacy mask protections) after diffusion.
                // This protects same-layer objects from a neighbouring defocused foreground.
                if let protection = selections.protection {
                    let sharp = try maskImage(protection, extent: extent, feather: safe.edgeFeather * pixelScale)
                    result = input.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: result, "inputMaskImage": sharp
                    ]).cropped(to: extent)
                }
            }
            if abs(safe.exposure) > 0.001 {
                result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: safe.exposure])
            }
            switch safe.style {
            case .original: break
            case .monochrome:
                result = result.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            case .warm:
                result = result.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5400, y: 0)
                ])
            case .cool:
                result = result.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 7800, y: 0)
                ])
            }
            result = ImageSupport.cropped(result, ratio: safe.crop, originalSize: sourceSize)
            try Task.checkCancellation()
            return try ImageSupport.cgImage(result, context: context)
        }
    }

    func original(image: CGImage, crop: CropRatio, sourceSize: PixelSize) throws -> CGImage {
        try ImageSupport.cgImage(ImageSupport.cropped(CIImage(cgImage: image), ratio: crop, originalSize: sourceSize), context: context)
    }

    /// Predicted/native: relative disparity. Explicit local/legacy: actual blur-control mask.
    func maskPreview(image: CGImage, photoID: UUID, analysis: PhotoAnalysis,
                     sourceSize: PixelSize, recipe: EditRecipe, portrait: PortraitAnalysis? = nil) throws -> CGImage {
        let field: GrayMask
        if recipe.focusMode == .automatic, let mask = portrait?.person(id: recipe.selectedPersonID)?.mask {
            field = mask
        } else if let depth = analysis.continuousDepth, recipe.focusMode == .automatic {
            field = try GrayMask(width: depth.width, height: depth.height, bytes: Data(depth.bytes()))
        } else {
            field = try masks(photoID: photoID, analysis: analysis, recipe: recipe, sourceSize: sourceSize).blur
        }
        let isDepthMap = recipe.focusMode == .automatic && (analysis.continuousDepth != nil || portrait != nil)
        let feather = isDepthMap ? 0 : recipe.edgeFeather * Double(max(image.width, image.height)) / 1024
        let input = try maskImage(field, extent: CIImage(cgImage: image).extent, feather: feather)
        return try ImageSupport.cgImage(ImageSupport.cropped(input, ratio: recipe.crop, originalSize: sourceSize), context: context)
    }

    func selectionOutline(image: CGImage, sourceSize: PixelSize, recipe: EditRecipe,
                          portrait: PortraitAnalysis?) throws -> CGImage? {
        guard recipe.focusMode == .automatic, let mask = portrait?.person(id: recipe.selectedPersonID)?.mask else { return nil }
        let extent = CIImage(cgImage: image).extent
        let outline = try PortraitRenderer.maskImage(mask, extent: extent)
            .applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: 1.5])
            .applyingFilter("CIMaskToAlpha").cropped(to: extent)
        return try ImageSupport.cgImage(ImageSupport.cropped(outline, ratio: recipe.crop, originalSize: sourceSize), context: context)
    }

    private func maskImage(_ mask: GrayMask, extent: CGRect, feather: Double) throws -> CIImage {
        let cg = try ImageSupport.grayImage(width: mask.width, height: mask.height, bytes: Array(mask.bytes))
        var image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(mask.width), y: extent.height / CGFloat(mask.height)))
        if feather > 0.01 {
            image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
        }
        return image.cropped(to: extent)
    }
}
