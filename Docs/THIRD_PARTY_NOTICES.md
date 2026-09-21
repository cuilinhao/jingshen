# 来源与许可

## Demo 源码

新写 Swift Demo 源码采用根目录 `LICENSE`（MIT）。App 仅链接苹果系统框架，不包含第三方推理 SDK 或自定义 Metal shader。

## 内置模型

- 模型：Depth Anything V2 Small，Apple Core ML FP16 转换版本。
- 原始研究：Lihe Yang 等，Depth Anything V2；上游 `https://github.com/DepthAnything/Depth-Anything-V2`。
- Apple 分发：`https://huggingface.co/apple/coreml-depth-anything-v2-small`。
- 与上传文件核对的 revision：`cfef6f6f2a70783dedc0bfae40cecbc2052285d3`。
- 该 Small 模型 metadata / 分发许可：Apache-2.0。完整文本 `PGYDepthDemo/Resources/Apache-2.0.txt` 随工程及 App 资源保存。原始模型 metadata 未修改。
- 模型与权重逐文件 SHA256 / 长度见 `PGYDepthDemo/Resources/ModelInfo.json`。本次使用用户上传完整包，没有在构建阶段从上游取权重。

本说明仅针对随包交付的 Small，不延伸为其他规模模型的许可结论。

## 原生编译方式依据

- Apple Frameworks Engineer 关于 .mlpackage 加入工程时由 Xcode 编译并写入 App Bundle 的说明：`https://developer.apple.com/forums/thread/750161`。
- 同一模型的官方示例工程：`https://github.com/huggingface/coreml-examples/blob/main/depth-anything-example/DepthSample.xcodeproj/project.pbxproj`，使用 `folder.mlpackage` 和 Sources 阶段。
- 模型协议字段：`https://github.com/apple/coremltools/tree/main/mlmodel/format` 中 Model.proto、MIL.proto、FeatureTypes.proto。

## 照片及验证材料

`ReferencePhoto.png` 是用户提供的 `yuntu0920.png`，仅用于本次私人测试。原图、对比图和录屏不是开放授权素材；对外发布前应替换。旧人工标注只在 Tests/Fixtures 和历史验证目录中，不进入 App，不作为新自动算法结果。

`Scripts/ReferenceCPU` 是本次编写的有限 MLProgram 检查 / CPU 参考工具，运行时需要本地 Python、NumPy、PyTorch、Pillow。它不进入 App、不参与 Xcode 构建；工程运行无需这些依赖。它不是 Core ML 的替代运行 SDK，也没有声称完整实现所有 MIL 算子或与 Apple 后端数值等价。
