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
                        Text("自动模式优先读取照片自带深度；普通照片使用内置模型估计相对深度。点击照片选择清晰的深度层；景深分析不可用时使用圆形局部虚化。")
                    }
                    Section {
                        labeledSlider("效果强度", value: $model.recipe.effectStrength, range: 0...1.5, format: "%.2f")
                        labeledSlider("边缘羽化", value: $model.recipe.edgeFeather, range: 0...6, format: "%.1f")
                        if model.isUsingLocal {
                            labeledSlider("局部清晰范围", value: $model.recipe.localRadius, range: 0.08...0.7, format: "%.2f")
                        } else if model.photo?.analysis.isEstimated == true {
                            labeledSlider("清晰深度范围", value: $model.recipe.estimatedFocusTolerance, range: 0.02...0.30, format: "%.3f")
                        } else if model.photo?.analysis.depthField != nil {
                            labeledSlider("清晰深度范围", value: $model.recipe.focusTolerance, range: 0.01...0.2, format: "%.3f")
                        }
                        labeledSlider("曝光", value: $model.recipe.exposure, range: -1.5...1.5, format: "%+.1f EV")
                    } footer: {
                        Text("清晰深度范围越大，焦点附近越多深度层保持清晰；同一深度层的物体会一起保持清晰。边缘羽化用于柔化过渡，模拟光圈不代表经过标定的真实镜头参数。")
                    }
                    Section {
                        Button("恢复细调默认值") {
                            var next = model.recipe
                            next.effectStrength = 1; next.focusTolerance = 0.035; next.exposure = 0
                            next.estimatedFocusTolerance = 0.18
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
                            case .estimated(let estimate):
                                LabeledContent("AI 估计深度图", value: "\(estimate.field.width) × \(estimate.field.height)")
                                LabeledContent("估计模型", value: "DepthAnythingV2SmallF16")
                            case .subjects(let subjects):
                                LabeledContent("主体 / 组", value: "\(subjects.subjects.count)")
                                if subjects.groupedSubjectCount > 0 { Text("其中 \(subjects.groupedSubjectCount) 个主体按内存预算合并为一组。") }
                            case .localFallback(let reason):
                                Text(reason).font(.footnote)
                            }
                        }
                    }
                    Section("使用") {
                        Text("点击照片选择焦点深度：与焦点处在同一深度层的区域保持清晰，更近和更远的区域逐渐虚化。向左拖刻度增大 f 值，虚化减弱；向右则增强。长按照片或点底部双框图标比较原图。")
                        Text("“查看深度 / 虚化蒙版”：原生与 AI 估计深度均显示亮近暗远的相对深度，不是以米为单位的距离；旧版主体和局部模式显示白色虚化、黑色清晰的控制蒙版。")
                        Text("“景深细调”中可调整清晰深度范围，或切换到圆形局部虚化。旧版主体模式保留按主体选择的行为，可通过“重新分析景深”更新分析。")
                    }
                    Section("模型与本机处理") {
                        Text("工程内置 DepthAnythingV2SmallF16 Core ML 模型。照片分析在本机运行，不上传照片，也不联网下载分析模型。")
                        Text("Depth Anything V2 Small 模型采用 Apache-2.0 许可，Core ML 转换版本由 Apple 发布。")
                        NavigationLink("查看模型许可证") {
                            ScrollView {
                                Text(modelLicense).font(.footnote).textSelection(.enabled).padding()
                            }.navigationTitle("Apache-2.0")
                        }
                        Text("照片自带可用深度时读取原生深度；普通照片使用 AI 估计连续的相对深度。界面会明确标注两种来源，估计结果并非相机测量值。")
                        Text("请用已在本机的照片测试离线处理。仅存在于 iCloud 的照片需要先通过系统下载，这与本 Demo 的分析无关。")
                    }
                    Section("边界与素材") {
                        Text("AI 相对深度可能判断错误，透明物体、反射表面、细发和遮挡边缘尤其容易出现瑕疵。无法恢复原片已经失焦的细节，也不能重建被前景遮住的背景。")
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

    private var modelLicense: String {
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Depth Anything V2 Small — Apache License 2.0。完整许可请参阅工程中的 Docs/DepthAnythingV2-LICENSE.txt。"
        }
        return text
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
