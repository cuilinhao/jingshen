import Foundation

/// Combines independent Vision requests in the original image's top-left coordinate system.
enum PersonMaskAssembly {
    /// Select the soft four-connected region attached to a reliable seed near a detector target.
    static func component(in mask: GrayMask, near point: UnitPoint2D, searchRadius: Int) throws -> GrayMask? {
        try Task.checkCancellation()
        let p = point.clamped
        let px = p.x * Double(mask.width - 1), py = p.y * Double(mask.height - 1)
        let centerX = Int(px.rounded()), centerY = Int(py.rounded())
        let radius = max(0, min(max(mask.width, mask.height), searchRadius))
        var seed: Int?, bestCoverage: UInt8 = 127, bestDistance = Double.infinity
        for y in max(0, centerY - radius)...min(mask.height - 1, centerY + radius) {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in max(0, centerX - radius)...min(mask.width - 1, centerX + radius) {
                let index = y * mask.width + x, value = mask.bytes[index]
                guard value >= 128 else { continue }
                let dx = Double(x) - px, dy = Double(y) - py
                let distance = dx * dx + dy * dy
                if value > bestCoverage || (value == bestCoverage && distance < bestDistance) {
                    seed = index; bestCoverage = value; bestDistance = distance
                }
            }
        }
        guard let seed else { return nil }
        var output = [UInt8](repeating: 0, count: mask.bytes.count)
        var queue = [Int](); queue.reserveCapacity(min(mask.bytes.count, 4096))
        output[seed] = mask.bytes[seed]; queue.append(seed)
        func enqueue(_ index: Int) {
            guard output[index] == 0, mask.bytes[index] >= 32 else { return }
            output[index] = mask.bytes[index]
            queue.append(index)
        }
        var head = 0
        while head < queue.count {
            if head % 16384 == 0 { try Task.checkCancellation() }
            let index = queue[head]; head += 1
            let x = index % mask.width, y = index / mask.width
            if x > 0 { enqueue(index - 1) }
            if x + 1 < mask.width { enqueue(index + 1) }
            if y > 0 { enqueue(index - mask.width) }
            if y + 1 < mask.height { enqueue(index + mask.width) }
        }
        return try GrayMask(width: mask.width, height: mask.height, bytes: Data(output))
    }

    static func project(_ mask: GrayMask, left: Int, top: Int, width: Int, height: Int,
                        imageSize: PixelSize) throws -> GrayMask {
        try Task.checkCancellation()
        guard imageSize.width > 0, imageSize.height > 0,
              imageSize.width <= 4096, imageSize.height <= 4096,
              left >= 0, top >= 0, width > 0, height > 0,
              left < imageSize.width, top < imageSize.height,
              width <= imageSize.width - left, height <= imageSize.height - top else {
            throw MaskDataError.invalidDimensions
        }
        var output = [UInt8](repeating: 0, count: imageSize.width * imageSize.height)
        // Match image resampling: align pixel centers, then clamp taps at the crop edges.
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let sy = min(Double(mask.height - 1), max(0, (Double(y) + 0.5) * Double(mask.height) / Double(height) - 0.5))
            let y0 = Int(sy), y1 = min(mask.height - 1, y0 + 1), fy = sy - Double(y0)
            for x in 0..<width {
                let sx = min(Double(mask.width - 1), max(0, (Double(x) + 0.5) * Double(mask.width) / Double(width) - 0.5))
                let x0 = Int(sx), x1 = min(mask.width - 1, x0 + 1), fx = sx - Double(x0)
                let upper = Double(mask.bytes[y0 * mask.width + x0]) * (1 - fx) + Double(mask.bytes[y0 * mask.width + x1]) * fx
                let lower = Double(mask.bytes[y1 * mask.width + x0]) * (1 - fx) + Double(mask.bytes[y1 * mask.width + x1]) * fx
                output[(top + y) * imageSize.width + left + x] = UInt8(min(255, max(0, (upper * (1 - fy) + lower * fy).rounded())))
            }
        }
        return try GrayMask(width: imageSize.width, height: imageSize.height, bytes: Data(output))
    }

    static func removingOverlap(from candidate: GrayMask, occupied: [GrayMask]) throws -> GrayMask {
        try Task.checkCancellation()
        guard occupied.allSatisfy({ $0.width == candidate.width && $0.height == candidate.height }) else {
            throw MaskDataError.invalidDimensions
        }
        guard !occupied.isEmpty else { return candidate }
        var output = [UInt8](repeating: 0, count: candidate.bytes.count)
        for index in output.indices {
            if index % 16384 == 0 { try Task.checkCancellation() }
            let coverage = occupied.reduce(UInt8(0)) { max($0, $1.bytes[index]) }
            output[index] = UInt8(Int(candidate.bytes[index]) * (255 - Int(coverage)) / 255)
        }
        return try GrayMask(width: candidate.width, height: candidate.height, bytes: Data(output))
    }

    static func segmentation(masks: [GrayMask]) throws -> SubjectSegmentation {
        try Task.checkCancellation()
        guard (1...4).contains(masks.count), let first = masks.first,
              masks.allSatisfy({ $0.width == first.width && $0.height == first.height }),
              masks.reduce(0, { $0 + $1.bytes.count }) <= 32 * 1024 * 1024 else {
            throw MaskDataError.inconsistentSubjects
        }
        var labels = [UInt8](repeating: 0, count: first.bytes.count)
        for index in labels.indices {
            if index % 16384 == 0 { try Task.checkCancellation() }
            var best: UInt8 = 63
            for (subjectIndex, mask) in masks.enumerated() where mask.bytes[index] > best {
                best = mask.bytes[index]
                labels[index] = UInt8(subjectIndex + 1)
            }
        }
        let subjects = masks.enumerated().map { SubjectMask(id: UInt8($0.offset + 1), mask: $0.element) }
        return try SubjectSegmentation(labels: GrayMask(width: first.width, height: first.height, bytes: Data(labels)),
                                       subjects: subjects)
    }
}
