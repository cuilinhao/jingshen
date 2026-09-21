import Foundation

enum DepthModelChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case v3, v2
    var id: Self { self }
    var title: String { self == .v3 ? "V3 Base（默认）" : "V2 Small（对照）" }
    var resourceName: String { self == .v3 ? "DepthAnythingV3_base_504" : "DepthAnythingV2SmallF16" }
    var modelID: String { self == .v3 ? "DA3Base504-cd96d12b7d14fb92" : "DepthAnythingV2SmallF16-fa60d9b6a155734f" }
    var preprocessingID: String {
        self == .v3 ? "rgb255-letterbox504-inverse-validROI-p01p99-v1" : "rgb255-scaleFill518x392-p01p99-v1"
    }
    var width: Int { self == .v3 ? 504 : 518 }
    var height: Int { self == .v3 ? 504 : 392 }
    func normalize(width: Int, height: Int, values: [Float]) throws -> DepthField {
        guard values.allSatisfy({ $0.isFinite && (self == .v2 || $0 > 0.000001) }) else { throw DepthDataError.noFiniteValues }
        let disparity = self == .v3 ? values.map { 1 / $0 } : values
        return try DepthField.normalizing(width: width, height: height, values: disparity)
    }
}

/// Integer ROI in visual top-left coordinates; use the same ROI before and after inference.
struct DepthInputGeometry: Equatable, Sendable {
    let width: Int, height: Int, contentWidth: Int, contentHeight: Int, left: Int, top: Int
    init(imageSize: PixelSize, width: Int, height: Int, letterbox: Bool = true) {
        self.width = width; self.height = height
        let scale = min(Double(width) / Double(max(1, imageSize.width)), Double(height) / Double(max(1, imageSize.height)))
        contentWidth = letterbox ? max(1, min(width, Int((Double(imageSize.width) * scale).rounded()))) : width
        contentHeight = letterbox ? max(1, min(height, Int((Double(imageSize.height) * scale).rounded()))) : height
        left = (width - contentWidth) / 2; top = (height - contentHeight) / 2
    }
    func unpad(_ values: [Float]) throws -> [Float] {
        guard values.count == width * height else { throw DepthDataError.invalidDimensions }
        var result: [Float] = []; result.reserveCapacity(contentWidth * contentHeight)
        for y in top..<(top + contentHeight) {
            result.append(contentsOf: values[(y * width + left)..<(y * width + left + contentWidth)])
        }
        return result
    }
}
