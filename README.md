# PGYDepthDemo · 按深度对焦

用于 iOS 的照片景深编辑 Demo。照片自带可用深度时优先使用原生深度；普通照片使用内置 **Depth Anything V2 Small F16** 估计整幅相对深度，再按点击位置的深度范围决定清晰区域。

同一清晰深度范围内的不同物体可以一起清晰。普通照片不再依赖系统把它们分成同一个主体，修复了点击瓶子和柜子得到相同虚化结果的问题。

## 运行

1. 打开 `PGYDepthDemo.xcodeproj`，选择 `PGYDepthDemo` Scheme。
2. 选择 iPhone 模拟器；真机运行时在 Signing & Capabilities 选择自己的团队。
3. 按 **⌘R**，从相册或文件导入照片；按 **⌘U** 运行测试。

最低 iOS 17。需要完整 Xcode 和目标设备的 SDK。模型已包含在 `PGYDepthDemo/Resources/DepthAnythingV2SmallF16.mlpackage`，Xcode 会编译为 App 内的 `.mlmodelc`；没有构建或运行时模型下载，也无需第三方 SDK。模型约 50 MB。模拟器使用 CPU 推理，真机由 Core ML 调度可用计算设备。

## 使用

- 点击图片对焦，拖动光圈尺调整虚化强度；f16 或关闭景深时不做虚化。
- “调整”中的 **清晰深度范围**控制多大深度范围一起清晰。AI 深度默认 0.18，原生深度使用独立容差。范围越大，一起清晰的物体越多。
- 自动模式显示“AI 估计景深”或原生景深；模型失败会明确提示“局部虚化”。手动局部模式也可主动选择。
- 深度预览为亮近暗远；局部蒙版为白色虚化、黑色清晰。
- 支持原图对比、居中比例裁切、简单色调与曝光，导出 JPEG 最长边不超过 2048。
- 只保存最近一张照片草稿。重启恢复原图和配方；旧主体蒙版与旧版本模型缓存会重新分析。

所有照片分析在本机完成。仅存于 iCloud 的原图仍需要系统先取回。单目深度是相对估计，不是米制测距；光圈数值是效果控制参数。透明物体、细线和复杂遮挡仍可能估计不准，也不能恢复原图已经丢失的细节。目标是与参考图一致的前后景清晰关系，不保证复制醒图的专有散景与边缘算法。

## 验证与结构

```sh
swift test
python3 -m unittest discover -s Tests -p test_native_project.py -v
python3 Scripts/validate_project.py
```

Apple SDK 图像测试包括真实内置模型和用户提供的 `Tests/Fixtures/FocusScene.png`，验证瓶子/显示器/柜子的焦平面切换、预览、导出和缓存恢复。样图只进入测试包，不进入 App。

- `PGYDepthDemo/Core/`：相对深度、焦点采样、配方与草稿。
- `PGYDepthDemo/Imaging/`：原图读取、模型推理、Core Image 渲染和串行调度。
- `PGYDepthDemo/State/`、`UI/`：编辑状态与 SwiftUI 界面。
- `Docs/VERIFICATION.md`：实际测试结果和未覆盖事项。
- `Docs/TEST_PLAN.md`：复验步骤。
- `Docs/THIRD_PARTY_NOTICES.md`：模型来源与 Apache-2.0 许可。
