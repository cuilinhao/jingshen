# 来源与许可

## Demo 源码

Demo 源码采用根目录 `LICENSE`（MIT）。App 使用苹果系统框架，不包含第三方推理 SDK 或自定义 Metal shader。Vision 的人物实例分析属于系统能力，不随工程分发额外人物分割权重。

## 默认模型：Depth Anything V3 Base 504

- 研究及原始模型：[ByteDance-Seed / Depth Anything 3](https://github.com/ByteDance-Seed/Depth-Anything-3)、[DA3-BASE 模型卡](https://huggingface.co/depth-anything/DA3-BASE)。
- Core ML 转换：john-rocky（Daisuke Majima）；[转换模型卡](https://huggingface.co/mlboydaisuke/Depth-Anything-3-Base-CoreML)。该模型卡注明转换继承上游 Apache-2.0 许可。
- 下载来源：[mlboydaisuke/coreml-zoo](https://huggingface.co/mlboydaisuke/coreml-zoo/tree/a3d12de43e1b6131cd05cdd9027e0c4978d436e5/depth_anything_v3)，固定 revision `a3d12de43e1b6131cd05cdd9027e0c4978d436e5`。
- 文件：`DepthAnythingV3_base_504.mlpackage`；原 ZIP SHA256 `cd96d12b7d14fb92c312ad1efe771eb1732680578e11bf6b76ab63f4c5d6c51b`。
- 解压后总量 233,541,894 字节，其中权重 233,223,744 字节。完整包随工程提供，模型 metadata 未改写。

以上许可来源于该 Base 权重及该转换的模型卡（2026-09-21 核对），不延伸为其他规模或其他仓库模型的许可结论。

## 对照模型：Depth Anything V2 Small

- 原始研究：Lihe Yang 等；[Depth Anything V2](https://github.com/DepthAnything/Depth-Anything-V2)。
- Apple Core ML FP16 分发：[apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small)。
- 与原工程完整包核对的 revision：`cfef6f6f2a70783dedc0bfae40cecbc2052285d3`。
- Small 权重 metadata / 分发许可：Apache-2.0。文件 `DepthAnythingV2SmallF16.mlpackage`，总量 49,819,122 字节。

两份模型逐文件 SHA256 / 长度在 `PGYDepthDemo/Resources/ModelInfo.json`，完整 Apache-2.0 文本在 `PGYDepthDemo/Resources/Apache-2.0.txt`，随工程及 App 资源保存。构建与 App 使用期间不从上游下载权重。

## 原生编译方式

`.mlpackage` 通过 Xcode Sources 编译为 App Bundle 中的 `.mlmodelc`。依据包括 [Apple 工程师说明](https://developer.apple.com/forums/thread/750161)、[Core ML 示例工程](https://github.com/huggingface/coreml-examples/blob/main/depth-anything-example/DepthSample.xcodeproj/project.pbxproj) 和 [Core ML 模型协议](https://github.com/apple/coremltools/tree/main/mlmodel/format)。

## 照片与历史验证材料

`ReferencePhoto.png` 是用户提供的 `yuntu0920.png`，仅用于本次私人测试。原图、对比图和录屏不是开放授权素材；对外发布前应替换。旧人工标注与预计算深度只供测试和历史验证，不进入 App，不作为当前自动识别结果。

`Scripts/ReferenceCPU` 是原工程为 V2 编写的有限 MLProgram 检查 / CPU 参考工具，需要 Python、NumPy、PyTorch、Pillow。它不进入 App、不参与 Xcode 构建，也不是 V3 或苹果运行时验证；运行 Demo 无需安装这些依赖。
