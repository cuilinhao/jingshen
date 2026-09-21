import Foundation

enum DepthDataError: Error, LocalizedError {
    case invalidDimensions, noFiniteValues
    var errorDescription: String? {
        switch self {
        case .invalidDimensions: return "深度图尺寸或数据长度不正确。"
        case .noFiniteValues: return "没有可用的深度值，请更换照片后重试。"
        }
    }
}

/// Row-major, visual top-to-bottom. 0 = far, 1 = near (relative disparity).
/// The name does NOT imply meters or a metric camera calibration.
struct DepthField: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height == values.count else { throw DepthDataError.invalidDimensions }
        guard values.allSatisfy({ $0.isFinite }) else { throw DepthDataError.noFiniteValues }
        self.width = width
        self.height = height
        self.values = values.map { min(1, max(0, $0)) }
    }

    private enum CodingKeys: String, CodingKey { case width, height, values }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: box.decode(Int.self, forKey: .width),
                      height: box.decode(Int.self, forKey: .height),
                      values: box.decode([Float].self, forKey: .values))
    }

    static func normalizing(width: Int, height: Int, values: [Float]) throws -> Self {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height == values.count else { throw DepthDataError.invalidDimensions }
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last else { throw DepthDataError.noFiniteValues }
        let count = sorted.count
        let low = count > 100 ? sorted[Int(Double(count - 1) * 0.01)] : first
        let high = count > 100 ? sorted[Int(Double(count - 1) * 0.99)] : last
        let span = high - low
        if span < 0.000001 {
            return try Self(width: width, height: height, values: Array(repeating: 0.5, count: values.count))
        }
        // Invalid native disparity pixels are filled from nearby finite samples where possible.
        // Median fallback is reserved for genuinely empty neighborhoods.
        let fallback = sorted[count / 2]
        var repaired = values
        for index in values.indices where !values[index].isFinite {
            let x = index % width, y = index / width
            var local: [Float] = []
            for yy in max(0, y - 2)...min(height - 1, y + 2) {
                for xx in max(0, x - 2)...min(width - 1, x + 2) {
                    let candidate = values[yy * width + xx]
                    if candidate.isFinite { local.append(candidate) }
                }
            }
            local.sort()
            repaired[index] = local.isEmpty ? fallback : local[local.count / 2]
        }
        return try Self(width: width, height: height,
                        values: repaired.map { min(1, max(0, ($0 - low) / span)) })
    }

    func sample(at point: UnitPoint2D, radius: Int = 2) -> Float {
        let p = point.clamped
        let x = min(width - 1, Int((p.x * Double(width - 1)).rounded()))
        let y = min(height - 1, Int((p.y * Double(height - 1)).rounded()))
        let r = max(0, min(12, radius))
        var neighborhood: [Float] = []
        for yy in max(0, y - r)...min(height - 1, y + r) {
            for xx in max(0, x - r)...min(width - 1, x + r) {
                neighborhood.append(values[yy * width + xx])
            }
        }
        neighborhood.sort()
        return neighborhood[neighborhood.count / 2]
    }

    func bytes(transform: (Float) -> Float = { $0 }) -> [UInt8] {
        values.map { UInt8((min(1, max(0, transform($0))) * 255).rounded()) }
    }
}
