# 源码审计报告（0.0.41）：设计与实现差在哪

> 方法：逐文件读源码取证（A31 逆向口径：**证据 → 推断 → 待验证**）。
> 结论先行：**内核骨架是真的**（装配/挂载/可逆/快照/MCP/沙箱都有真实现），
> 但**分级与钩子只到「声明」层，没有执行点**——这正是 NewAgentUniverse 批评上游的那一条：
> 「文档承诺 > 代码事实」。本报告把每一处差距钉到 `文件:行号`。

## 1. 与设计一致（有真实实现，已取证）

| 设计项 | 证据位置 | 判定 |
|---|---|---|
| 内核装配：读盘→建 profile→按 bundle 顺序挂载→模式裁剪→落盘 | `frontend/lib/harness/plugin_kernel.dart:739-766`（boot） | ✅ 真实 |
| 挂载依赖校验，缺依赖即拒绝 | 同上 `:841-850`（requires 校验） | ✅ 真实 |
| 可逆效果：卸载逆序撤销，恢复同名服务 | 同上 `:880-910`（effects.reversed） | ✅ 真实 |
| 能力接缝：定义 + providers + activeProviderId + consumers | 同上 `:162-184`（CapabilitySeam） | ✅ 真实 |
| 切换 provider 时消费者一起感知 | 同上 `:948-978`（setProvider） | ✅ 真实 |
| 接缝调用无 provider 时明确拒绝，不伪造执行 | 同上 `:985-995` | ✅ 真实 |
| 动作面：mount/unmount/set_provider/invoke/events/search/fork/modes/patch/pages/widget_slots | 同上 `:1203-1314`（handle） | ✅ 真实 |
| 事件 append-only + replay + search + fork | 同上 `:216-247`、`:1271-1294` | ✅ 真实 |
| 内置插件真实注入 11 类接缝（storage/model/sandbox/skills/mcp/agent-loop/trajectory/scheduler/im/hooks/ui-pages） | `frontend/lib/harness/builtin_plugins.dart:196-1040` | ✅ 真实 |
| 快照：白名单 + 逐文件 SHA256 + 恢复前自动备份 | `frontend/lib/harness/snapshot_service.dart:29-53`、`:211-249` | ✅ 真实 |
| MCP 客户端：initialize → notifications/initialized → tools/list → tools/call | `frontend/lib/harness/mcp_client.dart:56`、`:80`、`:117` | ✅ 真实 |
| 插件子进程沙箱：shell 默认拒绝、HTTP 主机白名单、私网/回环拒绝、超时与并发上限 | `backend/app/runtime/plugin_runtime.py:718-720`、`:756-762`、`:764+` | ✅ 真实 |
| UI 插件宿主：只读白名单渲染，绝不执行任意 HTML/JS | `frontend/lib/ui/pages/tga_ui_plugins_page.dart:1-25` | ✅ 真实（但见 G7） |

## 2. 与设计不一致 / 只有声明没有执行（7 处）

### G1 · 分级是声明性的，不是执行性的
- 证据：`Plugin.tier` 默认 `T1 official`（`plugin_kernel.dart:526`）；唯一读取点是
  `consumeSeam` 的 caps 判定（`:346-352`）；内置插件 caps 全为空（`builtin_plugins.dart:116` 只声明 providesSeams）。
- 推断：**所有内置插件 caps 为空 → 判定永远通过**；tier 在真机上不产生任何约束。
  第三方插件若不声明 tier，也默认拿 T1 官方权限（fail-open）。
- 本轮已修一半：`_CreatorPlugin` 用户自建插件显式标 T2（`creator_runtime.dart:1088`）。
- 待验证：需要一个「第三方插件 tier=T3 且无 caps → 拒绝挂载」的用例，当前无该路径。

### G2 · 仲裁缺失：`invoke` 没有调用方身份
- 证据：`handle` 的 `invoke` 分支（`plugin_kernel.dart:1246-1251`）直接取 `p['seam']` 调
  `invoke()`；`invoke()`（`:979-1020`）只校验接缝与 provider 是否存在，**不校验谁在调、有没有能力令牌**。
- 推断：任何能发 `plugin_kernel {action:'invoke'}` 的调用方（UI / 脚本 / 插件）都能调用任意接缝，
  包括 `core/sandbox` 的真实 shell。**这是本仓库当前最大的权限缺口**，与 NAU 的
  「策略必须强制，否则拒绝」相悖。
- 修复方向：invoke 增加 `caller` + `caps` 参数，缺声明即拒绝；UI 侧按登录态注入。

### G3 · 钩子只有「通知」，没有「改写 / 否决」
- 证据：`KernelEventBus`（`plugin_kernel.dart:216-247`）只有 on/off/emit，订阅者不能改 payload、不能否决；
  全文件无 `hooks` 层概念。
- 推断：与 NORP 的 9 层钩子（可订阅/改写/否决）不是一回事。当前内核的「可扩展」是
  **注册式**（provide/consume/registerTool），不是 **拦截式**。
- 影响：做不到「发送前统一改写」「工具调用前统一拦截」这类横切策略。

### G4 · 地址函数没有接线
- 证据：`parsePluginAddress()` 只出现在 `plugin_tier.dart` 与测试里；生产代码 0 引用。
  provider id 仍是 `'core/storage'`、`'in-memory'` 这类自由字符串（`builtin_plugins.dart:209+`）。
- 推断：地址函数目前是**死代码**，属「文档承诺 > 代码事实」。要么接线（provider id 规范化 + 解析失败即拒绝），
  要么删掉，不留假承诺。

### G5 · 快照不覆盖内核内存态，且没有内核级回退
- 证据：`SnapshotService` 备份的是**磁盘 JSON 白名单**（`snapshot_service.dart:29-53`），
  含 `kernel_events.jsonl`、`plugin_config.json`；但内核的 `_nodes`/`_seams`/`_services` 在内存里。
  `handle` 动作表（`:1203-1314`）**没有 rollback / snapshot 动作**。
- 推断：恢复文件后，已挂载的插件仍在内存里跑着 —— 「回退」只回退了数据，没回退行为。
  要真正做到「装坏了能退」，需要：挂载前后各打一次内核态快照（节点树 + seam 表 + 配置），
  恢复时先 unmount 差异插件再回放。

### G6 · WASM 模块级契约完全缺席
- 证据：全仓库无 wasm/wasmtime 相关实现（`frontend/lib/**`、`backend/**` 均无）。
  `contracts/` 下只有本仓库自己的插件清单 schema 思路，**没有** WASM ABI 文件。
- 推断：跨语言契约目前只有 MCP（工具级），模块级为零。这不是 bug，是**未实现**，
  但文档里不能写成「已有 WASM 契约层」。

### G7 · UI 不是「编译期约定加载」，是运行时数据驱动
- 证据：`tga_ui_plugins_page.dart` 从内核 `widget_slots` / `pages` 拉数据，按
  title/text/button/link/card 白名单渲染（`:1-25`）。
- 推断：与 mosaic 设想的「约定接口 + 生成器注册表」不同 —— 现在是**插件运行时声明、宿主按白名单画**，
  好处是安全（不执行任意 UI），代价是**不能放复杂交互组件**，且新增页面要走内核注册而非文件约定。

## 3. 建议的修复顺序（按风险/收益）

| 序 | 动作 | 风险 | 收益 |
|---|---|---|---|
| 1 | G2：invoke 增加 caller + caps 校验（缺声明即拒绝） | 中（要改 UI 调用点） | 关掉最大权限缺口 |
| 2 | G5：`onBeforeMount` 接 SnapshotService + 内核态快照/回退动作 | 中 | 「装坏了能退」成真 |
| 3 | G4：provider id 规范化（`pkg.mod:attr`），解析失败即拒绝 | 低 | 去掉死代码，接上地址函数 |
| 4 | G1：第三方插件路径强制 tier=T3 且无 caps 即拒 | 低 | 分级真正生效 |
| 5 | G3：引入否决式钩子（tool 调用前 / 发送前） | 高 | 横切策略可落地 |
| 6 | G6：WASM ABI（`wasm/1`）+ 缺运行时类型化拒绝 | 高 | 模块级插件，非本轮 |

## 4. 本轮已改（0.0.41 第二笔）

- `frontend/lib/harness/plugin_tier.dart`（新）：分级枚举 + caps 判定 + 地址解析 + `CapabilityDenied`。
- `plugin_kernel.dart`：`Plugin.tier/caps/address` 默认值；`consumeSeam` caps 校验；`pluginOf()`；
  `onBeforeMount` 钩子（默认 null，抛异常即拒绝挂载）。
- `backend/app/runtime/plugin_runtime.py`：清单支持 `tier`（默认 T1，未知兜底 T1）与 `caps`；
  **T3 未声明 caps 直接拒绝加载**。
- `creator_runtime.dart`：用户自建插件显式 `tier = T2`。
- 测试：`frontend/test/plugin_tier_test.dart`、`tests/test_plugin_tier.py`。

## 5. 验证状态（不粉饰）

| 项 | 状态 |
|---|---|
| 括号配平 | ✅ 已过（kernel 314/314、creator 262/262、新文件 10/10、6/6） |
| `flutter test test/plugin_tier_test.dart` | ❌ **未跑**（设备无 Flutter） |
| `pytest tests/test_plugin_tier.py` | ❌ **未跑**（设备无 python3） |
| 真机装插件 / 切换 provider / 快照恢复 | ❌ 未验证 |

> 本报告本身就是一次「声明 → 证据」核对：上面每条「✅ 真实」都指到具体行；
> 每条「只有声明」都写明了缺哪个执行点。修完 1–4 再复跑本报告，应能把 G1/G2/G4/G5 划掉。
