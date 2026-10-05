# PencilKit 优先的书写引擎

## 决定

默认书写从自研圆头笔带切换到 Apple PencilKit。输入采集、预测、压力与角度响应、笔迹渲染、局部擦除和套索交给系统。旧自研画布、算法、对照页及相关测试已经删除，只保留 PencilKit。

## 工具

| 顶层 | 子类型 | 系统工具 |
| --- | --- | --- |
| Pen | Monoline / Ball（新用户默认） | PKInkingTool(.monoline) |
| Pen | Fountain | PKInkingTool(.fountainPen) |
| Pen | Pencil | PKInkingTool(.pencil) |
| Highlighter | 恒定指定宽度 | PKInkingTool(.marker) |
| Eraser | 局部（默认） | PKEraserTool(.fixedWidthBitmap, width:) |
| Eraser | 整笔 | PKEraserTool(.vector) |
| Lasso | 系统选择、移动 | PKLassoTool() |

工具各自记住宽度和颜色。三个宽度预设按工具区分；高光用 8/16/24 点，局部橡皮用 8/16/32 点，普通笔用 1/2/3.5 点，铅笔用 2/4/6 点。引擎按 SDK 的 validWidthRange 限制实际宽度。颜色有黑、蓝、红、黄、绿和自定义。

工具枚举不再保留 Brush。旧 brush 偏好读取时回退为等宽笔。已有钢笔偏好保留；新用户默认等宽笔。过去的压感和稳定度设置不应用到 PencilKit，不显示无效滑块。

## 边界接口

InkEngine 提供 UIView、PKDrawing、工具配置、恢复绘图、撤销/重做、结束当前操作以及生命周期事件。PDF 协调器只依赖该协议，通过 InkEngineFactory 创建默认引擎；画布卸载也按注册的引擎视图匹配，不强制转换到 PencilKit 实现。PencilKitInkEngine 自身处理 PKCanvasViewDelegate、Pencil 双击和长按 Ask ✦。

没有 beginStroke/updateStroke 原始触点注入 API：PencilKit 自己拥有输入。将来 Metal 引擎可内部处理 coalesced/predicted touches，并发布同样的生命周期事件，不要求 PDF、AI 或文档 UI 处理采样点。

## PDF、手势与保存

每个 PDF 页使用独立画布与 UndoManager，Pencil only drawing；画布自身滚动和缩放关闭，由父 PDFView 导航。父视图的 Pencil 防误触遍历遇到 PKCanvasView 即停止，避免剥夺系统画布内部识别器的 Pencil 输入。

按页保存原始 PKDrawing。局部擦除的 mask、套索变换和系统墨迹类型不被重新生成圆头几何。OCR 黑线归一化仍保留 transform/mask。旧自研绘图可读取，但其墨迹原先主要以 pen/marker 存储，换系统渲染后外观可能变化。

正常抬笔进入停笔计时。drawingDidChange 若在抬笔后到达，会更新版本并重新计时。局部擦除、套索移动、撤销或页面强制结束只保存，不自动提问。离屏延迟释放 0.8 秒以接收系统晚到的笔迹更新；极端系统取消/后台情况需真机复测，不把这个延迟视为无条件持久化保证。

## 验证与下一步

检查工具映射、最低 iPadOS 17 可用性、PDF 画布手势隔离和完整 PKDrawing 的保存/识别链路。旧引擎清理后剩余 65 项原生回归测试通过，针对连接的 iPad 签名构建通过；没有调用付费模型。原生算法回归和模拟器、iPad 架构编译用于发现集成错误，无法测量真实 Pencil 延迟。

旧引擎对照入口已删除。真机要验证：三支笔的差别、同处高光是否符合预期、局部擦除只删除触碰区域、套索移动和撤销恢复、翻页后笔迹及 mask 恢复、手指缩放与手掌保护、问号自动回答。

只有真实用户测试证实系统引擎无法满足明确需求时，再开发 MetalInkEngine。那时必须独立处理合并采样、预测替换及 GPU 增量渲染，而不是继续让主线程重建整笔路径。
