# 这些不是 App 运行截图

- `HumanAnnotatedLayers.png`：用户原图与人工层标注叠加，橙=近景、蓝=远景。
- `near-focus.png`：用生产 Swift 核心生成，点击瓶子所在近层时的控制蒙版，黑=清晰，白=虚化。
- `far-focus.png`：点击柜子所在远层时的控制蒙版，黑=清晰，白=虚化。

由 `Scripts/ExportReferenceMasks.swift` 从同一份 `ReferenceLayers.json` 生成 PGM，之后仅用 Python/Pillow转换为 PNG 和颜色覆盖图。没有运行 Core Image 或 iOS，也没有生成冒充运行结果的效果截图。
