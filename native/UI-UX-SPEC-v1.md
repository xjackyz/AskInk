# AskInk — UI / UX Specification v1

## 0. 产品原则

AskInk 是一个 **Pencil-first PDF reader for deep reading**。

核心体验只有：

**Read → Write → Ask → Keep reading**

普通手写永远是笔记。

只有当一段新手写以：

`?`

或：

`？`

结束时，AskInk 才认为用户在向 AI 提问。

AI 不拥有独立页面，不存在常驻 AI sidebar，也不改变 PDF 的页面尺寸。AI 回答永远附着在对应 PDF 位置附近。

---

# 1. 整个 App 的页面结构

整个 v1 只有两个一级页面：

| 一级页面 | 用途 |
|---|---|
| Library | 找书、导入书、继续阅读 |
| Reader | 阅读、手写、提问 |

其他全部是临时界面：

| 临时界面 | 形式 |
|---|---|
| PDF 目录 | 左侧抽屉 |
| 搜索 | 顶部展开 |
| Settings | Sheet |
| AI 完整回答 | PDF 上方浮层 |
| AI 后续对话 | 同一个浮层 |
| Paywall | Sheet |
| Export | Popover / Sheet |
| 文档设置 | Popover |

**没有底部 Tab Bar。**

不要：

`Library / Notes / AI / Profile`

这种结构。

AskInk 打开以后，用户要么在找书，要么就在读书。

---

# 2. 第一次下载打开

## Screen 1 — Welcome

首次打开不要求：

账号、Apple 登录、API Key、订阅、AI 模型选择。

背景使用 AskInk 的暖白：

`#FAF8F3`

页面中央偏上：

AskInk Logo

下面：

**Read. Write. Ask.**

副标题：

**Write where you're stuck. AskInk answers right there.**

页面中央展示一个极简单的演示：

```text
The gradient points in the
direction of greatest increase.

                  why?
                    ✦
```

不要播放复杂 onboarding carousel。

屏幕下方两个按钮：

**Open a PDF**

为蓝色 primary button。

下面：

**Try a sample**

为无背景 secondary button。

最底部很淡的小字：

`Your PDFs and handwriting stay on your iPad.`

这里不提 GPT、不提模型、不谈技术。

---

# 3. 用户点击 Open a PDF

直接调系统 Files document picker。

用户选择：

`Calculus.pdf`

后立刻进入 Reader。

同时：

PDF 被复制/保存进入本地 Library。

不再弹：

“Import successful”

这种无意义提示。

直接开始阅读。

---

# 4. 第一次进入 Reader

PDF 出现以后，只出现一次非常轻量的教学提示。

页面底部：

```text
Write normally with Pencil.

End a question with ? to ask.
```

旁边一个：

`Got it`

或者用户开始写以后自动消失。

第二个小提示只在第一次 Pencil 接触页面时出现：

```text
Pencil writes.
Finger scrolls and zooms.
```

之后永远不再出现。

Apple 的 HIG 本身也建议 Pencil 应该落笔即可产生标记，而不是要求用户先切换到一个特殊模式。

---

# 5. Reader 是整个产品最重要的页面

基本结构：

```text
┌──────────────────────────────────────────────┐
│ ‹   ▣      Calculus III        ⌕  ♧   •••  │
│──────────────────────────────────────────────│
│                                              │
│                                              │
│                PDF PAGE                      │
│                                              │
│   The gradient points in the direction      │
│   of maximum increase...                    │
│                                              │
│                         why?                 │
│                           ✦ Because ∇f...    │
│                                              │
│                                              │
│                                              │
│                                              │
│              ┌────────────────┐              │
│              │ ✒︎ ▱ ⌫ ◯ ● ↶ ↷ │              │
│              └────────────────┘              │
│                                      42/312  │
└──────────────────────────────────────────────┘
```

PDF 永远占据绝大多数空间。

Apple 对 iPad 的设计建议也是最大化用户真正关心的内容，并尽量减少 modal 和 full-screen transition。

---

# 6. Reader 顶部 Toolbar

默认高度约：

**52–56 pt**

三组。

Apple 的 iPad toolbar HIG 本身也是 Leading / Center / Trailing 三块逻辑，并建议避免 toolbar 塞太多按钮。

### 左侧

最左：

`‹`

返回 Library。

右边：

`▣`

Pages / Outline。

点击以后从左边滑出约 280–320 pt 的 drawer。

---

### 中间

显示：

**Calculus III**

太长自动截断：

`Calculus III — Stew…`

点击书名弹出 document menu：

```text
Rename
Document Info
Export Annotated PDF
Share
Remove from Library
```

不要把这些按钮放在屏幕上。

---

### 右侧

依次：

`⌕` Search

`bookmark` Bookmark current page

`•••` More

More 里面：

```text
Go to Page
Questions & Annotations
Reading Appearance
Export
Document Settings
```

Search、Bookmark 属于频繁操作，因此留在主 toolbar。

Export、设置等低频行为放 menu。菜单本身就是 Apple 推荐的节省界面空间方式。

---

# 7. Toolbar 自动隐藏

用户连续滚动阅读约 1 秒：

顶部 toolbar 淡出。

用户：

单击 PDF 空白处

或者：

向上轻滑到页面顶部

toolbar 再出现。

这样纯阅读时：

**几乎整块屏幕都是书。**

---

# 8. 页码

右下角始终存在非常淡的：

`42 / 312`

默认 opacity 约 45%。

点击：

弹出：

```text
Go to page
[ 42          ]
```

并出现小型 page scrubber。

不要常驻一整条底部 page slider。

浪费垂直空间。

---

# 9. Finger 与 Pencil 的输入职责

必须完全固定。

| 输入 | 行为 |
|---|---|
| Pencil | 写字 / 高光 / 擦除 |
| 单指拖动 | Scroll |
| 两指 pinch | Zoom |
| 双击 PDF | Zoom in / restore |
| 单击空白 | Show / hide UI |
| 长按正文 | 系统文本选择 |
| Pencil 点击 UI | 操作 UI |

**Pencil 永远不能突然变成 scroll。**

**Finger 永远不会意外留下 ink。**

---

# 10. Pencil 工具栏

不要占据整个顶部。

使用一个：

## Floating Pen Palette

默认位置：

**屏幕底部中央上方约 24–32 pt。**

尺寸大约：

**48 pt 高。**

用户可以长按拖动它，把它吸附到：

左下、底部、右下。

这样左撇子和右撇子都可以调整；Apple 的 Pencil 指南也特别提醒不要让控制项长期被手掌挡住，并建议必要时允许重新定位。

---

# 11. Pen Palette 内容

展开状态：

```text
┌────────────────────────────────────┐
│ Pen | Highlighter | Eraser | Lasso │
│       ●    ━       ↶       ↷      │
└────────────────────────────────────┘
```

从左到右：

| 位置 | 控件 |
|---|---|
| 1 | Pen |
| 2 | Highlighter |
| 3 | Eraser |
| 4 | Lasso |
| Separator | |
| 5 | Current color |
| 6 | Current width |
| 7 | Undo |
| 8 | Redo |

不要放 AI。

不要放 Ask。

不要放 Chat。

---

# 12. Pen 设置

点击已经选中的 Pen：

出现小 popover。

内容：

```text
Pen
Ballpoint
Pencil
Brush

Thickness
●  ●  ●  ●

Color
● ● ● ● ●
```

稳定度、pressure curve 这种高级设置：

**不要放在这里。**

进入：

Settings → Pencil → Advanced。

正常用户不应该需要调滤波参数。

---

# 13. Pen Palette 收起

用户开始连续阅读时：

palette 自动缩成一个：

`pen.tip`

圆形按钮。

点击：

再次展开。

如果用户正持续批注，可以把 palette pin 住：

`Keep Open`

不要每次都自动关。

---

# 14. 普通书写逻辑

这是 AskInk 最重要的规则之一。

用户写：

```text
important
```

Nothing happens.

写：

```text
exam
```

Nothing happens.

写：

```text
remember this
```

Nothing happens.

写：

```text
gradient direction
```

Nothing happens.

这些全部只是：

**handwritten annotations。**

没有：

AI thinking

OCR popup

suggestion

sparkle

animation

任何东西。

书写必须感觉像普通纸。

---

# 15. 用户写问号

例如：

```text
why?
```

或者：

```text
为什么这里要除以 |v|？
```

或者甚至只写：

```text
?
```

这时开始 AskInk 核心流程。

---

# 16. Question Detection UI

用户写完 `?`。

约：

**500–700 ms**

没有继续写。

系统确认这是一个 question session。

这时候在问号旁边出现一个极小的：

`✦`

例如：

```text
why?  ✦
```

这就是：

**AI 正在理解。**

不要 spinner。

不要：

`Thinking...`

不要进度条。

不要弹窗口。

---

# 17. 用户继续写时

如果 `✦` 出现前或者刚出现后，用户继续下笔：

当前请求取消或暂缓。

系统重新等待。

因此：

```text
why?
because...
```

不会在写到 `?` 的瞬间马上发送。

必须经过短暂 idle。

---

# 18. 第一次真正使用 AI

只有第一次。

出现一个小 Sheet：

## AskInk AI

正文：

```text
To answer this question, AskInk sends:

• your handwritten question
• the nearby text
• a small image of the relevant area when needed

The full PDF is not uploaded.
```

下面显示：

**AI Provider: AskInk**

不要向普通用户展示：

OpenAI / GPT-6 / Claude。

按钮：

**Continue**

下面：

`Not Now`

用户 Continue 以后，以后不再问。

---

# 19. `?` 本身也算问题

这是很重要的设计。

如果用户只在某个公式旁边写：

```text
?
```

AskInk 将其解释为：

> Explain this.

Context Engine 根据：

问号坐标、附近正文、附近公式、最近 highlight

判断“this”是什么。

这是非常符合真实阅读习惯的功能。

---

# 20. Highlight + ?

如果用户先高光：

```text
The gradient points in the direction
of maximum increase.
```

然后附近写：

`why?`

那么高光内容拥有最高 context priority。

用户不需要：

选中 → Ask AI。

只需要：

**Highlight → 写 why?**

---

# 21. AI 回答怎么显示

不要传统 chat bubble。

不要大白框。

回答更像：

## AI Margin Note

例如：

```text
              why?

              ✦ Because ∇f points toward
                the fastest increase…
```

只有：

小 sparkle

+

2–3 行文字。

背景只有很轻的半透明暖白 blur。

没有明显 border。

没有标题：

`AI Answer`

没有模型名。

最大宽度约：

**240–300 pt**

---

# 22. Answer Placement

优先级：

**问题右侧 → 问题下方 → 左侧 → 上方**

系统寻找最近的可用空白区域。

尽量：

不遮公式

不遮用户笔迹

不遮正在阅读的正文。

如果实在没有空间：

使用一个很小的半透明 backdrop 覆盖 PDF。

但绝不：

把 PDF 页面撑大

插入新的 PDF 内容

改变 PDF layout。

---

# 23. Compact Answer

默认只显示约：

**2–3 行。**

例如：

```text
✦ Because a directional derivative
  measures change per unit distance…
                         More ›
```

如果回答已经完整：

不一定显示 More。

用户继续阅读即可。

---

# 24. 回答自动收起

回答出现后：

用户开始滚动，或者约 8–12 秒没有操作。

它缩成：

```text
why?  ✦
```

这样一本书有几十个问题以后，页面不会被几十张 AI card 塞满。

点击 `✦`：

恢复 compact answer。

---

# 25. 展开答案

用户点击：

回答文字

或者：

`More ›`

不要跳到 AI 页面。

出现一个浮在 PDF 上面的：

## Expanded Thread

Landscape：

宽约 **460–520 pt**

高最多屏幕 **65%**

尽量从问题附近展开。

Portrait：

从底部升起约：

**55–65% screen height**

PDF 始终在后面看得见。

---

# 26. Expanded Thread 内容

顶部：

```text
✦ AskInk                         ×
```

下面：

用户问题。

然后完整 AI 回答。

回答中的来源显示：

```text
Source · p.42
```

点击 Source：

关闭/缩小 Thread。

PDF 自动定位到对应 paragraph。

对应文字短暂 highlight。

---

# 27. Follow-up

Thread 最底部：

```text
Ask a follow-up…
```

这是系统 text field。

用户可以：

键盘输入

或者直接用 Apple Pencil Scribble 输入。

右侧：

`↑`

Send。

后续内容继续在这个 Thread。

但是：

关闭 Thread 以后，Reader 又恢复成：

```text
why? ✦
```

不留下巨大的 chat history。

---

# 28. Expanded Thread 顶部按钮

只有：

左侧 `✦ AskInk`

右侧：

`•••`

`×`

••• 里面：

```text
Copy Answer
Regenerate
Explain More Deeply
Change Answer Length
Delete Thread
```

不要出现模型切换。

---

# 29. AI 回答长度

默认：

## Short

AskInk 的回答应该像老师在书边写注释。

不是 ChatGPT essay。

设置里可以改：

```text
Answer Style

Short
Tutor
Detailed
```

默认必须：

**Short**

---

# 30. 如果 AI 出错

问号旁：

`!`

点击：

```text
Couldn't answer.

Retry
```

不要显示：

`HTTP 401`

`JSON parsing error`

`Model timeout`

之类开发者信息。

---

# 31. Offline

Pencil 和 PDF 阅读完全工作。

问题照样保留。

`?` 旁显示：

`cloud.slash`

点击：

```text
You're offline.

Retry when connected
```

不要阻止继续阅读。

---

# 32. 左侧 Page Drawer

点击顶部：

`▣`

左侧滑出 drawer。

顶部三个 segmented tabs：

```text
Pages | Outline | Marks
```

Pages：

PDF thumbnails。

Outline：

PDF chapter outline。

Marks：

用户的：

Highlights

Bookmarks

Questions

这里只用于“重新找到东西”。

不是一个知识管理系统。

---

# 33. Search

顶部点：

`⌕`

Toolbar 中间变成：

```text
‹   Search this PDF…           ×
```

搜索结果在左侧 drawer。

点击结果：

跳转页面。

搜索结束：

×。

不要离开 Reader。

---

# 34. Long Press 正文

用户长按 PDF text：

使用熟悉的 text selection。

Context menu：

```text
Copy
Highlight
Define
Translate
AskInk
```

这里的 AskInk 是：

**fallback。**

不是主要交互。

主要交互仍然：

Pencil + `?`

但如果 OCR 没识别问号，或者用户没有 Pencil，可以选正文 → AskInk。

---

# 35. Library

从 Reader 点击左上 `‹`：

返回：

## My Library

顶栏：

左：

AskInk icon

`My Library`

右：

`⌕`

`+`

`•••`

---

# 36. Library 主体

最上方：

## Continue Reading

只显示最近 1–3 本。

下面：

## Library

PDF cover grid。

每本书卡片：

封面

书名

阅读进度

最后打开时间

例如：

```text
┌────────────┐
│            │
│ Calculus   │
│            │
└────────────┘
Calculus III
42 / 312
Yesterday
```

不要在 Library 卡片上显示：

“23 AI chats”

“AI processed”

这种东西。

这里首先是一个：

**书库。**

---

# 37. Library 的 +

右上：

`+`

点击后 menu：

```text
Import PDF
Open from Files
```

以后如果支持：

Scan Document

再加。

第一版不要塞：

Web Import

YouTube

EPUB

Notes

等等。

---

# 38. 长按一本书

Context menu：

```text
Open
Rename
Favorite
Export Annotated PDF
Share
Remove from Library
```

Remove：

必须确认。

---

# 39. Settings 入口

Library 右上：

`•••`

菜单：

```text
Settings
Subscription
Help
About AskInk
```

Settings 使用 Sheet。

---

# 40. Settings 主结构

左侧分类：

```text
General
Reading
Pencil
AI
Data & Privacy
Subscription
About
```

---

# 41. General

内容：

```text
Appearance
System / Light / Dark

App Language
Automatic
```

非常简单。

---

# 42. Reading

内容：

```text
Reading Background
White
Warm
Dark

Toolbar Auto-Hide
ON

Remember Zoom Per Book
ON

Continuous Scroll
ON
```

---

# 43. Pencil

内容：

```text
Default Tool
Pen

Default Color
●

Default Width
━━

Double Tap Action
Switch to Eraser

Floating Palette
Bottom / Left / Right
```

下面：

**Advanced**

里面才出现：

```text
Stroke stabilization
Pressure response
Palm behavior
```

不要让普通用户第一眼看到。

---

# 44. AI Settings

默认极其简单：

```text
AI Mode

Auto ✓
```

下面：

```text
Answer Style
Short

Use Images When Needed
ON
```

再下面：

## Advanced

进去以后才显示：

```text
Provider
AskInk

Bring Your Own API Key

OpenAI
Anthropic
Compatible API
```

普通用户永远不需要知道模型 ID。

---

# 45. Subscription

显示：

```text
AskInk Free

AI Questions
12 / 20 used
```

按钮：

**Upgrade to Pro**

Pro：

```text
Unlimited reading
More AI questions
Deep explanations
Full follow-up threads
Advanced export
```

价格：

**$39.99 / year**

下面：

`$4.99 / month`

Annual 高亮。

---

# 46. Paywall 出现时机

绝对不要：

第一次打开 App 就 paywall。

用户必须先体验：

PDF

Pencil

AI answer

之后再付钱。

Free 用户达到 AI quota 后，如果再次写：

`?`

问题仍然保存。

旁边显示：

```text
✦ Upgrade to answer
```

点击才打开 Paywall Sheet。

购买成功：

自动回答刚才那个问题。

不用重新写。

---

# 47. Data & Privacy

显示非常明确：

```text
Your PDFs
On this iPad

Your handwriting
On this iPad

AI requests
Only the question and relevant nearby context
are sent when you ask a question.
```

然后：

```text
Delete AI History
Delete All Local Data
```

未来：

iCloud Sync

再增加。

---

# 48. Export

Reader → ••• → Export。

Sheet：

```text
Export

Original PDF

Annotated PDF
Includes handwriting and highlights

AskInk Archive
PDF + handwriting + AI threads
```

用户必须能够离开 AskInk。

不要锁死数据。

---

# 49. Portrait Layout

Portrait：

PDF 基本占满宽度。

顶部 toolbar 同样存在。

Pen palette：

默认底部中央。

AI compact answer：

优先问题下面。

Expanded Thread：

使用 bottom sheet。

不要从侧边开 panel，因为 portrait 太窄。

---

# 50. Landscape Layout

Landscape：

PDF 居中。

周围是暖灰/暖白 reading canvas。

如果 PDF 页面旁边有足够空间：

AI answer 可以稍微伸出 PDF 页面边缘。

但视觉上仍然通过 anchor 与 question 连接。

Expanded Thread：

使用 floating panel。

PDF 仍然在后方。

---

# 51. Split View / Stage Manager

窗口变窄：

书名自动隐藏。

Toolbar 只保留：

```text
‹
▣

Search
•••
```

Bookmark 可以进入 More。

Pen palette 自动减少间距。

AI expanded Thread 自动切成 bottom sheet。

绝对不能要求：

“请全屏使用 AskInk”。

---

# 52. 用户完整第一次体验

最终应该是：

```text
App Store
   ↓
AskInk
   ↓
Welcome
   ↓
Open a PDF
   ↓
Files
   ↓
Calculus.pdf
   ↓
PDF instantly opens
   ↓
“Write normally. End a question with ? to ask.”
   ↓
User writes notes
   ↓
Nothing interrupts them
   ↓
User gets stuck
   ↓
writes “why?”
   ↓
✦
   ↓
first-time AI privacy permission
   ↓
short answer appears beside handwriting
   ↓
user understands it
   ↓
answer collapses
   ↓
user keeps reading
```

这整个过程里：

没有账号创建。

没有选择 AI model。

没有复制文本。

没有截图。

没有跳 ChatGPT。

没有 AI sidebar。

没有“开始 AI 对话”按钮。

这就是 AskInk。

---

# 53. 最终按钮地图

### Library 顶部

```text
LEFT                         RIGHT

AskInk  My Library          Search   +   •••
```

### Reader 顶部

```text
LEFT                 CENTER              RIGHT

‹   ▣               Book Title          Search  Bookmark  •••
```

### Reader 底部

```text
                Floating Pen Palette


                                       42 / 312
```

### Pen Palette

```text
Pen  Highlight  Erase  Lasso | Color Width | Undo Redo
```

### AI Compact

没有按钮栏。

只有：

```text
✦ answer text…   More ›
```

### AI Expanded

```text
✦ AskInk                            •••  ×

Question

Answer

Source · p.42


Ask a follow-up…                         ↑
```

这应该就是 AskInk v1 的完整 UI hierarchy。

---

# 54. 一个最后的设计限制

任何以后想增加的功能，都先问：

> **Does this help someone understand the PDF without leaving the page?**

如果答案不是明显的 Yes：

不要进入 Reader 主界面。

这能阻止 AskInk 最后变成另一个 Goodnotes / MarginNote / Notion 混合物。