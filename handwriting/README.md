# 手写模块

当前实现位于 native，是独立 iPad App。iPadOS 27 优先使用 Apple 笔画识别，不可用时回退随 App 内置的 PaddleOCR v6 small，无电脑 OCR 服务、v5 对照或语言模型下载步骤。

使用和构建见 [native/README.md](../native/README.md)，实际算法见 [native/AI-DESIGN.md](../native/AI-DESIGN.md)。

本目录的 evaluate.py 与 test_evaluate.py 仅为开发者离线评估工具，不属于 App 功能或运行依赖。无需用户导出 JSON 或标注样本才能使用 App。没有个人手写基准，因此不报告个人准确率。
