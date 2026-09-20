import SwiftUI
import UIKit

@MainActor
struct EditorPanel: View {
    let kind: EditorSheet
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        switch kind {
        case .crop: return "裁切"
        case .style: return "色调"
        case .adjustments: return "景深细调"
        case .about: return "关于这个 Demo"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .crop:
                    Section {
                        ForEach(CropRatio.allCases) { crop in
                            Button { model.setCrop(crop) } label: {
                                HStack {
                                    Text(crop.title).foregroundStyle(.white)
                                    Spacer()
                                    if model.recipe.crop == crop { Image(systemName: "checkmark").foregroundStyle(DepthTheme.accent) }
                                }
                            }
                        }
                    } footer: { Text("居中裁切；原图和分析数据保持不变。切回“原始”可恢复完整构图。") }
                case .style:
                    Section {
                        ForEach(PhotoStyle.allCases) { style in
                            Button { model.recipe.style = style } label: {
                                HStack {
                                    Text(style.title).foregroundStyle(.white)
                                    Spacer()
                                    if model.recipe.style == style { Image(systemName: "checkmark").foregroundStyle(DepthTheme.accent) }
                                }
                            }
                        }
                    } footer: { Text("展开面板为 Demo 补充功能，参考录屏没有展示这些面板。") }
                case .adjustments:
                    Section {
                        Picker("模式", selection: $model.recipe.focusMode) {
                            ForEach(FocusMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        Text(model.selectionDescription).font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("选择方式") } footer: {
                        Text("自动模式优先读取照片自带深度；普通照片使用系统主体识别。没有识别结果时明确使用圆形局部虚化，不伪装成景深。")
                    }
                    Section {
                        labeledSlider("效果强度", value: $model.recipe.effectStrength, range: 0...1.5, format: "%.2f")
                        labeledSlider("边缘羽化", value: $model.recipe.edgeFeather, range: 0...6, format: "%.1f")
                        if model.isUsingLocal {
                            labeledSlider("局部清晰范围", value: $model.recipe.localRadius, range: 0.08...0.7, format: "%.2f")
                        } else if model.photo?.analysis.isNative == true {
                            labeledSlider("原生深度清晰范围", value: $model.recipe.focusTolerance, range: 0.01...0.2, format: "%.3f")
                        }
                        labeledSlider("曝光", value: $model.recipe.exposure, range: -1.5...1.5, format: "%+.1f EV")
                    } footer: {
                        Text("边缘羽化用于柔化过渡。模拟光圈不是经过标定的真实镜头参数。透明物体和遮挡边缘可能存在瑕疵。")
                    }
                    Section {
                        Button("恢复细调默认值") {
                            var next = model.recipe
                            next.effectStrength = 1; next.focusTolerance = 0.035; next.exposure = 0
                            next.localRadius = 0.24; next.edgeFeather = 1.2; next.focusMode = .automatic
                            model.recipe = next
                        }
                    }
                case .about:
                    Section("当前照片") {
                        LabeledContent("文件", value: model.photo?.title ?? "尚未加载")
                        LabeledContent("分析来源", value: model.photo?.analysis.sourceDescription ?? "尚未分析")
                        if let photo = model.photo {
                            LabeledContent("处理尺寸", value: "\(photo.original.width) × \(photo.original.height)")
                            switch photo.analysis {
                            case .native(let depth):
                                LabeledContent("原生深度图", value: "\(depth.width) × \(depth.height)")
                            case .subjects(let subjects):
                                LabeledContent("主体 / 组", value: "\(subjects.subjects.count)")
                                if subjects.groupedSubjectCount > 0 { Text("其中 \(subjects.groupedSubjectCount) 个主体按内存预算合并为一组。") }
                            case .localFallback(let reason):
                                Text(reason).font(.footnote)
                            }
                        }
                    }
                    Section("使用") {
                        Text("点主体：保留选中主体清晰；点背景：保留背景清晰，虚化已识别主体。向左拖刻度增大 f 值，虚化减弱；向右则增强。长按照片或点底部双框图标比较原图。")
                        Text("“查看深度 / 虚化蒙版”：原生深度显示亮近暗远；主体和局部模式显示白色虚化、黑色清晰的控制蒙版。")
                        Text("“细调”中可切换到局部虚化、调整清晰范围。系统可能把多个对象识别成一组，不保证每个物体都能单独选中。")
                    }
                    Section("无需下载") {
                        Text("SwiftUI + Vision + Core Image。没有第三方运行 SDK、外部模型文件、自定义着色器或照片上传请求；工程也没有下载构建阶段。")
                        Text("系统主体识别属于苹果系统提供的机器学习能力，并非完全没有模型。照片自带深度时直接读取；没有可用主体时提供不依赖识别的局部虚化。")
                        Text("请用已在本机的照片测试离线处理。仅存在于 iCloud 的照片需要先通过系统下载，这与本 Demo 的分析无关。")
                    }
                    Section("边界与素材") {
                        Text("这是主体分割模拟景深，不是普通照片的完整三维深度预测。无法恢复原片已经失焦的细节，也不能重建被前景遮住的背景。")
                        Text("录屏样片来自视频裁切，不是原始照片，可能已经带有虚化。请导入自己拍摄的清晰照片测试。参考图是录屏画面，不是工程运行截图。")
                        Text("新写 Demo 源码采用 MIT 许可。系统框架由 Apple 提供。内置录屏素材只用于本次私人演示，发布时请替换。")
                    }
                }
            }
            .disabled(kind != .about && !model.controlsEnabled)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .tint(DepthTheme.accent).preferredColorScheme(.dark)
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }.padding(.vertical, 5)
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
