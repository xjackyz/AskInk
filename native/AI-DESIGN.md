# AskInk AI 阅读实现

## 运行链路

手写候选问号 → 本机识别 → 确认问题与笔迹锚点 → Context Planner → 流式短答 → 原书页边批注。普通笔记不会请求 AI。手动 Ask 与文字选中共用请求流程。识别、问号触发和笔触算法见 [书写审计](WRITING-AUDIT.md)，格式适配和全文索引见 [本机阅读研究](LOCAL-READING-RESEARCH.md)。

`AIReadingPipeline` 是新问题与追问的唯一问答入口；`AIRequest` 负责版本化 prompt、供应商格式和响应解码；`AIStreaming` 负责 SSE。旧 `ReaderAPI` 和独立的 ReaderStore 上下文拼装已删除。识别文字是草稿，原始笔迹图与附近正文图分开提供；用户编辑的文字优先。模型不能从正文编造手写问题。

## 短答、More 与原书浮层

第一次固定 compact，通常 2–4 句。默认 OpenAI 模型为 `gpt-6-luna`；只有点击 More／深入解释才请求 expanded，默认 `gpt-6.1-sol`。两个模型 ID 可配置，保留已有自带 API Key 服务配置；Claude 与兼容服务使用其配置模型。不会预生成长答。

确认后显示 60%–100% 呼吸星光，支持减少动态效果。SSE 增量中只展示 answer 的文字，隐藏 JSON schema 字段。空白区域无底框，正文冲突时加轻薄 material；点击答案在原书上展开来源和追问，关闭后回到小星光。菜单中的深入解释同样是单独网络请求。

OpenAI Responses、Claude Messages 和兼容 Chat Completions 共用 SSE 累积器。只有供应商明确完成的回答进入历史；断流、拒答、输出截断保留问题供重试。兼容接口若忽略 stream，回退普通 JSON 响应；不承诺每个兼容服务支持流式或图片。

## 上下文与防剧透

`DocumentGraph` 是正文、章节、阅读顺序与来源 ID 的统一模型。PDFAdapter 提取正文；扫描页回退本机 OCR。SQLite FTS5/BM25 和 Apple sentence embeddings 本机融合检索；系统没有对应语言 embedding 时继续使用词法检索。

ContextPacket 分为 targets、local_context、retrieved_context、recent_turns、thread_summary、reading_position 与 spoiler_policy。显式选择／标记优先，随后附近段落和前文检索。正文证据只发送一份，不再同时重复发送 context、relatedSources 与 packet。

默认以当前内容块为边界，同时过滤邻段、检索和记忆；未知位置不发送无限制的全书证据。用户可在设置中明确允许后文。关闭后文权限后，曾允许后文的历史回答也不进入后续模型上下文。模型请求更多 context 时，只追加相关片段，最多再请求一次；若规划后的证据没有改变则不重发。

来源只允许本次包内 ID，结构化和内联引用均验证。PDF页码与来源锚点可返回原书。来源列表中的检索候选与模型正式引用分开保留，不把所有候选都当作模型已引用的事实。

## 本机持久化与预算

`AIThread` 保存文档 ID、问题笔迹 ID、识别问题、锚点、目标内容 ID、createdAt/updatedAt 和 AITurn。每个 turn 保存 role、text、citations、model、input/cached/output tokens 与 timestamp。识别区域、笔迹图及其他旧元数据完整保留。

`threads.json` 是唯一会话存储，ReadingReply 是现有 UI 的投影。首次保存时读取并迁移 `replies.json`，校验往返后原子写入再删除旧文件；损坏的 canonical 文件不回退覆盖。备份导出、导入、删除会话已适配。没有使用供应商 conversation 或 previous_response_id。

前四轮保留有界历史，更长时使用本机抽取式摘要加最近两轮，不自动调用模型压缩历史。上下文规划采用保守 UTF-8 字节界限，compact 6000、expanded 18000；这是文本证据约束，不是供应商实际 token 计数。图片、稳定 prompt 和 JSON 结构另有开销。输出上限包含结构化字段及模型推理开销，compact 700、expanded 1600；实际 API 用量保存在 turn。

章节记忆只在重复问题或深入解释需要前文时生成，按文档 revision 与章节范围缓存；不会在导入时自动总结。只总结已读完且文本不超过 24000 UTF-8 bytes 的章节，缺目录或超大章节继续使用有界检索。记忆生成失败不阻断普通问答。显式全文总结仍是独立工具，需要用户主动选择。

稳定阅读 prompt 版本为 `askink_reader_v1`，位于本机 AIRequest；当前产品采用 iPad 直连自带密钥，没有部署后端。固定 developer/system 指令在动态证据之前。未来如改为服务端，由服务端托管同一版本；不为 cache 填充无意义文本，不硬编码价格。

## 验证与边界

回归测试覆盖 SSE 断流／截断、Unicode 增量、缓存用量、预算、来源校验、防剧透、旧 packet 解码、旧历史迁移、错误文档归属和损坏文件保护。完整 iPad App 用 Xcode 无签名模拟器构建验证；真实 Pencil、视觉问答、供应商账户权限和付费 API 输出质量需设备实测。当前可导入格式仍为 PDF，EPUB/DOCX 仅有格式中立模型。

接口依据：[OpenAI 流式响应](https://developers.openai.com/api/docs/guides/streaming-responses)、[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna)、[GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol)。
