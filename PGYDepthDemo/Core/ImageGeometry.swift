import Foundation

/// All public coordinates in this demo use a TOP-LEFT origin, regardless of Core Image's origin.
struct UnitPoint2D: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    static let center = UnitPoint2D(x: 0.5, y: 0.5)
    var clamped: Self {
        Self(x: x.isFinite ? min(1, max(0, x)) : 0.5,
             y: y.isFinite ? min(1, max(0, y)) : 0.5)
    }
}

struct PixelSize: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct Rect2D: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    static let unit = Rect2D(x: 0, y: 0, width: 1, height: 1)
    var center: UnitPoint2D { UnitPoint2D(x: x + width / 2, y: y + height / 2) }
    func originalPoint(from point: UnitPoint2D) -> UnitPoint2D {
        UnitPoint2D(x: x + point.x * width, y: y + point.y * height).clamped
    }
    func localPoint(from point: UnitPoint2D) -> UnitPoint2D? {
        guard width > 0, height > 0,
              point.x >= x, point.y >= y,
              point.x <= x + width, point.y <= y + height else { return nil }
        return UnitPoint2D(x: (point.x - x) / width, y: (point.y - y) / height).clamped
    }
}

enum ImageGeometry {
    static func aspectFit(imageWidth: Double, imageHeight: Double,
                          boxWidth: Double, boxHeight: Double) -> Rect2D {
        guard imageWidth > 0, imageHeight > 0, boxWidth > 0, boxHeight > 0 else {
            return Rect2D(x: 0, y: 0, width: 0, height: 0)
        }
        let scale = min(boxWidth / imageWidth, boxHeight / imageHeight)
        let w = imageWidth * scale, h = imageHeight * scale
        return Rect2D(x: (boxWidth - w) / 2, y: (boxHeight - h) / 2, width: w, height: h)
    }
    static func unitPoint(x: Double, y: Double, inside rect: Rect2D) -> UnitPoint2D? {
        rect.localPoint(from: UnitPoint2D(x: x, y: y))
    }
    static func outputSize(width: Int, height: Int, longestEdge: Int) -> PixelSize {
        guard width > 0, height > 0, longestEdge > 0 else { return PixelSize(width: 1, height: 1) }
        let scale = min(1, Double(longestEdge) / Double(max(width, height)))
        return PixelSize(width: max(1, Int((Double(width) * scale).rounded())),
                         height: max(1, Int((Double(height) * scale).rounded())))
    }
}
