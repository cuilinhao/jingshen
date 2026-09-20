# 原生主体虚化架构

## 路径

```text
本地 JPEG / PNG / HEIC 数据
  → PhotoLoader：EXIF 方向归一化，图像处理最长边≤2048，透明 PNG 合成白底
  → 有可用原生深度：PhotoAnalysis.native(DepthField)
  → 否则：NativeSubjectSegmenter → Vision 请求 → PhotoAnalysis.subjects(SubjectSegmentation)
  → 系统请求失败/没有主体：PhotoAnalysis.localFallback(reason)
  → 点击坐标逆映射到原图，生成虚化控制蒙版
  → DepthRenderer → Core Image 可变模糊 / 前景扩散 / 色调 / 裁切
  → 1024 预览或≤2048 JPEG 导出
```

没有服务器、模型下载、远程推理或额外模型文件。

## 数据含义

`DepthField` 只存照片原生相对视差：0 远，1 近，不承诺实际米数。`SubjectSegmentation.labels` 只存系统主体编号：0 背景，非零为主体。编号的大小不代表远近；`subjects` 保存各主体的软覆盖蒙版。

`FocusMaskBuilder` 分别处理原生深度、主体、明确的圆形局部模式。点击某主体时，对其软蒙版取反得到虚化蒙版；点背景时，前景蒙版最大值合并后作为虚化蒙版。只有明确前景相对背景的关系才触发前景扩散，不擅自排序两个主体的距离。

`GrayMask` 使用连续字节 Data 保存，记录尺寸并校验数据长度。所有公共坐标统一为原图左上角归一化坐标；Vision PixelBuffer 按左上角逐行读取，尊重 bytesPerRow。只有 Core Image 裁切矩形转换到左下角坐标。

## 性能与并发

PhotoPipeline actor 负责串行图像处理，主线程只管理 UI。导入生成主体蒙版一次；更改光圈不再调用 Vision。变更选中点、模式或清晰范围才更新基础蒙版；光圈改变只更新模糊程度。原图对比和诊断图也有与参数对应的缓存。

每次导入/预览都有取消与版本校验，旧结果不会覆盖新照片或新参数。系统请求和一次 GPU 提交不能保证中途被打断；只能在开始前、阶段之间与结束后检查取消。性能需要真机测量，不提供预先帧率保证。

## 持久化

DraftStore 是 Foundation actor，可在 Linux 的 Swift 测试中实际验证。每次写入独立 UUID 快照目录，source.data、analysis.plist、recipe.json 全部写好后才原子替换 current.json 指针。成功提交后仅清理本功能的旧 UUID 目录。

v2 使用二进制 plist 保存带类型的分析，不把标签当作浮点深度。v1 草稿保留原图和编辑参数；不信任旧外部模型的深度缓存，重新从原文件读取原生深度或调用系统识别。缓存损坏时保留原图与参数并重新分析。当前格式提供长度/维度一致性检查，不是加密归档或面向不可信远端文件的安全格式。

## 接入正式项目

业务代码仅 Swift，使用系统 SwiftUI、Vision、Core Image、ImageIO、AVFoundation、Photos/PhotosUI。可把 Core 和 Imaging 作为处理模块接入已有编辑 Recipe；录屏参考 UI 与处理引擎分离。

第一版不做真实场景三维重建、失焦恢复、视频、实时相机、手工笔刷精修、多项目草稿列表或遮挡补全。要提高透明物体、发丝与背景遮挡处质量，需要独立实测和后续改进，不能由“无下载依赖”推导出“与参考软件同算法/同画质”。
