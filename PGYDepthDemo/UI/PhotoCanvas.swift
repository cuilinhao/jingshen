import SwiftUI

@MainActor
struct PhotoCanvas: View {
    @ObservedObject var model: EditorModel
    @GestureState private var holdingOriginal = false

    private var showingOriginal: Bool { holdingOriginal || model.compareOriginal }
    private var image: UIImage? {
        if showingOriginal { return model.originalImage ?? model.previewImage }
        if model.showMask { return model.maskImage ?? model.previewImage }
        return model.previewImage
    }

    var body: some View {
        GeometryReader { proxy in
            let width = Double(image?.size.width ?? 3)
            let height = Double(image?.size.height ?? 4)
            let rect = ImageGeometry.aspectFit(imageWidth: width, imageHeight: height,
                                               boxWidth: Double(proxy.size.width), boxHeight: Double(proxy.size.height))
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(uiImage: image).resizable().interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { event in
                        guard let point = ImageGeometry.unitPoint(x: event.location.x, y: event.location.y, inside: rect) else { return }
                        model.focus(at: point)
                    })
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.25)
                        .updating($holdingOriginal) { current, state, _ in state = current })
                    .accessibilityLabel("照片预览，点击选择焦点，长按比较原图")
                if let point = model.focusInCrop, !showingOriginal, !model.showMask, !model.isPreparing {
                    FocusReticle(pulse: model.focusPulse)
                        .position(x: rect.x + point.x * rect.width, y: rect.y + point.y * rect.height)
                }
                if showingOriginal || model.showMask {
                    Text(showingOriginal ? "原图" : model.diagnosticCaption)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.top, 55).padding(.leading, 10)
                        .allowsHitTesting(false)
                }
                if model.isPreparing || model.isExporting {
                    Color.black.opacity(0.28)
                    VStack(spacing: 12) {
                        ProgressView().tint(DepthTheme.accent)
                        Text(model.isExporting ? "正在导出…" : "正在分析照片…")
                            .font(.system(size: 14, weight: .medium))
                        if model.isPreparing {
                            Text("照片在本机处理，不会上传")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .foregroundStyle(.white).padding(24)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
            .clipped()
        }
    }
}
