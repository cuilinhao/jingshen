# v5 验证记录

日期：2026-09-21。当前修改基于原桌面 Demo，默认切换为 V3 Base 504，并增加独立人物选择。这里区分文件/逻辑检查、苹果运行时结果与真实人像验收；旧 v4 的 Linux 参考计算记录已移到 [历史记录](History/v4_VERIFICATION.md)，不能作为 v5 通过证据。

## 本次人像边缘修复验证

日期：2026-09-21。正式工程加入蒙版可靠核心清理、原色软边合成和背景圆形散景。原始人物分割缓存 v1 自动失效，深度缓存保持独立。

| 检查 | 结果 | 证据 |
|---|---|---|
| `swift test` | 93 项，0 失败 | [core-tests.log](../Verification/v5-fixes/core-tests.log) |
| Python 工程测试 | 17 项，0 失败 | [python-tests.log](../Verification/v5-fixes/python-tests.log) |
| 工程配置检查 | 134 个对象引用，28 个 App Swift / 14 个测试 Swift | [project-check.log](../Verification/v5-fixes/project-check.log) |
| iOS 模拟器测试 | 124 项，0 失败，包含上述 93 个核心测试 | [apple-tests.log](../Verification/v5-fixes/apple-tests.log) |
| iPhone Release 无签名构建 | 成功，未安装真机 | [device-build-summary.log](../Verification/v5-fixes/device-build-summary.log) |
| 原图实际运行 | 正式 Core + Imaging 源码，Mac Core ML/Vision/PhotoPipeline 导出 | [sample-runtime.log](../Verification/v5-fixes/sample-runtime.log) |
| 独立代码及输出审查 | 未发现必须处理的新错误 | 下方说明 |

先以旧代码复现了过期缓存复用与软边去色断言失败，再验证修复。新增回归覆盖可靠核心变为不透明、附近软边保留、弱椅背/孤岛剔除、二维距离不跨行、无核心失败，以及深色主体纹理和背景清晰残影；保留同距离换人、前景遮挡、贴边不透明和禁用效果测试。原型之外，重新编译正式工程源码后，用用户原图导出 f/1.8、f/1.4 和 f/2.8 三档效果。

人工检查默认结果：明显黑块、手腕横向碎片及清晰椅背残影消除，灯带结构和圆形高光接近参考风格；手部局部边缘仍略硬。当前只识别出一个前景主体，两个小型背景人物未形成独立实例，不能据此声称多人识别通过。该照片及任何人物输出未加入 Git 仓库。日志时间来自本机模型缓存已热的运行，不代表首次加载或 iPhone 性能。

以下保留修复前的 v5 基线记录；其旧的背景去色实现已由保留原色合成替代。

## v5 初版自动验证（历史基线）

平台：Xcode 27.0 / Swift 6.4，iPhone 17 Pro 模拟器 iOS 26.5；日期 2026-09-21。

| 检查 | 结果 | 工程内证据 |
|---|---|---|
| `swift test` | 88 项，0 失败 | [core-tests.log](../Verification/v5/core-tests.log) |
| `python3 -m unittest discover -s Tests` | 17 项，0 失败；包括两份完整模型固定哈希与文件长度 | [python-tests.log](../Verification/v5/python-tests.log) |
| `python3 Scripts/validate_project.py` | 130 个对象引用，27 个 App Swift / 13 个测试 Swift，模型 Sources 与资源检查通过 | [project-check.log](../Verification/v5/project-check.log) |
| Xcode 模拟器 `test` | 118 项，0 失败；其中包含上述 88 个核心测试，不应重复相加 | [apple-tests.log](../Verification/v5/apple-tests.log) |
| iPhone Release `build CODE_SIGNING_ALLOWED=NO` | 构建成功；未签名、未安装真机 | [device-build-summary.log](../Verification/v5/device-build-summary.log) |
| 独立代码审查 | 贴边 alpha 问题已修复并复核；没有未处理的已确认 Critical / Important 项 | 下方回归说明 |

Apple 测试真实加载 App Bundle 的 V3/V2 模型，验证 V3 有效输出 379×504、输入方向及 RGB 补边；覆盖模型切换仅失效深度缓存、点击/导出不重跑分析、人物失败普通景深回退。7 项人物合成测试覆盖同距离换人、背景不渗入主体色、前景扩散及遮挡、关闭效果、上下方向、分数 alpha 与画面边缘。

回归修复：人物贴边时先在原图范围外延展再模糊；去背景色运算使用 RGBAh / linear-sRGB，避免在 gamma 编码字节中相减产生亮边。两项问题均先用合成图复现，再验证通过。非对称图片确认 `render(toBitmap:)` 与蒙版均按左上起始的行序读取；原先失败的上下断言来自测试误假定 bottom-up，已校正。

人工检查了合成输出附件：[清晰红色主体与虚化绿色人物](../Verification/v5/portrait-edge.jpeg)、[非对称软边输出](../Verification/v5/asymmetric-render.jpeg)。它们验证合成行为，不是人体识别准确率或真实发丝效果。

普通模拟器启动已进入编辑界面；系统账号提示遮挡界面，未以此声称完成 UI 点击流程验收。未修改系统账号。完整 `.xcresult`、构建日志和独立 Mac 探针保存在当前任务 `/Users/pgy/Documents/Codex/2026-09-21/k-n/work/`，工程内保留了最终测试日志和摘要。

## V3 苹果运行时探针验证了什么

输入为工程原有 `ReferencePhoto.png`（1060×1410），没有使用真实人像。模型输入 RGB 504×504，输出 `depth`、`confidence` 均为 Float16 `[1,504,504]`。加速输出 strides `[258048,512,1]`；CPU 输出 `[254016,504,1]`。因此 App 数组读取必须尊重 strides。

等比输入内容为 379×504，左补边 62、右补边 63；已经检查输入图方向。补边后的深度统计不同于有效内容，App 应在归一化前去掉补边。探针观察到瓶子/玩偶的原始深度低于柜子/墙，支持取逆数后亮近暗远的映射。`.all` 与 CPU 的等比输入原始深度平均相对差约 0.54%。

探针的 `.all` 首次加载约 13.01 秒、预测约 0.108–0.118 秒；CPU 加载约 0.882 秒、预测约 0.209–0.348 秒。它们来自这台 Mac 的独立脚本，每后端只测一次加载；不代表 iPhone、不含 Vision 和完整 UI，也不适合当作性能承诺。

`confidence` 的实际值大于 1，不是概率；当前应用没有用它做人物边缘判断。探针的归一化对比使用 p2/p98，生产 App 保持既有 p1/p99；探针统计不能当成生产像素输出。

这张非人物图中 V3 的显示器深度与柜子接近，没有复现 V2 历史 fixture 中显示器与瓶子同层的预期。V2 的历史点击断言应绑定 V2 对照路径，不能强行要求 V3 相同。此结果也说明“模型更大”不能证明所有场景更准。

## 仍需真实照片与设备验收

- 真实 iPhone 安装、首次飞行模式分析、模型切换的峰值内存与耗时、热状态和连续交互表现。
- 用户真实单人/2–4 人样片中的人物漏检、合并、发丝、肩膀、衣服边缘与复杂背景质量。
- 真实前后遮挡、原片已有失焦、导出画质及与预览的一致性；权限、裁切、快速换人和旧草稿的实机操作。

`PortraitImagingTests` 的人工合成图用于验证合成算法行为，不验证 Vision 能否准确找齐真实人物。`CoreMLSmokeTests` 必须真正加载 Bundle 编译模型，模型缺失应失败；Mac 独立探针不是 iOS App 的端到端替代。完整待执行步骤见 [TEST_PLAN.md](TEST_PLAN.md)。

人物半透明边缘保留原图颜色，可能残留原背景或另一人的颜色；单张样片的阈值不能保证所有场景都合适。人物整体深度排序也不等于交叉肢体的逐像素遮挡重建。应在真实发丝、透明衣物、人物相互遮挡的照片中验收。
