import Foundation

enum PersonMaskRefinementError: Error, Equatable {
    case incomplete
}

/// Removes weak detached regions while retaining soft coverage close to a reliable body core.
/// Run once after Vision analysis; cached masks are already refined and must not be refined again.
enum PersonMaskRefinement {
    static func refine(_ mask: GrayMask) throws -> GrayMask {
        try Task.checkCancellation()
        let width = mask.width, height = mask.height
        let input = Array(mask.bytes)
        let far: UInt16 = 32_767
        var distance = [UInt16](repeating: far, count: input.count)
        var hasCore = false

        // A two-pass Manhattan transform avoids a queue per pixel and keeps distance storage bounded.
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let index = y * width + x
                if input[index] >= 230 {
                    distance[index] = 0
                    hasCore = true
                } else {
                    if x > 0 { distance[index] = min(distance[index], distance[index - 1] + 1) }
                    if y > 0 { distance[index] = min(distance[index], distance[index - width] + 1) }
                }
            }
        }
        guard hasCore else { throw PersonMaskRefinementError.incomplete }
        for y in (0..<height).reversed() {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in (0..<width).reversed() {
                let index = y * width + x
                if x + 1 < width { distance[index] = min(distance[index], distance[index + 1] + 1) }
                if y + 1 < height { distance[index] = min(distance[index], distance[index + width] + 1) }
            }
        }

        let scale = max(Float(0.25), Float(max(width, height)) / 1024)
        var output = [UInt8](repeating: 0, count: input.count)
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let index = y * width + x
                let coverage = DepthMath.smoothstep(32, 230, Float(input[index]))
                let locality = 1 - DepthMath.smoothstep(4 * scale, 8 * scale, Float(distance[index]))
                output[index] = UInt8((255 * coverage * locality).rounded())
            }
        }
        return try GrayMask(width: width, height: height, bytes: Data(output))
    }
}
