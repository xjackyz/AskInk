# AskInk v1 界面实现

完整产品规范见 [UI / UX Specification v1](UI-UX-SPEC-v1.md)。该规范取代此前的文档标签栏与固定多层工具栏设计。

核心流程：Read → Write → Ask → Keep reading。一级页面只有 Library 与 Reader；首次 Welcome 不要求账号、API Key 或订阅。Open a PDF 直接选择 PDF 并进入阅读；Try a sample 使用本地示例。

Reader 顶部使用 56 pt 单行 toolbar：返回、页面抽屉、书名、搜索、书签、More。窄窗口隐藏书名，书签进入 More。文档操作收在书名菜单和 Document Settings popover；Reading Appearance 直接打开 Reading 设置。Pages / Outline / Marks 共用左侧抽屉，Questions & Annotations 直接打开 Marks。搜索保持在 Reader 内。

笔工具栏浮在底部，可长按拖动吸附到左下、底部或右下；连续阅读时收为笔尖按钮，Keep Open 可固定展开。普通手写只是笔记，末尾 ? / ？ 经 500–700 ms 停笔与本机确认后才触发问答。Pencil 用于书写，手指用于阅读与缩放。

回答以附近的三行 margin note 出现，10 秒或滚动后收成 ✦。手动恢复回答也重新计时。横屏优先右侧、下方、左侧、上方；竖屏优先下方。展开后是横屏浮层或竖屏底部浮层，PDF 尺寸不变；显示问题、回答、来源与追问输入。展开期间隐藏笔工具栏和其他问题标记，关闭后恢复阅读。模型名称和 token 用量不出现在回答界面。

Library 顶部左侧是品牌与 My Library，右侧是搜索、导入与 More。主体包括最多三本 Continue Reading 与 PDF cover grid。书籍菜单提供打开、重命名、收藏、导出、分享、确认移除。PDF 导入入口只选择 PDF；AskInk Archive 恢复放在 Data & Privacy。

## 当前产品边界

- 当前是个人版：真实文档使用 Advanced 中配置的自带 AI 连接；本地示例无网络调用。尚未提供 AskInk 托管服务。
- 未配置 StoreKit 产品、收据验证与服务端额度，订阅、购买恢复和 quota paywall 尚未实现，不展示假购买按钮。
- 笔触使用 PencilKit 实际支持的笔型；高级设置只暴露有效控制，不提供无效压感或稳定度滑块。
- 云端全书总结不再出现在 Reader 菜单；当前主流程只发送问题与相关上下文。
- 原始 PDF、合并手写的 PDF 和包含可编辑笔迹及问答的 Archive 可导出。

## 验证

算法回归测试与 iPad 模拟器架构编译用于检查触发规则、位置计算与 SwiftUI 编译。Pencil 延迟、手掌遮挡、系统 Scribble、横竖屏键盘行为和实际 AI 回答仍需设备验证。

## 当前书写工具

浮动笔盒的顶层只有 Pen、Highlighter、Eraser、Lasso。Pen 点开选择 Monoline、Fountain、Pencil，默认 Monoline；不提供画笔入口。宽度是按工具区分的三个预设，颜色为五个快捷色与自定义，各工具独立记住配置。橡皮再次点击可切换局部/整笔，局部是默认模式。PencilKit 处理压力与稳定，Advanced 中不显示没有实际效果的参数滑块。
