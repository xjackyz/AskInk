# 独立 iPad 书写与识字设计

## 书写

自定义 UIKit 画布接收 Pencil 的 coalesced touches，按时间排序去重。1 Euro 速度自适应低通滤波可调 0–100%，默认 15%；低速抑制抖动，高速提高截止频率降低拖尾。参数是本项目自己的调校，不是 Goodnotes 私有参数的复刻。

相邻滤波点采用 Catmull–Rom 转 cubic Bézier，切线长度上限为段长的 1/3，减少汉字拐角过冲。曲线采样为变宽矢量带；每 64 段形成保留路径块，跨块的所有更新均发布；属性修正只重算受影响的块，移动时不重建整页。笔带多边形和圆端点使用相同方向，避免 nonzero 填充互相抵消。预测触点仅画临时尾迹，下一个实际事件替换，抬笔或取消立即移除，不进入存储或 OCR。

圆珠笔恒定宽度。钢笔使用有界线性压力映射、轻微倾斜/笔杆旋转笔尖效果。画笔压感幅度较大，速度影响最多增加 12%，沿起收笔短距离渐细。Pencil Pro rollAngle 仅在 iPadOS 17.5 以上读取；旧系统取 0。荧光笔恒宽。橡皮使用点到笔画线段距离命中并删除整笔，撤销按一次手势恢复。

笔迹以 PKDrawing 保存滤波后的实测点、时间、压力、倾角和已计算宽度。不是原始触点录制器，也不保存预测点。实时显示是自定义矢量路径，OCR 快照使用兼容 PKDrawing 的黑字白底图像。旧系统笔迹的纹理、遮罩或笔刷外观不保证在新自定义画布中完全一致。

## 识别

iPadOS 27 优先使用 PKStrokeRecognizer 直接识别所选 PKDrawing，检查所选语言支持并在支持时加入英语；当前 API 没有提供识别置信度。每个快照创建独立 recognizer，避免异步结果读取时 drawing 被其他请求覆盖。保留 recognitionVersion 与搜索返回的文字位置、笔画 UUID。

旧系统、语言不支持或 Apple 没有返回文字时，回退随 App 打包的 PP-OCRv6 small ONNX 检测与识别流水线。PaddleOCR 使用细黑线图，原始彩色 PKDrawing 裁剪图另行保留用于视觉模型，不让归一化损坏公式证据。

识别不接收 PDF 正文；版本与取消检查阻止旧结果覆盖。两个本机引擎均失败或转录为空时，不编造问题，保留空转录与笔迹图交给视觉模型判断。

## 问答

停笔默认 2 秒后，先在本机识别新写的那句话，再将转录草稿、原始手写裁剪图、附近正文图像、正文文字和同页最近 4 次问答直接从设备发送到 OpenAI Responses。developer 指令约束区分引用与推断、忽略资料中的注入指令、模糊问题先澄清；strict JSON schema 校验回答结构。API Key 在个人设备 Keychain；无需电脑网关。未来收费发行需另行确定账户、计费与服务端密钥管理，当前个人版本不内置公共密钥。

## 来源与实现边界

- [1 Euro Filter 原论文与实现](https://gery.casiez.net/1euro/)：自适应滤波，不是神经模型。
- [Apple 预测触点](https://developer.apple.com/documentation/uikit/minimizing-latency-with-predicted-touches)：输入与临时尾迹机制。
- [官方 PaddleOCR iOS 部署](https://github.com/PaddlePaddle/PaddleOCR/tree/main/deploy/ios_demo)：本机 Swift/ONNX/OpenCV 检测识别流水线，已集成。
- [Goodnotes 笔刷设置](https://support.goodnotes.com/hc/en-us/articles/7353756785679-Write-and-customize-ink-with-the-Pen-tool)：公开压感、笔刷和稳定度功能；没有公开完整 Bézier 或压感公式，不能称本实现复制了其算法。

不宣称这些组件构成最前沿的个性化手写模型，也不宣称已经达到 Goodnotes 的延迟与准确率。之前研究文档中的其他候选没有进入当前运行链路。

## 自动触发与请求归属

Pencil 每次抬笔重置停笔计时；落笔、擦除、翻页和进入后台取消未开始的识别。高光正文标记不单独触发问答。识别阶段校验笔迹版本，AI 发送后冻结原书、原页和问题，后续书写进入下一批。每书每页排除已经发送的笔画创建时间，避免重复发送上一句。忙碌时保留待处理状态，当前请求结束后恢复停笔计时。失败不自动循环重试。识别文字直接发送给已配置的 AI，无逐次授权或确认弹窗。

书写链路缺陷与修复依据见 [WRITING-AUDIT.md](WRITING-AUDIT.md)。系统取消时保留实测点，丢弃预测尾迹；正常完成先通知笔迹变化，再启动停笔计时。
