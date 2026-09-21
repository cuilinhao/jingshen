import Foundation
import SwiftUI
import PhotosUI
import Photos
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var recipe = EditRecipe() {
        didSet {
            guard !applyingSnapshot, recipe != oldValue else { return }
            recipe.sanitize()
            schedulePreview()
            scheduleDraft()
        }
    }
    @Published private(set) var previewImage: UIImage? = UIImage(named: "ReferencePhoto.png")
    @Published private(set) var originalImage: UIImage?
    @Published private(set) var maskImage: UIImage?
    @Published private(set) var photo: PhotoSession?
    @Published private(set) var isPreparing = false
    @Published private(set) var isRendering = false
    @Published private(set) var isExporting = false
    @Published private(set) var focusPulse = 0
    @Published var compareOriginal = false
    @Published var showMask = false
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var sharePayload: SharePayload?

    private let pipeline = PhotoPipeline()
    private let draftStore = DraftStore()
    private var importTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var importGeneration = 0
    private var renderGeneration = 0
    private var applyingSnapshot = false
    private var started = false

    var controlsEnabled: Bool { photo != nil && !isPreparing && !isExporting }
    var isUsingLocal: Bool { recipe.focusMode == .local }
    var layeredScene: LayeredScene? {
        guard let photo, case .layered(let scene) = photo.analysis else { return nil }
        return scene
    }
    var banner: String {
        if isPreparing { return "正在生成离线自动深度，请稍候…" }
        guard let photo else { return "v4 内置完整模型 · 本机自动深度" }
        if recipe.focusMode == .local { return "局部虚化模式，启用圆形清晰选区" }
        switch photo.analysis {
        case .native: return "该图像包含景深数据，启用原生景深"
        case .estimated: return "已生成离线自动深度，启用景深虚化"
        case .layered(let scene):
            if scene.map.provenance == .reference { return "人工分层样例 · 同一景深层一起清晰" }
            if scene.map.knownLayers.isEmpty { return "未建立景深分层 · 点击此处标记" }
            return "景深分层虚化 · 同层清晰 · 可点击校正"
        case .subjects, .localFallback: return "请先确认景深分层"
        }
    }
    var diagnosticCaption: String {
        photo?.analysis.continuousDepth != nil && !isUsingLocal
        ? "相对深度 · 亮近暗远 · 非测距" : "虚化蒙版 · 白色虚化 / 黑色清晰"
    }
    var selectionDescription: String {
        guard let photo else { return "尚未加载照片" }
        if isUsingLocal { return "圆形选区内清晰，周围虚化" }
        switch photo.analysis {
        case .native(let field): return String(format: "原生相对深度 %.3f · 同范围清晰", field.sample(at: recipe.focusPoint))
        case .estimated(let estimated):
            return String(format: "相对深度 %.3f · 清晰范围 ±%.2f", estimated.field.sample(at: recipe.focusPoint), recipe.focusTolerance)
        case .layered(let scene):
            let layer = scene.map.layer(at: recipe.focusPoint)
            if layer == .unknown { return "此处未标记景深，请先进行分层校正" }
            return "\(layer.title)整层清晰 · 其他已标记层虚化"
        case .subjects, .localFallback: return "尚未确认景深，不把未知区域当成远景"
        }
    }
    var focusInCrop: UnitPoint2D? {
        guard let photo else { return nil }
        if !isUsingLocal, case .layered(let scene) = photo.analysis, scene.map.layer(at: recipe.focusPoint) == .unknown { return nil }
        return recipe.crop.unitRect(imageWidth: photo.original.width, imageHeight: photo.original.height)
            .localPoint(from: recipe.focusPoint)
    }

    func start() async {
        // TestAction alone sets this flag; avoid unrelated automatic UI inference during tests.
        guard ProcessInfo.processInfo.environment["PGY_SKIP_UI_STARTUP_FOR_TESTS"] != "1" else { return }
        guard !started else { return }
        started = true
        let token = importGeneration
        do {
            let saved = try await draftStore.load()
            guard token == importGeneration else { return }
            if let saved {
                open(data: saved.sourceData, title: saved.title, restored: saved.recipe,
                     cachedAnalysis: saved.analysis, cachedImageSize: saved.imageSize)
            } else {
                loadSample()
            }
        } catch {
            print("[Draft] 无法恢复草稿，保留磁盘数据并加载样片：\(error.localizedDescription)")
            guard token == importGeneration else { return }
            loadSample()
            showToast("草稿读取失败，已改为打开内置样片")
        }
    }

    func loadSample() {
        let pipeline = self.pipeline
        // The bundled original uses exactly the same estimator as a file/photo import.
        // No hand-authored mask or precomputed prediction is injected here.
        beginImport(title: "yuntu0920 · 自动深度原图") {
            guard let url = Bundle.main.url(forResource: "ReferencePhoto", withExtension: "png") else {
                throw ImagingError.unreadableImage
            }
            return try await pipeline.readFile(url)
        }
    }

    func importPickedPhoto(_ item: PhotosPickerItem) {
        beginImport(title: "相册照片") {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw ImagingError.unreadableImage }
            return data
        }
    }

    func importFile(_ url: URL, title: String? = nil) {
        let pipeline = self.pipeline
        beginImport(title: title ?? url.lastPathComponent) {
            try await pipeline.readFile(url)
        }
    }

    private func open(data: Data, title: String, restored: EditRecipe,
                      cachedAnalysis: PhotoAnalysis?, cachedImageSize: PixelSize?) {
        beginImport(title: title, restored: restored, cachedAnalysis: cachedAnalysis, cachedImageSize: cachedImageSize) { data }
    }

    private func beginImport(title: String, restored: EditRecipe = EditRecipe(),
                             cachedAnalysis: PhotoAnalysis? = nil, cachedImageSize: PixelSize? = nil,
                             load: @escaping () async throws -> Data) {
        importGeneration += 1
        let token = importGeneration
        importTask?.cancel()
        previewTask?.cancel()
        saveTask?.cancel()
        renderGeneration += 1
        isPreparing = true
        errorMessage = nil
        toastTask?.cancel(); toast = nil
        isRendering = false
        compareOriginal = false
        showMask = false
        importTask = Task {
            do {
                let data = try await load()
                try Task.checkCancellation()
                let prepared = try await pipeline.prepare(data: data, title: title,
                                                          cachedAnalysis: cachedAnalysis,
                                                          cachedImageSize: cachedImageSize)
                var initial = restored
                initial.sanitize()
                let crop = initial.crop.unitRect(imageWidth: prepared.original.width, imageHeight: prepared.original.height)
                if crop.localPoint(from: initial.focusPoint) == nil { initial.focusPoint = crop.center }
                let result = try await pipeline.preview(photo: prepared, recipe: initial)
                guard !Task.isCancelled, token == importGeneration else { return }
                applyingSnapshot = true
                recipe = initial
                applyingSnapshot = false
                photo = prepared
                apply(result)
                isPreparing = false
                focusPulse += 1
                if let notice = prepared.notice { showToast(notice) }
                scheduleDraft()
                print("[Editor] 新照片就绪：\(title)，export=\(prepared.original.width)×\(prepared.original.height)")
            } catch is CancellationError {
                // A later import owns the state; never clear its busy indicator.
            } catch {
                guard token == importGeneration else { return }
                isPreparing = false
                errorMessage = error.localizedDescription
                // Preserve the last successfully opened photo on a failed import.
                if photo != nil { schedulePreview(delay: 0) }
                print("[Editor] 导入失败：\(error)")
            }
        }
    }

    func focus(at pointInDisplayedCrop: UnitPoint2D) {
        guard let photo, controlsEnabled else { return }
        let crop = recipe.crop.unitRect(imageWidth: photo.original.width, imageHeight: photo.original.height)
        let point = crop.originalPoint(from: pointInDisplayedCrop)
        if !isUsingLocal, case .layered(let scene) = photo.analysis, scene.map.layer(at: point) == .unknown {
            print("[Focus] 未标记区域 normalized=\(point)；拒绝把 unknown 当成 background")
            showToast("此处尚未标记远近，点上方状态条或调整 → 分层校正")
            return
        }
        recipe.focusPoint = point
        focusPulse += 1
        UISelectionFeedbackGenerator().selectionChanged()
        print("[Focus] normalized=\(recipe.focusPoint)，\(selectionDescription)")
        showToast(selectionDescription)
    }

    func retryAnalysis() {
        guard let photo, controlsEnabled else { return }
        // Intentionally omit cachedAnalysis. This also repairs v1-v3/invalid cached drafts.
        let data = photo.sourceData
        beginImport(title: photo.title, restored: recipe) { data }
    }

    func commitLayers(_ map: SceneLayerMap, for sourceID: UUID) {
        guard let photo, photo.id == sourceID, controlsEnabled, case .layered(let scene) = photo.analysis else {
            showToast("照片已更换，未把旧选区应用到新照片")
            return
        }
        self.photo = photo.replacingAnalysis(.layered(LayeredScene(map: map, subjects: scene.subjects, notice: scene.notice)))
        // Updating the map changes session ID even when the focus point is unchanged.
        // Re-render and re-save explicitly; a recipe didSet alone is NOT enough.
        if map.layer(at: recipe.focusPoint) == .unknown,
           let layer = map.knownLayers.last, let point = map.firstPoint(in: layer) {
            recipe.focusPoint = point
        }
        schedulePreview(delay: 0); scheduleDraft()
        print("[Layers] 已应用分层 known=\(map.knownLayers.map(\.title)) coverage=\(map.assignedFraction)，缓存已失效")
        showToast("分层已更新；同一层的所有区域一起清晰")
    }

    func setAperture(_ value: Double) {
        guard controlsEnabled else { return }
        recipe.aperture = (Aperture.clamp(value) * 10).rounded() / 10
    }

    func setCrop(_ crop: CropRatio) {
        guard let photo else { return }
        var next = recipe
        next.crop = crop
        let rect = crop.unitRect(imageWidth: photo.original.width, imageHeight: photo.original.height)
        if rect.localPoint(from: next.focusPoint) == nil { next.focusPoint = rect.center }
        recipe = next
    }

    func reset() {
        var next = EditRecipe()
        next.focusPoint = .center
        recipe = next
        compareOriginal = false
        showMask = false
        showToast("已重置编辑参数")
    }

    private func schedulePreview(delay: UInt64 = 28_000_000) {
        guard let photo, !isPreparing else { return }
        previewTask?.cancel()
        renderGeneration += 1
        let token = renderGeneration
        let snapshot = recipe
        isRendering = true
        previewTask = Task {
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                let result = try await pipeline.preview(photo: photo, recipe: snapshot)
                guard !Task.isCancelled, token == renderGeneration, self.photo?.id == photo.id else { return }
                apply(result)
                isRendering = false
            } catch is CancellationError {
                // Newest render wins. Expensive native filters cannot be interrupted mid-GPU command.
            } catch {
                guard token == renderGeneration else { return }
                isRendering = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ result: PreviewResult) {
        previewImage = UIImage(cgImage: result.rendered)
        originalImage = UIImage(cgImage: result.original)
        maskImage = UIImage(cgImage: result.mask)
    }

    private func scheduleDraft() {
        guard let photo, !isPreparing else { return }
        saveTask?.cancel()
        let snapshot = recipe
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                try await draftStore.save(photo.draft(recipe: snapshot))
            } catch is CancellationError {
            } catch {
                print("[Draft] 自动保存失败：\(error.localizedDescription)")
                showToast("草稿未保存，请检查存储空间")
            }
        }
    }

    func saveDraft(showMessage: Bool = true) {
        guard let photo, !isPreparing else { return }
        saveTask?.cancel()
        let snapshot = recipe
        saveTask = Task {
            do {
                try await draftStore.save(photo.draft(recipe: snapshot))
                if showMessage { showToast("可编辑草稿已保存") }
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func export(toAlbum: Bool) {
        guard let photo, controlsEnabled else { return }
        let snapshot = recipe
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let output = try await pipeline.export(photo: photo, recipe: snapshot)
                if toAlbum {
                    try await PhotoExport.saveToAlbum(output.jpeg)
                    showToast("已保存到相册 · \(output.image.width)×\(output.image.height)")
                } else {
                    let url = try await pipeline.writeTemporaryJPEG(output.jpeg)
                    sharePayload = SharePayload(url: url)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func cleanupShare(_ url: URL) {
        Task { await pipeline.removeTemporaryFile(url) }
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}

private enum PhotoExport {
    static func saveToAlbum(_ data: Data) async throws {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in continuation.resume(returning: status) }
        }
        guard status == .authorized || status == .limited else { throw ImagingError.deniedPhotoPermission }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: ImagingError.cannotRender) }
            })
        }
    }
}
