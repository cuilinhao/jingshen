import Foundation

/// Independent soft person masks. Instance IDs are scoped to this exact analysis, never depth.
struct PortraitAnalysis: Codable, Equatable, Sendable {
    static let currentSegmentationID = "vision-person-instance-r1-2048-v1"
    var segmentationID: String
    let segmentation: SubjectSegmentation
    let sourceSHA256: String
    let imageSize: PixelSize

    init(segmentation: SubjectSegmentation, sourceSHA256: String, imageSize: PixelSize) throws {
        guard (1...4).contains(segmentation.subjects.count), segmentation.groupedSubjectCount == 0,
              sourceSHA256.count == 64, imageSize.width > 0, imageSize.height > 0 else {
            throw MaskDataError.inconsistentSubjects
        }
        self.segmentation = segmentation; self.sourceSHA256 = sourceSHA256; self.imageSize = imageSize
        segmentationID = Self.currentSegmentationID
    }
    private enum CodingKeys: String, CodingKey { case segmentationID, segmentation, sourceSHA256, imageSize }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(segmentation: box.decode(SubjectSegmentation.self, forKey: .segmentation),
                      sourceSHA256: box.decode(String.self, forKey: .sourceSHA256),
                      imageSize: box.decode(PixelSize.self, forKey: .imageSize))
        segmentationID = try box.decode(String.self, forKey: .segmentationID)
    }
    func matches(sourceSHA256: String, imageSize: PixelSize) -> Bool {
        self.sourceSHA256 == sourceSHA256 && self.imageSize == imageSize &&
            segmentationID == Self.currentSegmentationID
    }
    func person(id: UInt8?) -> SubjectMask? {
        guard let id else { return nil }
        return segmentation.subjects.first { $0.id == id }
    }
    func selectedPerson(at point: UnitPoint2D, currentID: UInt8?) -> UInt8? {
        // Permit soft hair edges, but never select an arbitrarily distant person on a blank tap.
        if let hit = segmentation.subjects.filter({ $0.mask.value(at: point) >= 64 })
            .max(by: { $0.mask.value(at: point) < $1.mask.value(at: point) }) { return hit.id }
        return person(id: currentID)?.id
    }
    func restoringSelection(in recipe: EditRecipe, cacheReused: Bool) -> EditRecipe {
        var result = recipe
        let id: UInt8?
        if recipe.selectedPersonID != nil {
            if cacheReused, let person = person(id: recipe.selectedPersonID) { id = person.id }
            else { id = selectedPerson(at: recipe.focusPoint, currentID: nil) }
        } else { id = nil }
        result.selectedPersonID = id ?? primaryPerson?.id
        if recipe.focusMode == .automatic, let selected = person(id: result.selectedPersonID), selected.mask.value(at: result.focusPoint) < 64 {
            result.focusPoint = anchor(for: selected.id) ?? result.focusPoint
        }
        return result
    }
    var primaryPerson: SubjectMask? {
        segmentation.subjects.max { a, b in
            a.mask.bytes.reduce(UInt64(0)) { $0 + UInt64($1) } < b.mask.bytes.reduce(UInt64(0)) { $0 + UInt64($1) }
        }
    }
    func anchor(for id: UInt8) -> UnitPoint2D? {
        guard let mask = person(id: id)?.mask else { return nil }
        var sx = 0.0, sy = 0.0, weight = 0.0
        let step = max(1, max(mask.width, mask.height) / 128)
        for y in stride(from: 0, to: mask.height, by: step) {
            for x in stride(from: 0, to: mask.width, by: step) {
                let w = Double(mask.bytes[y * mask.width + x])
                if w >= 224 { sx += Double(x) * w; sy += Double(y) * w; weight += w }
            }
        }
        guard weight > 0 else { return nil }
        let center = UnitPoint2D(x: sx / weight / Double(max(1, mask.width - 1)),
                                y: sy / weight / Double(max(1, mask.height - 1)))
        // A centroid may fall into the gap between arms. Snap to this person's nearest core.
        var closest: UnitPoint2D?, best = Double.infinity
        for y in stride(from: 0, to: mask.height, by: step) {
            for x in stride(from: 0, to: mask.width, by: step) where mask.bytes[y * mask.width + x] >= 224 {
                let p = UnitPoint2D(x: Double(x) / Double(max(1, mask.width - 1)), y: Double(y) / Double(max(1, mask.height - 1)))
                let d = pow(p.x - center.x, 2) + pow(p.y - center.y, 2)
                if d < best { closest = p; best = d }
            }
        }
        return closest
    }
    func focusDepth(depth: DepthField, selectedID: UInt8, point: UnitPoint2D) -> Float {
        guard let mask = person(id: selectedID)?.mask else { return depth.sample(at: point) }
        var all: [Float] = [], local: [Float] = []
        let step = max(1, max(depth.width, depth.height) / 128)
        for y in stride(from: 0, to: depth.height, by: step) {
            for x in stride(from: 0, to: depth.width, by: step) {
                let p = UnitPoint2D(x: Double(x) / Double(max(1, depth.width - 1)), y: Double(y) / Double(max(1, depth.height - 1)))
                guard mask.value(at: p) >= 224 else { continue }
                let z = depth.values[y * depth.width + x]
                all.append(z)
                if abs(p.x - point.x) < 0.05 && abs(p.y - point.y) < 0.05 { local.append(z) }
            }
        }
        var values = local.isEmpty ? all : local
        guard !values.isEmpty else { return depth.sample(at: point) }
        values.sort(); return values[values.count / 2]
    }
    func layers(depth: DepthField, selectedID: UInt8, focusPoint: UnitPoint2D) -> [PortraitLayer] {
        let focus = focusDepth(depth: depth, selectedID: selectedID, point: focusPoint)
        return segmentation.subjects.map { subject in
            let z = focusDepth(depth: depth, selectedID: subject.id, point: anchor(for: subject.id) ?? .center)
            let amount = subject.id == selectedID ? Float(0) : max(0.65, DepthMath.smoothstep(0.04, 0.5, abs(z - focus)))
            return PortraitLayer(subject: subject, depth: z, blurAmount: amount)
        }.sorted { a, b in
            if a.depth == b.depth {
                if a.subject.id == selectedID { return false }
                if b.subject.id == selectedID { return true }
                return a.subject.id < b.subject.id
            }
            return a.depth < b.depth // Far first; defocused foreground still occludes a selected person.
        }
    }
}

struct PortraitLayer: Sendable {
    let subject: SubjectMask
    let depth: Float
    let blurAmount: Float
}
