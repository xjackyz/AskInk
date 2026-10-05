# AskInk

**A Pencil-first reader with document-aware AI.**

AskInk 把 AI 作为深度阅读的一层能力。PDF 是第一个支持的格式；普通书写作为笔记，用 `? / ？` 结束来提问，答案锚定在笔迹旁。全文提取、索引和上下文规划在本机完成，当前版本直接连接用户配置的 AI 服务。

格式无关的数据层及实现边界见 [DocumentGraph 与上下文规划](native/DOCUMENT-ARCHITECTURE.md)。

## 完整项目内容

- `native/AskInk/`：SwiftUI 界面、PDF 阅读、PencilKit 书写画布、防手掌误触、本机识别和 AI 请求。
- `native/AskInk.xcworkspace` / `native/AskInk.xcodeproj`：Xcode 工程与构建入口。
- `native/Models/`：随 App 内置的 PaddleOCR 检测、识别 ONNX 权重和配套 YAML。
- `native/Tests/`：原生算法与多模态请求回归测试。
- `native/ThirdPartyNotices/`：第三方许可与模型来源记录。
- `handwriting/`：开发者离线评估脚本。

## 构建安装

需要 Mac、Xcode 27 SDK 和 CocoaPods；App 最低 iPadOS 17。

```sh
cd native
pod install
open AskInk.xcworkspace
```

在 AskInk target 的 Signing & Capabilities 选择自己的 Team，并设置唯一 Bundle Identifier；普通 Apple 账号可通过 Personal Team 在自己的 iPad 上测试。
个人签名也可写入不提交的 `native/AskInk.local.xcconfig`：

```xcconfig
ASKINK_DEVELOPMENT_TEAM = YOUR_TEAM_ID
ASKINK_BUNDLE_IDENTIFIER = com.yourname.askink
```

App 设置中选择 OpenAI、Claude 或 OpenAI 兼容服务，填写自己的 API Key 和账户可调用的模型 ID。密钥保存在设备 Keychain，仓库没有内置密钥。AI 问答需要 iPad 联网；阅读、书写、本机识字可离线运行。

## 识别与回答

iPadOS 27 优先 `PKStrokeRecognizer` 直接识别笔画；旧系统、语言不支持或识别不可用时回退 PaddleOCR。AI 同时接收转录草稿、原始手写裁剪图、正文文字和正文裁剪图，数学问题不只依赖 OCR。

## 测试

```sh
swift test --package-path native
```

真机手写准确率、笔触延迟及付费 API 效果仍需实测。构建成功不代表已达到 Goodnotes 的手感。

详细安装与功能见 [原生版说明](native/README.md)，架构见 [AI 设计](native/AI-DESIGN.md)、[书写引擎](native/INK-ENGINE.md)和[界面设计](native/UI-DESIGN.md)。
