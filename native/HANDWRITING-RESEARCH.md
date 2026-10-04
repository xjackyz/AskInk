# iPad 手写渲染与识别方案调研

> 历史研究记录，不代表当前实现。当前版本已改为自定义 UIKit 书写与内置 v6 small 本机 OCR，见 [现行设计](AI-DESIGN.md)。


调研日期：2026-10-04。以下记录调研时的基线与建议。后续已实现分组、后台存储、Apple／Google 笔画识别、PaddleOCR 对照和样本评估，见 [当前实现与使用](../handwriting/README.md)。尚未进行真机手感或个人字迹准确率测量。

## 结论与优先级

第一轮保留 PencilKit 作为渲染基线，优先比较直接读取笔画的识别器。iPadOS 27 上先测 Apple PKStrokeRecognizer，旧系统候选是 Google ML Kit Digital Ink Recognition。需要完全开源、可自部署的图片识别备选时，比较 PaddleOCR PP-OCRv5 与 PP-OCRv6。轨迹与图像融合是后续研究方向，不能把论文结果当作当前产品性能。

“写得舒服”与“识别得对”分别验收。在线识别中的“在线”指有笔画时间序列，并不意味着联网。PencilKit 本身不开放任意自定义笔刷算法；若系统笔刷确实无法满足手感，再用 Inkable 与 MaLiang 做自定义引擎实验。

## 当前实现与缺口

- `PDFReader.swift` 用 PKCanvasView / PKInkingTool 渲染，没有自己实现平滑或压力曲线。原始 PKDrawing 持久化保存，识别时却只给 Vision 一张图片，因此识别器没有使用笔顺或时间信息。
- 最近笔画归组只比较相邻笔画的开始时间（8 秒阈值），没有比较上一笔结束到下一笔开始的间隔，也没有空间行聚类。连续写多个问题可能合并；回头补笔可能错组。
- 以宽 > 80、高 < 12 的包围盒规则过滤长横线，可能误删字的笔画、减号或分数线。不能仅凭该规则判定不是文字。
- 自动保存虽然将写文件放到串行队列，但 `PKDrawing.dataRepresentation()` 在进入队列前执行，当前调用点在主线程；大笔迹可能产生卡顿，需测量再调整。加载也使用队列同步等待。尚无 Instruments 或真机数据，不能声称已证明卡顿来源。
- Vision 目前只取每行一个候选，以最小置信度汇总；没有候选对比或置信度校准。云端 high/其他映射到固定数值也不是实际正确率。

## 渲染候选

| 方案 | 已核实的能力 | 对本项目的用途与限制 |
| --- | --- | --- |
| [Apple PencilKit](https://developer.apple.com/documentation/pencilkit/) | 原生低延迟画布、Pencil 输入、系统笔刷和笔画数据 | 第一轮渲染基线；系统框架而非开源引擎，真实手感需要与同一设备上的 Notes/Goodnotes 比较 |
| [Inkable](https://github.com/adamwulf/Inkable) | MIT；合并采样、预测点、估计属性更新、增量 Bézier 路径 | 适合研究自定义输入管线；不是完整笔记应用，也不提供文字识别。README 中可变宽度笔迹仍列为 TBD |
| [MaLiang](https://github.com/Harley-xk/MaLiang) | MIT；Metal、Bézier、压力宽度、纹理、Pencil、撤销与保存 | 自定义笔刷实验候选；README 能力不等于在本项目中已验证的延迟或可靠性 |
| [1€ Filter](https://gery.casiez.net/1euro/) | 2012 年的速度自适应滤波，平衡抖动与延迟，有实现 | 仅用于自定义采样管线候选；过度平滑会损伤汉字折角，不应盲目叠加到 PencilKit |

若采用自定义引擎：用 coalesced touches 保留采样，predicted touches 只临时显示，新实测点到达后替换预测，并正确处理延迟到来的压力/位置修正。预测点不作为最终保存或识别数据。尽量只重绘当前变化区域，渲染与识别分别调度。依据：[Apple 预测触点文档](https://developer.apple.com/documentation/uikit/minimizing-latency-with-predicted-touches)、[WWDC19 PencilKit](https://developer.apple.com/videos/play/wwdc2019/221/)。

## 可落地的识别候选

### Apple PKStrokeRecognizer

[WWDC26 官方演示](https://developer.apple.com/videos/play/wwdc2026/203/)说明：iPadOS 27 起提供笔画识别，完全在设备运行，模型随系统提供，支持 29 种语言并演示中文；模拟器识别仅支持使用拉丁字符的语言，所以中文必须用真机验证。

本机 `/Applications/Xcode.app/.../PencilKit.framework/Modules/PencilKit.swiftmodule/arm64e-apple-ios.swiftinterface` 中已经确认：`@available(iOS 27.0, ...)` 的 `PKStrokeRecognizer`、`updateDrawing`、`recognizedText(strokeIDs:)`、`supportedLanguages`。此前只检查头文件而判定本机没有接口是错误结论，已纠正 AI-DESIGN.md。

优点是可直接使用 PKDrawing，减少图片转换；限制是系统版本和设备实际语言支持。尚未调用该 API，也没有中文准确率实测。

### Google ML Kit Digital Ink Recognition

[官方介绍](https://developers.google.com/ml-kit/vision/digital-ink-recognition)与 [iOS 集成文档](https://developers.google.com/ml-kit/vision/digital-ink-recognition/ios)提供成熟的本机 SDK：输入笔画的 x/y/t，下载语言模型后离线识别，返回候选；可以设置书写区域与已写文字的前文。这里的前文不是 PDF 内容，不能借正文猜改用户问题。

[语言列表](https://developers.google.com/ml-kit/vision/digital-ink-recognition/base-models)包括 `zh-Hani-CN`、`zh-Hani-HK`、`zh-Hani-TW`。SDK/模型不是本文所说的完全开源方案，示例代码许可与 SDK/模型条款应区别对待。iOS 文档使用 CocoaPods 集成；首次模型下载、字迹回补、跨行和中英混写均需实测。

### PaddleOCR

[官方仓库](https://github.com/PaddlePaddle/PaddleOCR)采用 Apache 2.0；具体选定模型权重和第三方依赖还应记录各自许可。

[PP-OCRv5 官方指标](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/algorithm/PP-OCRv5/PP-OCRv5.en.md)包含中文手写测试，并明确区分 server/mobile；这是图片 OCR，不读取 Pencil 笔顺。[2026 CVPR 论文](https://arxiv.org/abs/2603.24373)公开代码与模型。

本次查到已有更新的 [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/algorithm/PP-OCRv6/PP-OCRv6.en.md)，官方提供 tiny/small/medium 与多语言模型。先把 v5 与 v6 都列入同一字迹样本比较，不能从综合 OCR 或工业文字数据断定 v6 对个人潦草字更好，也不能把 Apple M4 桌面性能直接解释为 iPad 性能。

第一轮适合电脑/服务端实验，选出胜者后再做端侧部署可行性。ONNX/Core ML 转换、算子支持、动态长度、词表、检测与裁切、内存和功耗尚未验证。不要因为名称包含 mobile 就认为可直接塞进 Swift 应用。

## 近期有作者代码的研究

1. [2025：轨迹与图像融合 Transformer](https://arxiv.org/abs/2506.20255)，[作者代码 HATChar-Classifier](https://github.com/lodhayush/HATChar-Classifier)标注 MIT。用字形图片和 x/y/pen 序列融合；论文基准主要是 IAMOn-DB、VNOn-DB 与 ISI-Air，并非中文自然句测试。值得借鉴双模态输入，作者公开仓库也不能视作现成中文句子 SDK。
2. [2026：SW-PS + LRU](https://arxiv.org/abs/2602.01533)，[作者代码](https://github.com/ling17154/Character_Recognition)。针对旋转输入，将滑动窗口路径签名与线性循环单元结合。实验是数字、26 类大写字母和 52 类中文部件；不是数千汉字与中文句子的识别结果。仓库首页未展示明确许可证，因此只列为研究参考，未批准其代码用于产品。本文未对作者仓库进行全量许可证审计。

这些方法首先解决识别，不直接决定屏幕上笔尖跟随的延迟。第一轮无需自己训练模型；保留笔画时序与原始字形，方便之后对照实验。

## 第一轮实现与验收顺序

1. 修正笔画归组：以结束到开始的停顿、空间位置、行结构联合判断；圈线与文字分类保留撤回余地。识别只处理新变更区域，擦除/撤销会使对应结果失效。
2. 保留原始 PKDrawing 作为唯一笔迹事实；图片预处理只作用于识别副本。引入统一识别接口，分别跑 Apple / Google / Vision，返回来源、耗时、文本与可用候选；不把不同引擎的置信度直接比较为同一概率。
3. 识别异步排队、合并重复请求，笔迹变化后丢弃过时结果；优先保障书写主线程。对保存序列化与加载时机先测量，再优化。
4. 用个人真实字迹录制 50–100 个短问题：中文、英文术语、混写、否定词、数字、连笔、跨行、回补、划线、擦除。保存原始笔画和人工逐字标注。调参集与固定留出集分开；不要仅挑清楚的字。
5. 对同一 iPad、Pencil、PDF、缩放与笔宽比较当前实现、优化版本、Notes 与 Goodnotes。记录笔尖到墨迹的可见延迟（高速摄影）、掉帧/主线程阻塞（Instruments）、整句完全正确率、字符错误率、否定词/数字错误、识别 p50/p95 耗时和用户手感。60 Hz/120 Hz 设备分开报告；16.7/8.3 ms 是帧预算，不是已达到的笔尖延迟。

是否达标由真机体验与固定测试集共同决定。当前没有样本结果，不能保证达到 Goodnotes 或承诺固定准确率；本次只完成调研和接口可用性核对。
