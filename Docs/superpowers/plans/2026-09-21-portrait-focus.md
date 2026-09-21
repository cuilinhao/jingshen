# 人物选择景深 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有Demo实现 V3 深度、1–4人点击选择与干净的分层虚化。
**Architecture:** 深度与独立人物蒙版同时存储。纯Swift核心计算选择与层顺序；CoreImage与CPU边缘延展负责合成。当前主执行者实施，独立探针验证模型，最终独立代码审查。
**Tech Stack:** Swift 5 / iOS17 / CoreML / Vision / CoreImage / XCTest。
**Spec:** Docs/superpowers/specs/2026-09-21-portrait-focus.md

## Global Constraints
- iOS17起，无新增外部SDK、无网络推理。
- 直接在用户指定目录修改，保留既有 project.pbxproj 改动；不推送、不发布。
- 人物编号不编码为深度，原图与模型缓存使用SHA256隔离。
- 1–4人；不可靠的分割明确降级提示；不伪装支持拥挤场景。
- 中文提交信息；代码先用行为测试观察RED，再实现GREEN。

## Review Focus
- 同深度两人仍能独立选择：Task1 / Task3 的合成图及核心测试。
- 前景遮挡后排选中人：Task3 的层顺序与扩散测试。
- 旧草稿与编号重排：Task1 / Task4 的缓存身份及重选测试。
- 竖图补边、左右上下翻转：Task2 的输入与深度映射测试。
- 切图/快速选人/禁用效果：Task3 / Task4 的缓存及保持像素测试。

### Task 1: 人物选择核心与持久化
**Files:** Core/PortraitAnalysis.swift, EditRecipe.swift, DraftStore.swift; Tests/DepthCoreTests/PortraitFocusTests.swift。
**Interfaces:** PortraitAnalysis(segmentation:sourceSHA256:imageSize:); matches(...); selectedPerson(at:currentID:); layers(depth:selectedID:focusPoint:); SavedDraft.portrait。
- [ ] 写两人同深度互换、空白保持、软边、层排序、缓存绑定和v4配方迁移测试。
- [ ] `swift test --filter PortraitFocusTests` 观察新接口缺失或行为失败。
- [ ] 实现独立人物缓存、选择、稳健焦深和 layer plan；schema升级到5并兼容旧版。
- [ ] `swift test` 通过并记录。

### Task 2: V3 CoreML和人物分析
**Files:** Imaging/OfflineDepthEstimator.swift, NativeSubjectSegmenter.swift, PhotoPipeline.swift; Core/InferredDepth.swift; Resources/Models, ModelInfo.json; Tests/IOS/CoreMLSmokeTests.swift, ImagingTests.swift。
**Interfaces:** DepthEstimating保持原接口；PersonAnalyzing.analyze返回可选分割；PhotoPipeline.prepare(...cachedPortrait:)；ModelChoice指定V3/V2。
- [ ] 添加V3实际接口、等比补边/反映射、旧模型缓存失效、人物缓存测试，并观察失败。
- [ ] 完整模型入Sources；预处理RGB255，depth取逆数，读取strides；保留V2对照入口。
- [ ] 原图分割每个人，检测失败/拥挤不阻断深度；加载缓存与原生深度同时处理人物。
- [ ] 编译Apple SDK并运行模型/流水线测试，记录真实执行平台。

### Task 3: 分层合成与边缘延展
**Files:** Imaging/PortraitRenderer.swift, DepthRenderer.swift; Tests/IOS/PortraitImagingTests.swift。
**Interfaces:** PortraitRenderer.render(image:portrait:depth:recipe:photoID:radius:); render/preview接收可选portrait；选择进入缓存key。
- [ ] 合成两种颜色/棋盘人物的测试：同深度切换、清晰人物颜色不泄露到背景、前景扩散在选中人前面、关闭效果像素不变。
- [ ] 观察RED，背景有限边缘补色，连续深度背景虚化，按远近预乘alpha合成人物。
- [ ] 缓存图片相关准备结果，选人仅重绘；输出轮廓只供UI。
- [ ] 运行Apple图像测试并输出人工可检查的合成结果。

### Task 4: 交互、集成和交付验证
**Files:** State/EditorModel.swift, UI/PhotoCanvas.swift, EditorPanel.swift, DepthEditorView.swift; project.pbxproj; Scripts/validate_project.py; Tests/test_*; README和验证文档。
**Interfaces:** selectedPersonID保存与恢复；可选outline预览；preview缓存key增加选择；非人物照片保持自然深度。
- [ ] 添加选择变化/恢复/无人物分支的行为测试并观察RED。
- [ ] 集成选人、轮廓反馈、说明、重置和裁切行为，保留latest-request-wins。
- [ ] `swift test`、`python3 -m unittest discover -s Tests`、Xcode构建和模拟器图像测试。
- [ ] 独立审查最终diff，修复重要问题；写明真机与真实人物样片尚未验收。
- [ ] 仅提交本次改造文件，已有用户配置改动保持未提交；保留原目录可直接打开的结果。
