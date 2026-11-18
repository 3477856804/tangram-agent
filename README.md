# Tangram Agent（TGA）

个人专属 AI Agent 全平台运行时：手机 / 桌面 APP + 本地纯 Dart 后端 + 隔离沙箱，
可接云端 API 模型或本地 GGUF 模型，支持在微信 / QQ / 飞书里对话，
带工作轨迹、蒸馏模型管理、知识图谱、日记与定时任务等能力。

版本：**0.0.11**（唯一真源为仓库根 `VERSION`，由 `harness/version.py`
的 `assert_version_frozen()` 校验 pubspec / 后端包 / App 常量全部一致）

> 本仓库为开源软件，许可证为 **GNU AGPL-3.0**（见根目录 `LICENSE`）。
> 参考项目与 vendored 源码的许可证、版本与归属见 `third_party/`。
> 原版权归属：檀阁瑞木 / COSMOn。

## 组成

- `frontend/` — Flutter APP（Android / Windows / Linux / macOS / iOS），
  内置纯 Dart 后端（`lib/harness/embedded_backend.dart`）、受限 Isolate 沙箱、
  端侧 GGUF 真推理（`llamadart`）与全部业务页面。
- `backend/` — 本地 Python 后端运行时（真实入口 `main.py`）：
  `app/runtime/agent_service.py` 应答内核、`local_llm.py` 真实 GGUF/HF 推理、
  `memory.py` 持久化记忆、`app/models/store.py` 魔搭真实检索。
  只用标准库即可运行 `--chat` / `--bridge tcp`；推理后端按需惰性探测。
- `training/` — `pipeline.py`：真实梯度下降训练（有 torch 走 autograd 落盘
  `.pt`，无 torch 走纯 Python 解析梯度落盘 `.json`）+ 真实合并 / 原子晋升。
- `im/` — IM 网关（微信 iLink / QQ NapCat / 飞书设备授权流三渠道扫码接入、
  消息收发、局域网 UDP 自动发现、真实持久化 inbox 与 WS 事件监听）。
- `harness/` — 能力契约 / 工作轨迹 / 蒸馏与教师接口的 Python 参考实现。
- `tests/` — 真实功能回归测试（`python3 -m pytest tests -q`）。
- `skills/` — 内置技能清单。
- `schema/` `shared/` — 协议与共享定义。
- `scripts/` — 构建脚本（`build_frontend.sh` / `build_backend.sh` /
  `run_headless.sh` 等）。
- `.github/workflows/` — 全平台云端构建工作流。

## 核心能力（均为真实实现，无占位数据）

- **内置 Linux 沙箱**：Android 端只有一套环境——`proot` + Alpine 3.20
  用户态（约 4.2MB，首次使用真实下载并解包）。`apk` / `python3` / `pip`
  在用户态真实执行，`uid=0`、根分区与可用工具链由 `env_report` 单点探测；
  宿主玩具箱 shell 永不参与命令执行，不会出现「两台互相矛盾的机器」。
- **3D 建模**：OBJ / STL / PLY(ASCII) / GLB 真实解析、Canvas 实时渲染、
  导出 OBJ/STL；顶点按 1e-6 量化焊接，导出后可无损回读。
  另提供 `backend/app/runtime/cad_model.py`：**已 vendor 参考项目 build123d
  0.11.1 源码**（`third_party/build123d`，Apache-2.0），做参数化 B-rep 建模、
  布尔运算、体积/包围盒校验与 STEP/STL 导出；OCCT 原生依赖缺失时明确报错。
- **主动发消息**：微信 iLink、QQ v2、飞书 OpenAPI 三渠道真实 REST 发送，
  收件人来自真实会话列表，失败如实回传错误码，不伪造成功。
- **思考过程**：对话中默认直接展开推理内容，可点按收起 / 再展开。
- **端侧推理**：DeepInfer 调度思想落地——稳定前缀复用（`cache_prompt`）、
  分块预填充、prompt-lookup 投机起草、预算化生成、真实指标累加；
  不虚构加速比，硬件不满足时如实降级。
- **私有知识库**：多库隔离、文档/网页/粘贴文本增量入库，本地 BM25 检索、
  引用溯源、版本快照；对话只注入真实命中片段。二进制格式如实提示先用沙箱解析。
- **自动化工作流**：可视化步骤编排（对话 / 沙箱命令 / 知识库检索），
  变量传递、批量输入、每日定时触发；定义与运行记录真实落盘。
- **快照与备份**：Harness 数据目录文件级快照，逐文件 SHA256，恢复前自动备份；
  加密云端同步未配置时如实标注不可用。
- **多模型群聊**：本地/云端模型并发独立作答，主持人交叉比对分歧并裁决；
  API Key 只在进程内使用，不回显、不写日志。
- **Agent 应用市场 / 团队协作**：行业工作站模板一键安装（人格 + 工作流 +
  知识库 + 权限建议），本机团队空间按 owner/editor/runner/viewer 强制权限并留审计。
- **视频剪辑**：`backend/app/runtime/video_edit.py` 基于 ffmpeg 真实完成探测、
  裁剪、统一规格拼接、字幕烧录、配乐与自动粗剪；App 内「视频工作室」可生成
  命令、检查依赖、真实执行并保留任务记录。
- **全类型知识解析**：`backend/app/runtime/knowledge_ingest.py` 支持文本/HTML/
  PDF/DOCX/XLSX/图片 OCR/压缩包真实提取与切块；可选依赖缺失时明确报错。
- **Creator 创造模式**：声明式插件包（prompt/http/shell）校验、落盘、激活注册
  到内核、停用撤销与导入导出；不动态编译 Dart，危险能力默认拒绝。
- **经验迁移 / 账号运营**：从成功工单与工作流沉淀经验并本地检索迁移；账号只存
  凭据引用，草稿必须人工审批后才通过真实 IM 通道发布，全程审计。
- **全栈 UI 自定义**：强调色/表面/字号/密度/圆角/导航分组/可见项配置，
  全局与项目作用域分离，JSON 导入导出；保存后真正驱动主题与侧栏。
- **场景与情绪连贯**：专注 / 闲聊 / 安静三种模式，情绪与能量、打断任务恢复、
  合理遗忘与置顶记忆；只调整交互风格，不做心理诊断。
- **多角色子 Agent**：独立角色、知识库绑定、权限集、记忆作用域（isolated/shared）、
  独立执行开关与专属记忆检索；Super Agent 派生子任务时真实读取并写入角色记忆。
- **混合检索与算力调度**：本地哈希向量库 + BM25 混合检索，可切换 Qdrant/Chroma
  远程适配器；硬件探针给出量化/后端/路由建议与轻/重任务队列（不执行模型）。
- **目录映射**：宿主授权目录 ↔ 沙箱 `sandbox/mounts/` 真实文件同步，
  敏感目录拒绝、只读映射禁止回写、文件数与体积上限。
- **认知决策 / UI 插件槽**：澄清、风险、方案对比与决策日志可视化；
  Creator 插件可注册声明式 UI 槽位、权限策略与 MCP 工具。

## UI / 交互 / 性能迭代（2026-11-18）

在既有设计语言（云雾白 + 白卡 + 星蓝强调色）不变的前提下补齐质感与手感，
色值、字号与语义文案保持原样，不引入任何占位数据或假交互：

- **统一动效令牌**：新增 `frontend/lib/design/dsh_motion.dart`，把散落各处的
  硬编码毫秒数收敛为 110 / 180 / 260 / 420ms 四档与 `easeOutCubic` 曲线；
  动画均为一次性有限动画，并统一遵循系统「减少动态效果」开关。
- **视觉层次**：卡片、统计卡与输入区改为「发丝描边 + 双层柔和投影」，深色主题
  自动调整阴影色与强度；顶栏加发丝分隔线；分段胶囊、按钮、图标瓦片与发送键
  补齐按压高亮、缩放与触感反馈（高亮画在前景，不被不透明卡片遮挡）。
- **更自然的交互**：搜索框支持聚焦点亮与一键清除；空会话的品牌标 / 问候语 /
  快捷指令按节奏错落淡入；会话标题切换淡入淡出；检索详情高度缓动展开；
  拖动消息列表收起键盘；复制成功改为浮动圆角提示且不再排队堆叠。
- **不打断阅读的滚动**：聊天列表只在用户贴底时跟随，上翻看历史期间新内容不再
  把视图拽回底部；「回到最新消息」按钮带缩放淡入与投影。
- **性能优化**：
  - 消息列表「上一条用户消息」由 itemBuilder 内 O(n²) 回溯改为一次线性预计算；
  - 流式输出按「48ms / 24 字符」合并重绘，避免逐 token 重建整条消息列表与反复
    解析 Markdown；滚动跟随改为合并后的无动画 `jumpTo`，不再堆积互相打断的动画；
  - 输入区打字只重建编辑器行，模型注册表订阅下沉到模型入口的 `Builder` 子树；
  - `MarkdownStyleSheet` 按样式缓存复用（带上限），减少长会话滚动的对象分配；
  - 修复语音控制器匿名监听未摘除造成的回调泄漏；禁用态发送键不再注册无效点击。

验证：`flutter analyze --no-pub` 无问题；`flutter test --no-pub` 全量通过（含
UI 布局 / 截图 / 主题对比度回归）；`python3 -m pytest tests -q` 除构建环境缺
`libx264` 编码器的视频用例外全部通过。

## 本地后端与蒸馏（真实可运行）

```bash
# 无头对话：确定性能力真实执行；配置模型后走真实推理
bash scripts/run_headless.sh --data ~/.tangram

# 真实本地模型（GGUF）或 OpenAI 兼容云端 API
TANGRAM_MODEL=/path/to/model.gguf python3 backend/main.py --chat
TANGRAM_API_BASE=https://api.example.com/v1 TANGRAM_API_KEY=xxx \
  TANGRAM_API_MODEL=gpt-4o-mini python3 backend/main.py --bridge tcp --port 50440

# 工作蒸馏：真实数据集 → 真实训练 → 真实合并权重 → active.json 晋升
python3 -m harness --models-root ./models demo          # 离线端到端自测
python3 -m harness --models-root ./models download qwen2.5-0.5b --mirror
python3 -m harness --models-root ./models distill --source local --base qwen2.5-0.5b

# 真实功能回归测试与后端构建
python3 -m pytest tests -q
bash scripts/build_backend.sh --output dist/backend
```

未配置任何模型时，运行时会明确报「未配置模型」，绝不用模板/检索式占位文本
冒充模型回复。训练产物会如实标注格式（适配核 / 合并权重 / 标记文件），
不把 JSON 或适配核伪装成完整 GGUF/LLM 权重。

## 快速开始（构建 APP）

```bash
# 依赖：Flutter 3.41+（含 Dart 3.10.7+；实测 3.47.9 stable 可用）
cd frontend && flutter pub get
bash ../scripts/build_frontend.sh android        # 出 APK → dist/tangram-agent-<ver>-android.apk
bash ../scripts/build_frontend.sh linux          # 出 Linux 桌面
bash ../scripts/build_frontend.sh windows        # 出 Windows 全量便携包 zip
bash ../scripts/build_frontend.sh macos          # 出 macOS
```

Windows 便携包由 `scripts/pack_windows.py` 生成：Release 目录全量内容，
并**排除** Windows 无法加载的 ELF（`*.so`）——原生资产钩子会把预置的
android-arm64 运行库一并拷进 Windows 产物，排除后体积约 25MB（原 150MB+）。
打包只做排除，不删除磁盘产物。

云端一键全平台构建：仓库 push 到 `main` 会自动触发
`.github/workflows/build-all.yml`，产物汇总到一个 Release，可直接下载。

## 扫码接入 IM 渠道

手机 APP「更多通信」点对应渠道的「去授权」即出真二维码：微信走腾讯官方 iLink、
QQ 走 NapCat 官方协议端、飞书走官方设备授权流。APP 与电脑同 WiFi 时经 UDP `50433`
自动发现网关，发现失败才需手填地址。二维码均来自官方接口 / 网关真实响应，
拿不到即如实报错，绝不伪造。

单独启动网关（三渠道扫码登录、消息应答）：

```bash
python3 -m im.serve --port 50432
```

## 数据与隐私

- API Key、SSH 凭据、人格设定等仅在本机 `flutter_secure_storage` 加密存储，不落盘明文、不写日志。
- 对话记录、工作轨迹、日记、云端模型配置全部落在 App 私有目录，重启可恢复，不上传任何第三方。

## 许可

Copyright © 2026 檀阁瑞木 / COSMOn — 闭源专有软件，保留所有权利。
