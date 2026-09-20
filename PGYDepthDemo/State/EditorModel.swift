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
    @Published private(set) var previewImage: UIImage? = UIImage(named: "DemoSample.jpg")
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
    var isUsingLocal: Bool { recipe.focusMode == .local || photo?.analysis.isFallback == true }
    var banner: String {
        guard let photo else { return "照片在本机处理，无需下载外部模型" }
        if recipe.focusMode == .local { return "局部虚化模式，启用圆形清晰选区" }
        switch photo.analysis {
        case .native: return "该图像包含景深数据，启用原生景深"
        case .subjects: return "该图像无景深数据，启用系统主体虚化"
        case .localFallback: return "未识别到主体，当前使用局部虚化"
        }
    }
    var diagnosticCaption: String {
        photo?.analysis.isNative == true && !isUsingLocal
        ? "原生相对深度 · 亮近暗远" : "虚化蒙版 · 白色虚化 / 黑色清晰"
    }
    var selectionDescription: String {
        guard let photo else { return "尚未加载照片" }
        if isUsingLocal { return "圆形选区内清晰，周围虚化" }
        switch photo.analysis {
        case .native(let field): return String(format: "原生相对深度 %.3f", field.sample(at: recipe.focusPoint))
        case .subjects(let subjects):
            return subjects.instance(at: recipe.focusPoint) == 0 ? "背景清晰 · 前景主体虚化" : "选中主体清晰 · 其他区域虚化"
        case .localFallback: return "局部虚化（未识别主体）"
        }
    }
    var focusInCrop: UnitPoint2D? {
        guard let photo else { return nil }
        return recipe.crop.unitRect(imageWidth: photo.original.width, imageHeight: photo.original.height)
            .localPoint(from: recipe.focusPoint)
    }

    func start() async {
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
        guard let url = Bundle.main.url(forResource: "DemoSample", withExtension: "jpg") else {
            errorMessage = "工程内缺少 DemoSample.jpg，请检查 Copy Bundle Resources。"
            return
        }
        importFile(url, title: "录屏裁切样片")
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
        isRendering = false
        compareOriginal = false
        showMask = false
        importTask = Task {
            do {
                let data = try await load()
                try Task.checkCancellation()
                let prepared = try await pipeline.prepare(data: data, title: title,
                                                          cachedAnalysis: cachedAnalysis, cachedImageSize: cachedImageSize)
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
        recipe.focusPoint = crop.originalPoint(from: pointInDisplayedCrop)
        focusPulse += 1
        UISelectionFeedbackGenerator().selectionChanged()
        print("[Focus] normalized=\(recipe.focusPoint)，\(selectionDescription)")
        showToast(selectionDescription)
    }

    func retryAnalysis() {
        guard let photo, controlsEnabled else { return }
        var next = recipe; next.focusMode = .automatic
        beginImport(title: photo.title, restored: next) { photo.sourceData }
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
