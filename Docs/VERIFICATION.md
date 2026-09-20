# 原生主体虚化版 v2 · 交付验证记录

日期：2026-09-20。环境：Linux x86_64、Swift 6.2.1；App 项目使用 Swift 5 语言模式，最低 iOS 17。

**此环境没有 Xcode、Apple iOS SDK、iOS 模拟器或 iPhone。下面的“通过”不代表通过了 Xcode 编译或真机验收。**

## 已实际执行

| 检查 | 实际结果 | 证据 |
|---|---|---|
| Swift 核心、主体选择、局部蒙版、配方测试 | 28 项通过 | `Verification/core-native-final.log` |
| Swift 草稿持久化与旧版迁移测试 | 7 项通过；与上行合计 35 项，0 失败 | 同上 |
| 工程静态回归检查 | 6 项通过，0 失败 | `Verification/project-tests-final.log` |
| 实际 `.pbxproj` OpenStep 解析与引用完整性 | 78 个对象；17 个 App Swift 源码文件、4 个测试文件归属一致 | `Verification/project-validation-native.log` |
| 无外部模型依赖检查 | 无下载 Run Script、无远程 Package 引用、无外部模型文件或加载代码 | 同上及工程回归检查 |
| 所有 App Swift 文件与 iOS 图像测试的语法解析 | 通过 `swiftc -frontend -parse`；不是 Apple SDK 类型检查 | `Verification/swift-parse-native.log` |
| 资源、共享 Scheme、权限与隐私清单、Bash 语法 | 通过静态检查 | `Verification/project-validation-native.log` |
| 录屏布局保留 | 对照固定几何数值和光圈刻度实现；不是运行后像素比对 | 工程回归检查中的 UI 项 |

6 项工程回归是 Python 标准库测试，读取实际工程与源码。它们没有用假 Vision 结果来冒充真实识别验证。核心测试使用明确构造的标签、蒙版、深度、配方和临时文件夹，验证数学与持久化行为。

## 本轮审查中修正

删除旧模型下载构建阶段，同时删除运行时加载路径，避免“能构建但仍找模型”。将原生深度、主体标签/软蒙版、局部选区分别建模；主体编号不会被用作距离。

更新旧草稿迁移：保留原图和编辑参数，丢弃旧外部模型的深度缓存并重新分析。损坏分析缓存不会丢弃原图；导入和渲染保留版本号与取消保护。

补充沙盒文件和用户授权文件大小读取的隐私理由，并调整带标题与 footer 的 SwiftUI Section 为明确的 `content:header:footer:` 初始化写法。相应静态回归先观察到失败，再修改并重新执行通过。

这些是本次实现者的源码自查，不是独立审计或另一个审查者的验收。

## 已提供、但未执行的 Apple SDK 测试

`Tests/IOS/ImagingTests.swift` 共 11 项，需要在 Mac 上用 Xcode 的 ⌘U 执行。覆盖灰度图方向、裁切坐标、Core Image 参数、关闭效果/f16 的像素结果、局部虚化、带行填充的 PixelBuffer、浮点软蒙版，以及分析失败回退/缓存复用/尺寸不匹配场景。

其中分析失败与缓存测试使用可控的分析器替身，只验证调度与回退；即使这些测试在 Mac 上通过，也不能替代真实 `VNGenerateForegroundInstanceMaskRequest` 的照片验收。

## 仍待 Mac / iPhone 验证

尚未进行 Xcode 类型检查、链接、签名、安装或运行；真实 Vision 主体分割、Core Image 输出画质、相册权限、导出分享、杀进程恢复、连续拖动性能与内存均未在设备上执行。

“Mac 断网构建”与“全新安装 App 后，断网首次识别本地照片”是两项独立的待验收测试。工程没有自定义联网步骤、模型权重或请求，但不能以静态检查推断每台设备上的系统 Vision 都必定成功。识别失败会明确使用局部虚化，不会以此冒充主体识别通过。

`Docs/VideoReference.png` 是用户录屏参考帧，不是新 App 运行截图。主页面沿用参考布局和刻度交互，但尚未逐像素验证；未展示过的展开面板是 Demo 补充设计。

## 在 Mac 上复验

解压到新文件夹，打开 `PGYDepthDemo.xcodeproj`，选择 PGYDepthDemo Scheme 与设备，⌘R 构建运行，⌘U 运行测试。无需先执行脚本或下载模型。

可选的编译检查命令：

```bash
bash Scripts/Verify_on_Mac.sh
```

该脚本需要已安装完整 Xcode，执行不签名的模拟器 SDK 构建，输出 `Verification/mac-build.log`。它不进行模型下载，不代表真机 UI 验收。功能与离线验收步骤见 `Docs/TEST_PLAN.md`。
