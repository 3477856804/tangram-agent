# third_party —— 参考项目与 vendored 源码

本目录用于存放从参考开源项目 vendored（复制）进来的源码，以及每个项目的
许可证与接入说明。仓库整体已切换为 **AGPL-3.0**（见根目录 `LICENSE`）。

规则：

1. 每个 vendored 项目单独一个子目录，保留原始 `LICENSE` 与版权头。
2. 不允许把 GPL/AGPL 源码复制进来后闭源分发；本项目整体按 AGPL-3.0 开源。
3. 能在运行时作为依赖/独立进程使用的，优先依赖，不重复复制源码。
4. 复制后必须在本文件登记：项目、版本、许可证、入口文件、接入方式。

## 已 vendored

| 项目 | 版本 | 许可证 | 目录 | 接入点 |
|---|---|---|---|---|
| build123d | 0.11.1 | Apache-2.0 | `build123d/` | `backend/app/runtime/cad_model.py` 优先从本目录导入；OCCT 原生依赖仍需安装 |

## 参考项目登记（按能力清单）

| # | 能力 | 参考项目 | 许可证 | 当前接入方式 |
|---|---|---|---|---|
| 1 | 事件微内核 / 可插拔循环 | Cordis、LangGraph | MIT | Dart 自研内核，行为对齐 |
| 2 | Router-Worker | AutoGen、CrewAI | MIT | Dart SuperAgent 自研 |
| 3 | 工单 / 上下文 / Watchdog | LangGraph、mem0 | MIT / Apache-2.0 | Dart 自研 |
| 4 | 隔离沙箱 / 权限 | Linux namespaces、cgroups | GPL-2.0（内核） | 系统能力 + Dart 策略引擎 |
| 5 | 模型 / 存储适配器 | LangChain、Ollama | MIT | Dart 适配器 |
| 6 | 事件流 / Fork / 回放 | LangGraph checkpoint | MIT | Dart 插件内核事件流 |
| 7 | 目录映射 | rclone、watchdog | MIT / Apache-2.0 | Dart 文件同步 + 桌面 symlink |
| 8 | 本地推理加速 | llama.cpp、vLLM、SGLang | MIT / Apache-2.0 | llamadart 依赖；vLLM/SGLang 未内置 |
| 9 | 免费开源模型 | ModelScope、HF、Ollama | Apache-2.0 / MIT | 目录 + 按需下载 |
| 10 | 硬件调度 | pyamdgpuinfo、nvidia-smi | MIT / 专有工具 | Dart 探针与建议，不跨设备执行 |
| 11 | 多角色子 Agent | AutoGen、LangGraph | MIT | Dart 自研 |
| 12 | 私有知识库 | Chroma、Qdrant、LangChain | Apache-2.0 / MIT | Dart BM25 + 向量库适配器 |
| 13 | 深度思考 | LangChain ReAct/CoT、ToT | MIT | Dart 执行循环 |
| 14 | 联网搜索 | SearXNG、httpx、BeautifulSoup | AGPL-3.0 / BSD / MIT | Dart 原生 HTTP 重写（DuckDuckGo + 维基） |
| 15 | 全类型文件解析 | PaddleOCR、PyMuPDF、python-docx、Unstructured | Apache-2.0 / AGPL-3.0 / MIT | Python 运行时依赖 |
| 26 | Creator 插件 | monaco-editor、Cordis | MIT | 声明式插件 + 内核注册 |
| 27 | 工作流 | LangGraph、Prefect | MIT / Apache-2.0 | Dart 工作流引擎 |
| 29 | 模型商店 | modelscope、huggingface_hub | Apache-2.0 | Python 运行时依赖 |
| 25 | 渐进交付 | 无特定参考（LangGraph 草稿/审阅思想） | — | `delivery_versions.dart`：版本落盘 + draft/review/final |
| 30 | 快照 / 云同步 | rclone、cryptography | MIT / Apache-2.0 | `cloud_sync.py`：AES-256-GCM + SigV4 R2/S3，本地快照接入 |
| 31 | 量化回测 | Jesse、vn.py | AGPL-3.0 / MIT | `backtest.py`：事件驱动回测、手续费/滑点、MA/RSI、指标 |
| 32 | 视频剪辑 | MoviePy、FFmpeg、PySceneDetect、Whisper | MIT / LGPL / BSD / MIT | FFmpeg 命令行真实执行 |
| 33 | 3D 参数化建模 | build123d、OCCT | Apache-2.0 / LGPL-2.1 | **已 vendored build123d 0.11.1** |
| 37 | 账号运营 | Playwright、httpx | Apache-2.0 / BSD | IM 真实发布；平台自动化未接入 |
| 39/41 | 人格 / 记忆 / 情绪 | mem0、LangMem | Apache-2.0 / MIT | `emotion_tone.dart` 词库 + EMA，接入 Presence |

> 说明：登记表里标「未接入」的能力不会被 UI 说成已完成；后续 vendoring 会
> 逐项补充到「已 vendored」表并更新接入点。
