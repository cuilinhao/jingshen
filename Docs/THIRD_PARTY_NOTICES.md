# 来源与许可

本版没有随包分发任何第三方神经网络权重或第三方运行 SDK。旧版外部模型相关文件和构建步骤已移除。

新增 Demo 源码采用根目录的 MIT 许可。苹果系统框架由设备系统提供，使用应遵守 Apple 相关协议；系统框架本身不属于本 Demo 的 MIT 代码。

`DemoSample.jpg` 和 `VideoReference.png` 来自用户在本次会话提供的录屏，只作本次私人演示参考，不授权公开分发录屏中的第三方内容。商用发布前请替换成自己拥有使用权的素材。

## 官方技术依据

- [Vision 前景实例蒙版请求](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
- [生成选择主体的高分辨率蒙版](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatescaledmaskforimage(forinstances:from:))
- [Apple WWDC23：Lift subjects from images in your app](https://developer.apple.com/videos/play/wwdc2023/10176/)
- [Core Image 可变蒙版模糊](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/maskedvariableblur())
- [读取照片辅助深度数据](https://developer.apple.com/documentation/avfoundation/creating-auxiliary-depth-data-manually)

主体可能包含多个对象；实例编号是标签而非深度；PixelBuffer 的标签行数据与 UIKit 左上角坐标一致；这些约束参考上述苹果文档与 WWDC 说明。工程没有复制第三方模型推理实现。

## 隐私清单

`PrivacyInfo.xcprivacy` 声明不追踪、不收集数据。读取草稿沙盒文件大小使用 `C617.1`，读取用户通过文件选择器授权的文件大小使用 `3B52.1`；两者对应 File Timestamp 类别的文件元数据访问理由。并未使用这些信息进行指纹识别或上传。

官方理由说明：<https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype>

这份 Demo 未进行 App Store 提交验证；集成到正式 App 后应按整个 App 的实际使用重新核对隐私声明。
