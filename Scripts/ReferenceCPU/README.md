# 可选 CPU 参考计算（开发验证，不是 App 运行依赖）

这两个 Python 文件只支持本次实际上传模型所用的 MIL 操作子集。它们按 Apple 公开 protobuf schema 读取模型，读取真实 weight.bin，不接受手工选区。默认对所有 FP16 输出边界做半精度舍入；不声称与 Apple Core ML 的融合、累加和插值逐位相同。

在已经具备 Python / NumPy / PyTorch / Pillow 的环境，于工程根目录执行：

```bash
python Scripts/ReferenceCPU/mil_reference.py \
  PGYDepthDemo/Resources/Models/DepthAnythingV2SmallF16.mlpackage \
  PGYDepthDemo/Resources/ReferencePhoto.png \
  /tmp/pgy-reference
```

只有开发验证需要这些依赖，**Xcode 打开/构建/运行不需要安装或执行本工具**。图像输出不是 iOS App 截图。参考预测不应作为 App 的运行缓存或内置回退。

`Tests/Fixtures/AutomaticReference.f32` 为本次全图缩放参考输出；配套 JSON 有原图、模型、输出校验和与局限说明。生产 Swift 后续蒙版可以独立复算：

```bash
swiftc PGYDepthDemo/Core/*.swift Scripts/InspectAutomaticReference.swift -o /tmp/pgy-inspect
/tmp/pgy-inspect Tests/Fixtures/AutomaticReference.f32 /tmp/pgy-swift-masks
```

生成灰度 PGM 和8个历史点击的数值日志。此路径验证的是深度场到蒙版的数学逻辑，不是 Core Image 渲染。
