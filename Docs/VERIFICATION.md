# 验证记录 · 2026-09-20

本次以用户提供的 yuntu0920.png 为输入，对照 demo-01/02 与 xingtu-01/02 的前后景关系，使用提供的 DepthAnythingV2SmallF16 模型实现按深度对焦。

## 已执行

环境：Apple Silicon Mac，Xcode 27；iPhone 18 Pro 模拟器，iOS 27.0。

| 检查 | 结果 |
| --- | --- |
| Swift 核心测试 | 40 项，0 失败 |
| Xcode 模拟器测试（包含核心测试） | 56 项，0 失败 |
| Python 工程/离线配置测试 | 10 项，0 失败 |
| 实际 pbxproj/资源归属检查 | 通过，模型在 App Sources 编译，样图只进入测试包 |
| iPhone Release 无签名构建 | BUILD SUCCEEDED；不等同真机安装/运行 |
| git diff --check | 通过 |

模拟器测试运行真实 Core ML 权重和 Core Image，不使用固定输出代替模型。实际测试渲染图包括 near-focus.png、far-focus.png、near-export.png、far-export.png、estimated-depth.png；XCTest 报告保留图片附件。

真实样图验证：点瓶子后，瓶子、显示器和附近桌面保持清晰，柜子虚化；点柜子后，柜子清晰，前景显示器、瓶子和桌面虚化。通过渲染图目视复查，主体分组导致的“点瓶子和柜子效果相同”已消除。默认 AI 虚化半径调至 1024 长边下 16 像素，再随光圈和效果强度缩放，以保留更适度的失焦形状。

自动断言还覆盖：切换清晰范围后缓存刷新、f16/关闭效果保留像素、预览与缩放导出的平均通道差小于 8/255、草稿类型与模型版本、失败回退、错误尺寸缓存拒绝、真实 JPEG 辅助视差与 EXIF 6 的方向/原生优先级。

## 测试发现并修复

1. **模拟器 GPU 返回全零深度。**首轮真实样图测试有 5 个焦平面断言失败，定位到模拟器 MPSGraph 后端异常但请求仍返回输出。模拟器改用 CPU，并拒绝全零/非有限预测；模型缓存版本更新，避免恢复调试期间的无效结果。
2. **失焦前景仍有硬剪影。**旧版整图模糊后再次叠加前景，合成白黑边缘的相邻像素跳变为 43/255。改为扩展前景的虚化支持范围并只模糊一次，模拟器测得跳变 5/255；远处聚焦条纹对比仍大于 240/255。
3. **缓存可能覆盖原生深度。**恢复时先复用 AI 缓存，可能跳过本次已成功读取的原生辅助深度。改为原生深度优先；真实带 EXIF 旋转的 JPEG 辅助视差测试先红后绿。
4. **模型构建归属。**集成中检查捕获了模型初始加入 Resources 的错误；最终模型由 Sources 编译为 mlmodelc，估计器加入 App Sources，用户样图只加入测试 Resources。

## 未完成的设备验收与画质边界

- 已完成的是模拟器内自动运行、真实推理和渲染检查。当前 Xcode 27 的 Device Hub 无法由桌面自动化工具取得可操作窗口，尝试返回 timeoutReached，未宣称完成逐项手势/系统相册权限/分享面板人工验收。
- 真机签名安装、`.all` 推理路径、断网首次安装、速度/内存/耗电/散热尚未实测。工程不含网络下载路径，不能据此冒充物理断网测试。
- 已覆盖真实用户竖图与 EXIF 6 原生深度；尚未穷举所有 EXIF 镜像和不同长宽比的模型表现。
- 参考醒图照片是屏幕翻拍，带反光和透视；本次验证焦平面行为，不宣称逐像素一致。细线、透明物体和遮挡边缘仍有单目估计误差。
- 前景扩散会影响轮廓附近可见背景，不重建被遮挡内容；Core Image 可变模糊与醒图专有散景形状可能不同。

## 复验命令

```sh
swift test
python3 -m unittest discover -s Tests -p test_native_project.py -v
python3 Scripts/validate_project.py
xcodebuild -project PGYDepthDemo.xcodeproj -scheme PGYDepthDemo \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  test CODE_SIGNING_ALLOWED=NO
xcodebuild -project PGYDepthDemo.xcodeproj -scheme PGYDepthDemo \
  -configuration Release -destination 'generic/platform=iOS' \
  build CODE_SIGNING_ALLOWED=NO
```

选择本机已安装的模拟器型号/系统版本。应用运行与测试都无需下载模型。
