# PGYDepthDemo v5 · 人物选择景深

在原有 Demo 上增加 **Depth Anything V3 Base 504 + Vision 独立人物蒙版 + 分层虚化**。面向单人及 2–4 人照片：点击谁，就突出谁；旁边同一距离的人也会虚化。V2 Small 保留为效果与性能对照。

**真实 iPhone 性能和真实人像发丝/肩膀边缘仍需验收。**已经进行的检查与证据、尚未完成的项目见 [验证记录](Docs/VERIFICATION.md)。更换深度模型本身不能保证人物轮廓干净，本版同时改动人物选择和边缘合成。

## 打开运行

从 GitHub 克隆本分支后，**首次打开 Xcode 前先拉取 Git LFS 模型权重**。如果 `git lfs` 命令不可用，先安装 [Git LFS](https://git-lfs.com/)，然后在项目目录执行：

```sh
git lfs install --local
git lfs pull
python3 -m unittest discover -s Tests -p test_offline_model_project.py
```

`--local` 将 Git LFS 配置限制在此仓库。V3 包内 `Data/com.apple.CoreML/weights/weight.bin` 应为 **233,223,744 字节**，上面的检查还会核对 SHA256；若只有一小段 `version https://git-lfs.github.com/spec/v1` 文本，说明仍是指针，不能编译模型。拉取完成后，App 的构建和运行不再下载权重。

GitHub 的 **Download ZIP 默认只包含 LFS 指针**，不能据此假定已拿到完整模型；建议使用 Git 克隆并执行 `git lfs pull`。[GitHub 存档说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/managing-git-lfs-objects-in-archives-of-your-repository)

1. 在此目录打开 `PGYDepthDemo.xcodeproj`，Scheme 选择 `PGYDepthDemo`，最低 iOS **17.0**。
2. 选择已安装的 iPhone 模拟器，或在 Signing & Capabilities 设置你的开发团队后选择真机。
3. 按 **⌘R**。两份完整模型均随工程提供，由 Xcode 编译到 App Bundle，没有构建脚本下载或运行时模型下载。

首次构建会编译模型，首次分析会加载模型。模拟器使用 CPU，耗时不能代表手机。App 代码为 Swift，使用 Core ML、Vision、Core Image 等苹果系统框架，无第三方推理 SDK 或自定义 Metal shader。

| 用途 | 模型包 | 实际文件总量 |
|---|---|---:|
| 默认 | `DepthAnythingV3_base_504.mlpackage` | 233,541,894 字节 |
| 对照 | `DepthAnythingV2SmallF16.mlpackage` | 49,819,122 字节 |

模型位于 `PGYDepthDemo/Resources/Models/`。数值是未编译模型文件总量，不等于安装包大小。固定版本、逐文件 SHA256 与接口记录在 `PGYDepthDemo/Resources/ModelInfo.json`；许可见 [第三方说明](Docs/THIRD_PARTY_NOTICES.md)。

## 人物选择如何工作

导入时分别准备深度和人物蒙版。照片自带有效原生深度时优先使用它；普通照片使用当前选择的模型。Vision 在处理原图的尺度生成每个人的软蒙版。两类分析独立保存，人物编号不会被当作距离。

- 单人自动选中；多人默认选择面积最大的可识别人，并可点击其他人切换。
- 选中人物内部保持原始细节，其他人物有独立虚化量，即使他们深度相同。
- 点击空白保留当前人物。切换时短暂显示轮廓，轮廓不进入导出图。
- 人物按远近合成；前排失焦人物仍可遮挡后排选中的人，不把后排人物整体贴到最上层。
- 未识别到可独立选择的人物，或识别失败/检测到拥挤时，界面提示并使用普通景深。无人物照片保留原来的按深度对焦；“局部”模式仍是独立的圆形虚化。

背景先移除人物颜色并做有限距离的边缘延展，再虚化并合成人物；这用于降低肩膀附近的颜色泄漏。它不还原真实被遮挡背景，也不恢复原片已经失焦的细节。

人物软蒙版先清理远离可靠核心的弱背景残影，再保留原图颜色合成，降低黑发色块和椅背残影。人物模式的背景采用圆形散景及高光响应。整图分割之外，增加多尺度人体检测与局部精细人像补全；用户原图中的前景主体、左后方和右后方人物现已分别识别，并通过三个点击点及逐人导出验收。

点击换人、拖动光圈只重新渲染，不重复运行深度模型或人物识别。切换 V3/V2 会重新准备对应深度，并可复用有效的人物蒙版。V3 输入等比补边到 504×504，输出去除补边、转换为逆深度并归一化；相对深度图为亮近暗远，不是米数。

## 草稿与保留功能

v5 草稿保存所选人物、模型选择、深度和独立人物蒙版。缓存与源图片 SHA256、处理尺寸及各自分析版本绑定；V2 和 V3 深度不互相复用。重新分割后按保存的焦点位置重新匹配人物，避免沿用重排的编号。v1–v4 草稿仍读取原图和参数；缺失或过期分析重新生成。仍只保留最近一张可编辑草稿。

保留相册/文件导入、原图对比、光圈、色调、裁切、细调、导出及原主界面布局。导出从处理原图重新渲染，**JPEG / SDR / sRGB，最长边不超过 2048，小图不放大**；不包含选中轮廓、对焦框或原图 GPS。预览最长边 1024。

内置 `ReferencePhoto.png` 是原有非人物样图，走普通导入流程；它可验证深度方向和 V2/V3 对照，不能验收多人选择或发丝质量。`Tests/Fixtures` 的人工图和历史预计算深度仅供测试，不进入 App。

## 验证和局限

在 Mac 可运行：

```sh
swift test
python3 -m unittest discover -s Tests
python3 Scripts/validate_project.py
```

Apple 图像、流水线和模型测试在 Xcode 按 **⌘U** 执行。`CoreMLSmokeTests` 真正加载 Bundle 编译模型；`PortraitImagingTests` 用合成图检查人物切换、边缘泄色与遮挡；这些不能替代真实人像验收。可选 `Scripts/Verify_on_Mac.sh` 只做模拟器 SDK 构建检查。

`Scripts/VerifyPortraitPeople.sh --help` 提供真实照片验收入口：传入本地照片、已编译模型 Bundle、输出目录、预期人数和每个人的点击坐标。它编译当前正式 Core/Imaging 代码，检查人数及独立 ID，再导出每个人的对焦图和蒙版。照片不随仓库提供，脚本不上传输入。

Vision 最多提供四个独立人物实例，重叠、遮挡、复杂背景或超过四人可能漏检/合并；人数检查也不能发现所有错误。透明物、细发丝和运动模糊仍可能有瑕疵。V3 不保证在每张照片上优于 V2，且体积与运行开销更大。真机应按 [验收清单](Docs/TEST_PLAN.md) 测试单人、2–4 人、同距离人物、前后遮挡和复杂发丝。

模型与分析代码不联网。飞行模式测试请用手机本地照片；仅存于 iCloud 的照片仍需系统先取回。日志前缀包括 `[Model]`、`[Depth]`、`[People]`、`[Focus]`、`[Draft]`、`[Export]`。
