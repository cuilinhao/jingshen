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
                        Text(model.isUsingPortrait
                             ? "点击人物保留其细节，同一距离的其他人也会虚化。背景按相对远近过渡；前景人物仍可遮挡后景人物。"
                             : "优先读取照片自带深度；普通照片由内置模型估计远近。未识别到独立人物时，按清晰深度范围虚化；局部模式使用圆形选区。")
                    }
                    Section {
                        Picker("深度模型", selection: Binding(get: { model.recipe.depthModel }, set: { model.setDepthModel($0) })) {
                            ForEach(DepthModelChoice.allCases) { choice in Text(choice.title).tag(choice) }
                        }
                        .disabled(model.hasNativeDepth)
                    } footer: {
                        Text(model.hasNativeDepth
                             ? "当前照片使用相机自带深度，无需 AI 深度模型。模型切换适用于普通照片。"
                             : "默认使用 Depth Anything V3 Base 504；V2 Small 用于同图对照。切换只重新估计深度，已识别的人物保持不变。")
                    }
                    Section {
                        labeledSlider("效果强度", value: $model.recipe.effectStrength, range: 0...1.5, format: "%.2f")
                        if !model.isUsingPortrait {
                            labeledSlider("边缘羽化", value: $model.recipe.edgeFeather, range: 0...6, format: "%.1f")
                        }
                        if model.isUsingLocal {
                            labeledSlider("局部清晰范围", value: $model.recipe.localRadius, range: 0.08...0.7, format: "%.2f")
                        } else if !model.isUsingPortrait, model.photo?.analysis.continuousDepth != nil {
                            labeledSlider("清晰深度范围（±）", value: $model.recipe.focusTolerance, range: 0.01...0.4, format: "%.3f")
                        }
                        labeledSlider("曝光", value: $model.recipe.exposure, range: -1.5...1.5, format: "%+.1f EV")
                    } footer: {
                        Text(model.isUsingPortrait
                             ? "人物轮廓使用独立软蒙版；调节光圈和效果强度改变其他人物及背景的虚化。模拟光圈未经真实镜头标定。"
                             : "扩大清晰深度范围可保留更多相近距离的物体。边缘羽化柔化过渡，模拟光圈未经真实镜头标定。")
                    }
                    Section {
                        Button("恢复细调默认值") {
                            var next = model.recipe
                            next.effectStrength = 1; next.focusTolerance = 0.22; next.exposure = 0
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
                            case .estimated(let estimated):
                                LabeledContent("自动深度图", value: "\(estimated.field.width) × \(estimated.field.height)")
                                LabeledContent("模型", value: model.recipe.depthModel == .v3 ? "Depth Anything V3 Base · 504" : "Depth Anything V2 Small · F16")
                                Text("完整权重随 App 内置；每张照片分析一次，移动焦点/拖动光圈不重复推理。").font(.footnote)
                            case .layered(let scene):
                                LabeledContent("分层来源", value: scene.map.provenance.title)
                                LabeledContent("已标记区域", value: "\(Int(scene.map.assignedFraction * 100))%")
                                LabeledContent("已定义景深层", value: scene.map.knownLayers.map(\.title).joined(separator: " / "))
                                if let notice = scene.notice { Text(notice).font(.footnote) }
                            case .subjects(let subjects):
                                LabeledContent("主体 / 组", value: "\(subjects.subjects.count)")
                                if subjects.groupedSubjectCount > 0 { Text("其中 \(subjects.groupedSubjectCount) 个主体按内存预算合并为一组。") }
                            case .localFallback(let reason):
                                Text(reason).font(.footnote)
                            }
                            if let portrait = photo.portrait {
                                LabeledContent("可选人物", value: "\(portrait.segmentation.subjects.count) 人")
                                Text("人物蒙版与深度分别保存；点击换人、拖动光圈复用分析结果。")
                                    .font(.footnote)
                            } else {
                                Text("当前为普通景深；未识别到可独立选择的人物。")
                                    .font(.footnote)
                            }
                        }
                    }
                    Section("使用") {
                        Text("导入本地原图后，单人自动选中；多人默认选择画面中较主要的人。点击其他人物切换清晰主体，即使距离相同也会虚化其他人。点击空白保留当前选择。")
                        Text("向左拖刻度增大 f 值，虚化减弱；向右增强。右上角菜单可查看所选人物蒙版，未识别人像时显示相对深度图。长按照片或点底部双框图标对比原图。")
                    }
                    Section("内置模型 · 全程本机") {
                        Text("SwiftUI + Core ML + Vision + Core Image。V3 Base 504 与 V2 Small 完整模型随工程内置；Xcode 在本机编译进 App，日常使用无需下载模型。人物轮廓由系统 Vision 单独识别。")
                        Text("没有第三方推理 SDK、自定义 Metal shader 或照片上传请求。模拟器使用 CPU，真机由 Core ML 调度；不支持的加速设备会尝试本机 CPU。推理失败会明确报错，不返回空分层冒充就绪。")
                        Text("旧草稿保留原图和编辑参数，必要时重新分析。深度缓存校验原图、尺寸、模型与预处理版本；人物缓存独立校验，重新识别后按位置恢复选择。")
                        Text("离线测试请使用已经位于手机本地的照片。仅存在于 iCloud 的原片仍需由系统取回。")
                    }
                    Section("边界与素材") {
                        Text("主要面向单人及 2–4 人照片。系统最多提供 4 个独立人物；人物重叠、发丝、透明或反光区域仍可能识别不准，检测异常时会提示并退回普通景深。")
                        Text("深度是相对远近估计，不代表米数。人像模式为了突出所选人物，会虚化同一距离的其他人，效果不等同于真实镜头景深。")
                        Text("不能恢复原片已失焦的细节，也不重建被遮挡的背景。内置 yuntu0920 原图走正常推理流程，不加载人工标注或预计算深度。")
                        Text("Demo 源码 MIT；模型及权重 Apache-2.0（许可随工程）。参考照片仅用于本次私人验证，发布时请替换。")
                        Text("v5 · 构建及测试记录见工程 Docs/VERIFICATION.md。真实人像的轮廓效果、速度与内存仍需用实际照片和设备确认。")
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
