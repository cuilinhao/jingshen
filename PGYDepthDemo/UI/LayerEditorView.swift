import SwiftUI
import UIKit

@MainActor
struct LayerEditorView: View {
    let photoID: UUID
    let image: UIImage
    let onApply: (SceneLayerMap, UUID) -> Void
    @StateObject private var editor: LayerEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFill = false
    @State private var showClear = false

    init(photo: PhotoSession, scene: LayeredScene, onApply: @escaping (SceneLayerMap, UUID) -> Void) {
        self.photoID = photo.id; self.image = UIImage(cgImage: photo.preview); self.onApply = onApply
        _editor = StateObject(wrappedValue: LayerEditorModel(scene: scene))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(editor.message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal)
                    .frame(minHeight: 32)
                ZStack {
                    LayerDrawingCanvas(image: image, overlay: editor.showOverlay ? editor.overlay : nil,
                                       tool: editor.tool, layer: editor.layer, radius: editor.brushRadius,
                                       polygon: editor.polygon, enabled: !editor.busy,
                                       onTap: editor.tap, onStroke: editor.stroke)
                    if editor.busy { ProgressView("更新分层…").padding().background(.black.opacity(0.75),in: Capsule()) }
                }.frame(maxHeight: .infinity)
                Text("双指缩放 / 移动 · 单指编辑 · 原图坐标保存，裁切不改变分层")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                controls.padding(.horizontal).padding(.bottom,8)
            }
            .background(.black)
            .navigationTitle("景深分层校正").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editor.cancelPending(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { onApply(editor.history.current,photoID); dismiss() }
                        .disabled(editor.busy || !editor.polygon.isEmpty)
                }
            }
            .confirmationDialog("把所有未标记区域设为远景？",isPresented: $showFill,titleVisibility: .visible) {
                Button("确认：未标记区域全部设为远景") { editor.fillRemainingFar() }
                Button("取消",role: .cancel) {}
            } message: { Text("这是你的手动判断，不是自动识别。漏标的瓶子等也会变为远景，可随后用涂抹/多边形改回近景。") }
            .confirmationDialog("清空这张照片的分层？",isPresented: $showClear,titleVisibility: .visible) {
                Button("清空分层",role: .destructive) { editor.clearAll() }
                Button("取消",role: .cancel) {}
            } message: { Text("仅清空当前编辑副本，不删除原图。应用前可撤销，也可以取消退出。") }
            .onChange(of: editor.tool) { _, _ in editor.polygon = [] }
            .onDisappear { editor.cancelPending() }
        }.preferredColorScheme(.dark).tint(DepthTheme.accent)
    }
    private var controls: some View {
        VStack(spacing: 12) {
            Picker("当前景深层",selection: $editor.layer) {
                ForEach([SceneLayer.near,.middle,.far,.unknown]) { layer in
                    Text(layer == .unknown ? "擦除标记" : layer.title).tag(layer)
                }
            }.pickerStyle(.segmented)
            HStack(spacing: 14) {
                legend("近景",.near); legend("中景",.middle); legend("远景",.far)
                Spacer()
                Text("\(Int(editor.history.current.assignedFraction*100))% 已标记").font(.caption2).monospacedDigit()
            }
            Picker("工具",selection: $editor.tool) {
                ForEach(LayerTool.allCases) { tool in Text(tool.title).tag(tool) }
            }.pickerStyle(.segmented)
            if editor.tool == .brush {
                HStack {
                    Text("笔刷").font(.caption)
                    Slider(value: $editor.brushRadius,in: 0.003...0.12)
                    Text("\(Int(editor.brushRadius*200))%").font(.caption).monospacedDigit().frame(width: 36)
                }
            } else if editor.tool == .polygon {
                HStack {
                    Text("\(editor.polygon.count) 个顶点").font(.caption)
                    Spacer()
                    Button("退一个点") { if !editor.polygon.isEmpty { editor.polygon.removeLast() } }.disabled(editor.polygon.isEmpty)
                    Button("闭合并填充") { editor.closePolygon() }.disabled(editor.polygon.count < 3)
                }.font(.caption)
            } else {
                Text(editor.subjects == nil ? "没有可用主体轮廓，请改用涂抹或多边形。" : "点一个主体，将其整体归入当前层；多个主体可以归入同一层。")
                    .font(.caption2).foregroundStyle(.secondary).frame(height: 30)
            }
            HStack {
                Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!editor.history.canUndo)
                Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!editor.history.canRedo)
                Spacer()
                Button { editor.showOverlay.toggle() } label: { Image(systemName: editor.showOverlay ? "eye" : "eye.slash") }
                Menu("批量") {
                    Button("未标记区域设为远景…") { showFill = true }
                    Button("清空分层…",role: .destructive) { showClear = true }
                }
            }.buttonStyle(.bordered)
        }.disabled(editor.busy)
    }
    private func legend(_ title: String,_ layer: SceneLayer) -> some View {
        HStack(spacing: 4) {
            Circle().fill(Color(uiColor: LayerDrawingCanvas.color(layer))).frame(width: 7,height: 7)
            Text(title).font(.caption2)
        }
    }
}
