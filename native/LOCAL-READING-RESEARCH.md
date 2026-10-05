# AskInk 本机阅读能力与实现记录

核对日期：2026-10-04。依据 Apple 官方资料和本机 Xcode 27 SDK；区分已经接入的能力与后续候选。

## 可以使用的系统 SDK

| SDK | 适合 AskInk 的用途 | 当前状态与边界 |
| --- | --- | --- |
| PDFKit | PDF 文字与坐标提取、原文选择、目录、页内定位、阅读位置恢复 | 已用于索引、下划线绑定和原文跳转；文字层的阅读顺序仍需复杂版面验证 |
| PencilKit / PKStrokeRecognizer | 直接识别笔画，搜索识别文字对应的笔迹 | 原项目已在 iPadOS 27 使用；检查语言支持，无置信度时不伪造；旧系统回退 PaddleOCR |
| Vision / VNRecognizeTextRequest | 扫描 PDF 的本机 OCR，保留识别框 | 本次接入扫描正文索引；不等同于可靠的手写数学识别 |
| Vision / RecognizeDocumentsRequest | 段落、列表、表格等文档结构识别 | iPadOS 26 起的后续候选；本次尚未接入结构化文档解析 |
| NaturalLanguage / NLTokenizer | 按句分块，避免摘要输入从句子中间切断 | 本次用于总结分块；超长句完整拆分，不丢弃尾部 |
| NaturalLanguage / NLEmbedding、NLContextualEmbedding | 端侧语义检索候选 | 尚未接入；sentenceEmbedding 可返回 nil，需检测语言与模型可用性；contextual embedding 不是现成的检索排名器，需评估池化、中文和领域效果 |
| Foundation Models / SystemLanguageModel | 本机分块摘要和摘要合并 | 本次接入；iPadOS 26+，需设备符合资格、启用 Apple Intelligence、模型准备好且支持目标语言；不可用时明确显示原因 |
| Core ML / Core AI | 部署自选 embedding、分类和生成模型 | 后续候选；新 Core AI 路径需按系统版本和模型支持核对，本次未替换已有 ONNX Runtime |
| Core Spotlight | 从系统搜索找到书籍和笔记 | 后续候选；与阅读页内检索分开设计，用户可控制索引范围 |

Apple 官方参考：

- [Foundation Models 概览](https://developer.apple.com/documentation/foundationmodels)
- [Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/)
- [Vision 文档结构识别](https://developer.apple.com/videos/play/wwdc2025/272/)
- [Natural Language 多语言模型](https://developer.apple.com/videos/play/wwdc2023/10042/)
- [PDFKit 导航](https://developer.apple.com/documentation/pdfkit/navigation)
- [PKStrokeRecognizer](https://developer.apple.com/documentation/pencilkit/pkstrokerecognizer)
- [Core AI](https://developer.apple.com/documentation/coreai)

## 本次接入的阅读流程

打开书籍 → 后台提取 PDF 文字 → 无文字层页面使用 Vision OCR → 保存带页码与矩形坐标的本机索引。

在文档菜单打开“全文索引与总结”。索引支持中英文关键词匹配、只搜索当前页之前的正文、点击命中区域跳转及返回原阅读位置。当前排名是词项匹配与频率加权，不声称已实现向量语义检索。

提问时，从已就绪的前文索引检索最多三个候选片段；候选带稳定 ID 与 PDF 文件页序号。回复中可以展开候选原文并跳转。检索候选不自动视为答案的已验证引用。

普通钢笔下划线需同时满足水平笔形、正文横向重叠和正文基线位置，才从问题笔迹中分离。页边横笔和减号保留。近期划线或高光优先决定原文，文字层可提取划线覆盖的文字，附近补充同栏上下文。扫描页面要先完成当前页 OCR；OCR 坐标不是逐字选择的保证。

划线标记也是笔迹分组的边界，避免在同一位置先写笔记、随后划线提问时，把旧笔记并入新问题。下划线允许轻微弯曲及从右向左书写。

使用方式：先划线／高光，再在附近写问题，以 `? / ？` 结束。自动识别失败时长按问题笔迹选择 Ask。原始手写图仍交给视觉回答模型核对。真实字迹、短划线、跨行划线、双栏、旋转页和扫描质量仍需真机验收。

## 总结与 token 用量

- 本机总结用 SystemLanguageModel，不自动改用云端模型；模型不可用时显示具体原因。
- 用户可明确选择已配置的云端 AI；首次全文总结会发送所有可识别正文并产生 API 用量。
- 先按句和字符预算处理所有正文块，再逐层合并摘要。没有文字的页明确列出，不将部分正文包装成完整覆盖。
- 每个成功摘要节点写入缓存，取消或失败后重试复用；按模型、提示版本、输入内容及文档变更信息区分缓存。
- 问答正文有字符预算；同页历史及追问历史总计最多 1400 字符，前文候选最多三条，每条发送最多 650 字符。
- 划线提问的正文图裁剪到附近少量行；手写原图保留。没有通过压缩 JPEG 文件大小声称减少图像 token。
- 文本追问不重复上传旧手写图；实际输入／输出 token 在服务返回 usage 时保留并显示。
- 回答输出上限减少失控长回复，但上限本身不代表实际 token 节省比例。字符预算也不是精确 token 计数。
- 全文总结的首次处理仍有成本；缓存与分层结构主要减少重复阅读时的重新处理，不能保证第一次比单次长上下文更便宜。

## 开源与论文参考

1. [LlamaIndex TreeSummarize](https://github.com/run-llama/llama_index/blob/main/llama-index-core/llama_index/core/response_synthesizers/tree_summarize.py)：分块摘要再自底向上合并。适合参考算法和在开发机做对照；本次用 Swift 实现类似的分层流程，没有引入 Python 依赖。
2. [RAPTOR 论文](https://arxiv.org/abs/2401.18059)与[官方代码](https://github.com/parthsarthi03/raptor)：将原文与不同层级的摘要组织为检索树。适合后续“前文概念 + 章节概览”；本次没有实现 RAPTOR 的聚类与完整检索树。
3. [Docling](https://github.com/docling-project/docling)：复杂 PDF 阅读顺序、表格和公式解析的开发机基线。支持本地运行，但不是直接可嵌入本项目的 iPad 原生 SDK；解析也不自动完成总结。
4. [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)：自选端侧语言、视觉和 embedding 模型的 Swift 实现参考。可在 Apple 系统模型不符合需求时评估，仍需真机内存和发热测量。
5. [Apple Intelligence Foundation Language Models: Tech Report 2025](https://arxiv.org/abs/2507.13575)：端侧模型设计背景。研究模型能力与开发者可调用 API 的能力需分别核对。

## 验证边界

本次增加下划线位置、横笔／减号保留、中文／英文前文检索、历史预算、超长 Unicode 分块覆盖、摘要请求不截断以及 API usage 解析的回归检查。通过编译只能确认 API 和类型接入；未调用付费 API，也未在支持 Apple Intelligence 的真实 iPad 上验证全文摘要质量。当前机器没有可启动的 iPad 模拟器设备，不能宣称已完成界面运行检查。

最终验证：48 项 Swift 算法／请求回归测试通过，最终合并界面的 iOS Simulator 目标无签名编译通过，`git diff --check` 通过。期间也完成过 iOS 真机架构无签名编译；最终界面重构后的整包运行仍需设备验证。
