import SwiftUI
import UIKit

enum LayerTool: String, CaseIterable, Identifiable {
    case brush, subject, polygon
    var id: Self { self }
    var title: String {
        switch self {
        case .brush: return "涂抹"
        case .subject: return "点主体"
        case .polygon: return "多边形"
        }
    }
}

@MainActor
final class LayerEditorModel: ObservableObject {
    let subjects: SubjectSegmentation?
    @Published private(set) var history: LayerEditingHistory
    @Published private(set) var overlay: UIImage?
    @Published private(set) var busy = false
    @Published var message = "先标记近景、远景；同一层可以包含多个不相连的物体。"
    @Published var layer: SceneLayer = .near
    @Published var tool: LayerTool = .brush
    @Published var brushRadius: Double = 0.025
    @Published var showOverlay = true
    @Published var polygon: [UnitPoint2D] = []
    private var task: Task<Void, Never>?
    private var generation = 0

    init(scene: LayeredScene) {
        subjects = scene.subjects
        history = LayerEditingHistory(initial: scene.map)
        overlay = (try? LayerOverlay.image(scene.map)).map { UIImage(cgImage: $0) }
        if scene.map.provenance == .reference {
            message = "人工标注验证样例，不是自动识别结果；可继续修改分层。"
        }
    }
    func tap(_ point: UnitPoint2D) {
        guard !busy else { return }
        switch tool {
        case .brush: stroke([point])
        case .polygon:
            guard polygon.count < 512 else { message = "单个多边形最多 512 个顶点"; return }
            polygon.append(point)
        case .subject:
            guard let subject = subjects?.subject(at: point) else {
                message = "这里没有可选轮廓；不会当作远景。请改用涂抹或多边形。"
                return
            }
            let layer = self.layer
            perform { try $0.assigning(mask: subject.mask, to: layer) }
        }
    }
    func stroke(_ points: [UnitPoint2D]) {
        let layer = self.layer, radius = brushRadius
        perform { try $0.painting(points: points, radius: radius, layer: layer) }
    }
    func closePolygon() {
        let points = polygon, layer = self.layer
        guard points.count >= 3 else { message = "至少点三个顶点"; return }
        polygon = []
        perform { try $0.filling(polygon: points, with: layer) }
    }
    func fillRemainingFar() { perform { try $0.fillingUnknown(with: .far) } }
    func clearAll() { perform { try SceneLayerMap.blank(width: $0.labels.width, height: $0.labels.height) } }
    func undo() { guard !busy else { return }; polygon = []; history.undo(); refreshOverlay() }
    func redo() { guard !busy else { return }; polygon = []; history.redo(); refreshOverlay() }
    func cancelPending() { generation += 1; task?.cancel() }

    private func perform(_ operation: @escaping @Sendable (SceneLayerMap) throws -> SceneLayerMap) {
        guard !busy else { return }
        task?.cancel(); generation += 1
        let token = generation, snapshot = history.current
        busy = true
        task = Task {
            let worker = Task.detached(priority: .userInitiated) { try operation(snapshot) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard token == generation else { return }
                history.apply(result)
                overlay = UIImage(cgImage: try LayerOverlay.image(result))
                busy = false
                message = "已标记 \(Int(result.assignedFraction*100))% · 同一颜色属于同一景深层"
            } catch is CancellationError {} catch {
                guard token == generation else { return }
                busy = false; message = error.localizedDescription
            }
        }
    }
    private func refreshOverlay() {
        do { overlay = UIImage(cgImage: try LayerOverlay.image(history.current)) }
        catch { message = error.localizedDescription }
    }
}
