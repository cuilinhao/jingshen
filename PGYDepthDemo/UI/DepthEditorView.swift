import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum EditorSheet: String, Identifiable { case crop, style, adjustments, about; var id: Self { self } }

@MainActor
struct DepthEditorView: View {
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showImportMenu = false
    @State private var showExportMenu = false
    @State private var activeSheet: EditorSheet?

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 402, proxy.size.height / 874)
            referenceCanvas
                .frame(width: 402, height: 874)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: 402 * scale, height: 874 * scale, alignment: .topLeading)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(.black).ignoresSafeArea()
        .preferredColorScheme(.dark).tint(DepthTheme.accent)
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .task { await model.start() }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: selectedPhoto) { _, item in
            if let item { model.importPickedPhoto(item); selectedPhoto = nil }
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.jpeg, .png, .heic], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importFile(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog("更换照片", isPresented: $showImportMenu, titleVisibility: .visible) {
            Button("从相册导入") { showPhotoPicker = true }
            Button("从文件导入") { showFilePicker = true }
            Button("打开原图并自动计算深度") { model.loadSample() }
            Button("取消", role: .cancel) {}
        } message: { Text("当前照片会自动保存为可编辑草稿；Demo 仅保留最近一张照片。") }
        .confirmationDialog("导出照片", isPresented: $showExportMenu, titleVisibility: .visible) {
            Button("保存到相册") { model.export(toAlbum: true) }
            Button("分享图片 / 存储到文件") { model.export(toAlbum: false) }
            Button("保存可编辑草稿") { model.saveDraft() }
            Button("取消", role: .cancel) {}
        } message: { Text("JPEG · sRGB · 最长边 2048 像素，不放大小图。对焦框和界面不会进入导出图片。") }
        .sheet(item: $activeSheet) { sheet in
            EditorPanel(kind: sheet, model: model)
                .presentationDetents(sheet == .about ? [.large] : [.height(390), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $model.sharePayload) { payload in
            ActivitySheet(url: payload.url) { model.cleanupShare(payload.url) }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil },
                                                 set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveDraft(showMessage: false) }
        }
    }

    private var referenceCanvas: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Color(white: 0.035).frame(width: 402, height: 44)
            Color(white: 0.035).frame(width: 402, height: 43).offset(y: 831)

            PhotoCanvas(model: model).frame(width: 388, height: 518).offset(x: 7, y: 62)

            ReferenceCircleButton(action: { showImportMenu = true }) {
                Image(systemName: "arrow.left").font(.system(size: 20, weight: .regular))
            }.offset(x: 5, y: 67).disabled(model.isExporting)
                .accessibilityLabel("返回 / 更换照片")

            Menu {
                Button { showPhotoPicker = true } label: { Label("从相册导入", systemImage: "photo") }
                Button { showFilePicker = true } label: { Label("从文件导入", systemImage: "folder") }
                Divider()
                Button { model.showMask.toggle() } label: {
                    Label(model.showMask ? "关闭蒙版预览" : "查看深度 / 虚化蒙版", systemImage: "square.3.layers.3d")
                }.disabled(!model.controlsEnabled)
                Button { model.retryAnalysis() } label: { Label("重新计算自动深度", systemImage: "arrow.clockwise") }
                    .disabled(!model.controlsEnabled)
                Button { model.saveDraft() } label: { Label("保存可编辑草稿", systemImage: "square.and.arrow.down") }
                    .disabled(!model.controlsEnabled)
                Button { model.reset() } label: { Label("重置编辑", systemImage: "arrow.counterclockwise") }
                    .disabled(!model.controlsEnabled)
                Button { model.loadSample() } label: { Label("打开原图并自动计算深度", systemImage: "photo.on.rectangle") }
                Divider()
                Button { activeSheet = .about } label: { Label("实现说明 / 离线说明", systemImage: "info.circle") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(DepthTheme.panel, in: Circle())
            }.offset(x: 353, y: 67).disabled(model.isExporting)
                .accessibilityLabel("更多")

            HStack(spacing: 4) {
                if model.toast == nil {
                    if model.isRendering { ProgressView().controlSize(.mini).scaleEffect(0.65) }
                    else { Image(systemName: "hand.tap").font(.system(size: 12, weight: .light)) }
                }
                Text(model.toast ?? "点击屏幕调整对焦点")
                    .font(.system(size: model.toast == nil ? 9 : 10, weight: .regular))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(model.toast == nil ? Color(white: 0.25) : DepthTheme.muted)
            .frame(width: 388, height: 26).offset(x: 7, y: 584)

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Text(model.banner).font(.system(size: 11.2, weight: .semibold))
                    .foregroundStyle(DepthTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
                    .contentShape(Rectangle())
                    .onTapGesture { activeSheet = .about }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("查看深度来源与离线模型信息")
                DepthToggle(enabled: $model.recipe.depthEnabled)
                    .disabled(!model.controlsEnabled)
            }
            .padding(.horizontal, 8).frame(width: 392, height: 49)
            .background(DepthTheme.panel, in: Capsule()).offset(x: 5, y: 621)

            ApertureRuler(value: model.recipe.aperture, isEnabled: model.controlsEnabled,
                          onChange: model.setAperture).offset(x: 10, y: 695)

            HStack(spacing: 0) {
                toolButton(label: "裁切", action: { activeSheet = .crop }) {
                    Image(systemName: "crop").font(.system(size: 19, weight: .light))
                }
                toolButton(label: "景深光圈", action: {
                    model.showMask = false; model.compareOriginal = false
                }) {
                    Text("ƒ").font(.system(size: 24, weight: .regular)).foregroundStyle(DepthTheme.accent)
                }
                toolButton(label: "色调", action: { activeSheet = .style }) { ColorCirclesIcon() }
                toolButton(label: "调整", action: { activeSheet = .adjustments }) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .regular))
                }
                toolButton(label: model.compareOriginal ? "返回效果图" : "原图对比", action: {
                    model.compareOriginal.toggle()
                }) { CompareIcon().foregroundStyle(model.compareOriginal ? DepthTheme.accent : .white) }
            }
            .frame(width: 317, height: 60).background(DepthTheme.panel, in: Capsule())
            .offset(x: 5, y: 766).disabled(!model.controlsEnabled)

            ReferenceCircleButton(size: 60, action: { showExportMenu = true }) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 21, weight: .regular))
            }.offset(x: 337, y: 766).disabled(!model.controlsEnabled)
                .accessibilityLabel("导出照片")
        }
        .environment(\.sizeCategory, .large)
    }

    private func toolButton<Content: View>(label: String, action: @escaping () -> Void,
                                          @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content().foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 60)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}
