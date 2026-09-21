# 来源与许可

本版随工程分发 Depth Anything V2 Small 的 Core ML Float16 模型，使用 Apple 系统 Core ML / Vision 框架在本机推理。没有随包分发第三方运行 SDK，也不包含构建时或运行时下载模型的步骤。

新增 Demo 源码采用根目录的 MIT 许可。苹果系统框架由设备系统提供，使用应遵守 Apple 相关协议；系统框架本身不属于本 Demo 的 MIT 代码。

`DemoSample.jpg` 和 `VideoReference.png` 来自用户在本次会话提供的录屏，只作本次私人演示参考，不授权公开分发录屏中的第三方内容。商用发布前请替换成自己拥有使用权的素材。

## 内置模型：Depth Anything V2 Small

- 工程文件：`PGYDepthDemo/Resources/DepthAnythingV2SmallF16.mlpackage`，包含模型说明和权重；Xcode 在 App 的 Compile Sources 阶段编译并随 App 提供 `.mlmodelc`。
- 原始模型：Depth Anything V2，由 Lihe Yang、Bingyi Kang、Zilong Huang、Zhen Zhao、Xiaogang Xu、Jiashi Feng、Hengshuang Zhao 发布。原始项目和许可说明见 [DepthAnything/Depth-Anything-V2](https://github.com/DepthAnything/Depth-Anything-V2#license)。
- Core ML 分发来源：[Apple 的 coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small)，采用其中 `DepthAnythingV2SmallF16` 变体。该分发页标注 Apache-2.0。
- 模型许可：Apache License 2.0。完整原文保存在 [DepthAnythingV2-LICENSE.txt](DepthAnythingV2-LICENSE.txt)，从[原始项目 LICENSE](https://github.com/DepthAnything/Depth-Anything-V2/blob/main/LICENSE) 获取。根目录 MIT 许可仅适用于本 Demo 源码，不替代模型许可。

这里使用的是 **Small** 版本；原始项目对 Base、Large、Giant 的许可另有规定。App 用该模型输出普通照片的相对深度估计，并独立标注为“AI 估计景深”，不会把它记为照片自带的相机深度，也不将数值解释为米制距离。

## 官方技术依据

- [Vision 前景实例蒙版请求](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
- [生成选择主体的高分辨率蒙版](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatescaledmaskforimage(forinstances:from:))
- [Apple WWDC23：Lift subjects from images in your app](https://developer.apple.com/videos/play/wwdc2023/10176/)
- [Core Image 可变蒙版模糊](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/maskedvariableblur())
- [读取照片辅助深度数据](https://developer.apple.com/documentation/avfoundation/creating-auxiliary-depth-data-manually)
- [Vision Core ML 请求](https://developer.apple.com/documentation/vision/vncoremlrequest)

保留的旧版主体模式遵循以下约束：主体可能包含多个对象，实例编号是标签而非深度，PixelBuffer 的标签行数据与 UIKit 左上角坐标一致。这些约束参考上述苹果文档与 WWDC 说明。内置模型通过系统 Core ML / Vision API 执行，Demo 没有包含第三方推理运行库。

## 隐私清单

`PrivacyInfo.xcprivacy` 声明不追踪、不收集数据。读取草稿沙盒文件大小使用 `C617.1`，读取用户通过文件选择器授权的文件大小使用 `3B52.1`；两者对应 File Timestamp 类别的文件元数据访问理由。并未使用这些信息进行指纹识别或上传。

官方理由说明：<https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype>

这份 Demo 未进行 App Store 提交验证；集成到正式 App 后应按整个 App 的实际使用重新核对隐私声明。
