# v4 架构与修复说明

## 目标

普通本地原图无需人工标记即可自动获得相对深度；点击选择清晰深度范围而非主体 ID。同深度范围可包含多个不相连区域。完整模型随工程交付；构建和 App 首次使用均不下载。UI 主布局不变。

## 分析来源

`PhotoAnalysis.native(DepthField)` 表示照片辅助数据；`estimated(InferredDepth)` 表示当前模型预测。旧 `subjects`、`layered`、`localFallback` 数据类型只为兼容迁移 / 历史测试保留，普通导入不会返回它们。旧人工校正 UI 源码保留但不在当前主界面暴露。

`PhotoPipeline.prepare` 首先使用 ImageIO / AVDepthData 读取原生深度。无原生深度时校验 v4 缓存的 SHA256、尺寸、模型与预处理版本、深度变化；无有效缓存就调用 `OfflineDepthEstimator`。不创建 `SceneLayerMap.blank`，不按图片名称套测试蒙版。一次成功的 `PhotoSession` 必须在推理和有效性检查之后发布。

`InferredDepth` 中保存 `sourceSHA256`、`imageSize`、`modelID`、`preprocessingID` 与深度场；模型本身留在 Bundle，不写入每张照片的草稿。`DraftStore` 原子提交原始数据、类型化分析与 v4 配方。旧缓存不适用时保留原图，重新推理。失败不会被隐藏为一张没有效果的图。

## 模型合同

对上传的 `model.mlmodel` 按公开 protobuf schema 实际读取：spec 8 / CoreML7，输入 `image` 为 RGB 518×392，输出 `depth` 为 GRAYSCALE_FLOAT16 518×392。MLProgram 已有 RGB255 的 mean/std 归一化，App 不再额外除以 255。

模型通过 `folder.mlpackage` 文件引用加入 Xcode Sources 阶段，由原生工具本地编译为 `DepthAnythingV2SmallF16.mlmodelc`。App 只加载 Bundle 中的编译产物。没有 download 或 `MLModel.compileModel` 运行时逻辑；也没有裸拷贝原始包假装编译模型。

输入先完成图片 EXIF 旋转 / 镜像和透明像素白底合成，再将全图缩放到模型实际尺寸；不裁掉照片内容、不塞黑边。输出按整张原图的归一化坐标映射回去。CVPixelBuffer 读取按 bytesPerRow，支持 Float16 / Float32；MLMultiArray 备用读取按 strides。验证输出尺寸、全体有限值、原始及归一化后的非恒定变化。

真机 `.all`，模拟器 `.cpuOnly`；加速模型加载 / 推理失败时尝试本机 CPU。模型在串行 actor 持有，滑动不重复加载；同步推理中不能保证即时中断，但开始 / 结束及每个重步骤检查取消，UI 使用版本号防止旧结果覆盖新任务。

## 对焦和渲染

点击从屏幕 aspect-fit 可见图片逆映射经过裁切的原图坐标，然后取深度附近 5×5 中值。清晰半宽默认 0.22，可调 0.01…0.4。对任意像素 d 与焦点 df：

```text
blur = smoothstep(width, width + 0.22, abs(d - df))
```

与屏幕距离无关，也与物体身份无关。前景扩散蒙版只作用于比焦点更近且需要虚化的区域；清晰范围保护蒙版在扩散后重新合成原始细节，避免同范围物体因相邻模糊而被一同污染。范围边缘做柔和过渡。这里是可调的摄影效果近似，不声称光学标定。

Core Image `CIMaskedVariableBlur`、高斯前景扩散和 `CIBlendWithMask` 使用同一份深度 / 参数。预览最长边 1024，导出处理输入最长边 2048，半径按像素尺寸同步放大，始终从原始处理输入重建。

缓存键包括图片会话 ID、焦点、范围、模式、尺寸；预览辅助缓存还包含裁切等。照片 / 分析改变都会更换 ID；滑杆更新采用取消与最新版本令牌。主线程只管理交互，重处理在 actor。

## 验证边界

真实权重的 CPU 参考解释器验证了 2459 个 MLProgram 操作的形状、权重偏移边界及各输出有限性。FP16 边界有模拟，但矩阵运算累加、融合和缩放算法与 Apple 后端不必逐位一致。它提供“模型对这张原图确实输出不同远近”的证据，不验证 iOS 的 Core ML 输入输出适配器。

Apple 原生链路对应 `CoreMLSmokeTests`，尚需实际 Xcode / iPhone 执行。见 VERIFICATION 与 TEST_PLAN。
