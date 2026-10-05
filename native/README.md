# AskInk — iPad 原生独立版

项目已移除网页版与 Node.js 服务。安装后阅读、书写、本机识别无需电脑服务；AI 问答需要设备联网。

## Library 与阅读

首页只提供文档列表、导入和设置；打开文档直接阅读，返回 Library 保存笔迹。顶部没有常驻 AI 按钮，自动回答与答案显示设置收在文档菜单。第一次阅读显示一次问号书写提示。

## 使用规则

普通书写作为笔记。想提问时用 `? / ？` 结束，默认停笔 500–700 ms 后自动处理，无需点击发送。继续书写会取消尚未发送的识别。

最近笔画先经过轻量问号候选检查，候选才进行局部本机识别。确认识别文字以问号结尾后，才准备整段问题、附近正文和图像并调用 AI。不使用语义意图分类器。问号写法或识别失败可能漏触发，可以长按目标笔迹选择 `Ask ✦`。

高光长横线作为正文标记，不单独提问；高光笔写出的文字可以提问，同样需要末尾问号。120 秒内、垂直距离 120 点以内的附近标记优先定位正文，复杂圈画可能需要调整位置。

答案锚定到问题的 PDF 坐标，显示为浮层，不改变 PDF 布局。准备回答时显示小星光；新答案展示最多三行，10 秒后收为星光。点击展开原位置对话、查看来源和追问，点外面收起。滚动与缩放只更新位置，卡片字体保持屏幕尺寸。旧问答没有锚点，可从文档菜单的“回答记录”查看。

## 连接 AI

在“Settings → AI → Advanced”选择 OpenAI、Claude 或其他 OpenAI 兼容 API，填写自己的密钥及账户可调用的模型 ID。兼容服务需要填写完整 HTTPS 接口地址并启用视觉模型的图片输入。配置的默认模型 ID 不代表账户拥有权限。

密钥按服务保存在设备 Keychain。请求包含问题转录、原始手写裁剪图、附近正文文字和正文裁剪图，不上传整本 PDF。主问题失败不会循环调用；可使用重试入口。追问失败会保留输入。

## 书写与识别

默认书写引擎为 PencilKit，由系统采集 Pencil 输入并渲染。顶层为 Pen、Highlighter、Eraser、Lasso；Pen 内含默认 Monoline、Fountain、Pencil。高光笔使用真实宽度，不再额外乘 8 倍。橡皮默认为固定大小局部擦除，可切换整笔模式。每种工具独立记住粗细和颜色，粗细提供三个预设，颜色提供五个快捷色与自定义颜色。

自定义压力曲线、稳定度及笔尖参数没有有效的公开系统接口，界面不提供伪装为有效参数的滑块。压力、角度、预测与实际笔迹由 PencilKit 处理；旧自研画布、算法、对照页和残留参数已删除，App 只使用 PencilKit。

PDFPageOverlayViewProvider 为每页创建实现 InkEngine 协议的 PencilKitInkEngine，按页保存完整 PKDrawing，包括局部擦除遮罩。父 PDFView 不再修改 PencilKit 内部手势；手指滚动和缩放由 PDF 负责。OCR、正文准备与问号流程仍在原链路运行。

iPadOS 27 优先 Apple PKStrokeRecognizer，旧系统、语言不支持或无文字时回退内置 PaddleOCR。原始彩色笔迹用于视觉模型，细黑线图用于本机 OCR。普通笔记不持续 OCR；问号候选可能误判形状，本机识别结果才决定是否自动发送。

## 构建与验证

用 Xcode 打开 `AskInk.xcworkspace`，选择自己的 Team、Bundle Identifier 和 iPad 构建安装。换开发电脑时在此目录执行 `pod install`。最低 iPadOS 17。

```sh
swift test --package-path native
```

原生回归测试覆盖渲染连续性、分块、触点修正、压力滤波、最终简化、问号规则、卡片位置和多模态请求。模拟器与 iPad 架构无签名编译已验证；没有调用付费模型。

真实 Pencil 延迟、手掌误触、问号识别率、答案在滚动缩放后的对齐及 API 效果仍需在 iPad 上测试。没有据编译结果宣称达到 Goodnotes 手感。支持本机检索、套索和合并笔迹的 PDF 导出；iCloud 同步、AskInk 托管 AI 与订阅尚未接入。

详见 [架构](AI-DESIGN.md)与[界面](UI-DESIGN.md)。

PencilKit 接口、工具映射与迁移边界见 [INK-ENGINE.md](INK-ENGINE.md)。

## 确认 iPad 已更新

打开 `AskInk.xcworkspace`，选择 AskInk scheme 和实际连接的 iPad，使用 Product → Run（⌘R）安装运行。Product → Build（⌘B）只编译，不安装；无签名的 generic iOS 构建也不会更新设备。当前版本为 0.1.1 (2)，可在 Settings → About 查看版本及 Writing Engine: PencilKit。

本机个人配置继续使用 `com.aireader.personal`，避免因改 Bundle ID 创建另一份 App。无需卸载旧 App，也不要删除本地笔记。
