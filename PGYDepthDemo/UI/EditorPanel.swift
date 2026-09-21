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
                        Text("优先读取照片自带深度；普通照片自动使用 App 内置模型预测相对远近。不需要手工标记，同一清晰深度范围内的多个物体一起保留细节。")
                    }
                    Section {
                        labeledSlider("效果强度", value: $model.recipe.effectStrength, range: 0...1.5, format: "%.2f")
                        labeledSlider("边缘羽化", value: $model.recipe.edgeFeather, range: 0...6, format: "%.1f")
                        if model.isUsingLocal {
                            labeledSlider("局部清晰范围", value: $model.recipe.localRadius, range: 0.08...0.7, format: "%.2f")
                        } else if model.photo?.analysis.continuousDepth != nil {
                            labeledSlider("清晰深度范围（±）", value: $model.recipe.focusTolerance, range: 0.01...0.4, format: "%.3f")
                        }
                        labeledSlider("曝光", value: $model.recipe.exposure, range: -1.5...1.5, format: "%+.1f EV")
                    } footer: {
                        Text("扩大清晰深度范围可保留更多相近距离的物体；不是扩大一个清晰圆圈。边缘羽化柔化过渡，模拟光圈不是经过标定的真实镜头参数。")
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
                                LabeledContent("模型", value: "Depth Anything V2 Small · F16")
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
                        }
                    }
                    Section("使用") {
                        Text("导入本地原图，等待自动深度计算完成后点选焦点。清晰范围内的多个物体一起保留细节，超出范围的像素按深度差渐变虚化。向左拖刻度增大 f 值，虚化减弱；向右增强。")
                        Text("右上角菜单可查看相对深度图（亮近暗远），或重新计算。长按照片/点底部双框图标对比原图。细调中的清晰深度范围可扩大或缩小清晰层。")
                    }
                    Section("内置模型 · 全程本机") {
                        Text("SwiftUI + Core ML + Core Image。完整 DepthAnythingV2SmallF16.mlpackage 随工程交付，Xcode 在本机编译进 App；构建、首次运行及日常使用均无模型下载步骤。")
                        Text("没有第三方推理 SDK、自定义 Metal shader 或照片上传请求。模拟器使用 CPU，真机由 Core ML 调度；不支持的加速设备会尝试本机 CPU。推理失败会明确报错，不返回空分层冒充就绪。")
                        Text("旧版没有有效深度的草稿会保留原图/参数并重新推理。照片缓存校验原图 SHA256、尺寸、模型及预处理版本，不把旧人工层或主体编号当作深度。")
                        Text("离线测试请使用已经位于手机本地的照片。仅存在于 iCloud 的原片仍需由系统取回。")
                    }
                    Section("边界与素材") {
                        Text("AI 输出是相对远近估计，不是米数或真实镜头标定；透明物体、反光、细线、遮挡边缘仍可能估计错误。清晰范围可调，但不会人为把所有主体一律合并成一层。")
                        Text("不能恢复原片已失焦的细节，也不重建被遮挡的背景。内置 yuntu0920 原图走正常推理流程，不加载人工标注或预计算深度。")
                        Text("Demo 源码 MIT；模型及权重 Apache-2.0（许可随工程）。参考照片仅用于本次私人验证，发布时请替换。")
                        Text("v4 · 当前交付未在本环境运行 Xcode/真机。详情见工程 Docs/VERIFICATION.md，不把非 Apple 参考计算当作 iOS 实测。")
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
