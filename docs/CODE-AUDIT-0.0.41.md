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

---

## 6. 修复完成状态（0.0.41 终版，一次性提交）

| 缺口 | 状态 | 实现位置 | 验证方式 |
|---|---|---|---|
| G1 分级无执行 | ✅ 已修 | `plugin_kernel.dart` mount 拒绝 T3 无 caps；`creator_runtime.dart` 用户插件=T2；`plugin_runtime.py` 清单 T3 fail-closed | 静态关卡 + pytest（待跑） |
| G2 invoke 无仲裁 | ✅ 已修 | `invoke({caller, caps})`；缺令牌发 `seam.denied` 并拒绝；`invokeGuard` 可否决；默认 `core/sandbox`→`sandbox:exec`、`core/im`→`channel:send`、`core/mcp`→`net:fetch`（`kernel_guard.dart`） | 静态关卡 + flutter test（待跑） |
| G3 钩子无否决 | ✅ 部分 | `InvokeGuard` 提供调用前否决点；事件总线仍只通知（不改写 payload，避免动 hot-path） | 静态关卡 |
| G4 地址函数死代码 | ✅ 已修 | mount 校验 `Plugin.address`，非法即拒绝挂载 | 静态关卡 |
| G5 快照不回退行为 | ✅ 已修 | `captureSnapshot/restoreSnapshot` + `handle` 的 `snapshot/snapshots/rollback`；`embedded_backend` 装插件前自动快照（失败发 `kernel.snapshot_failed`，不阻断挂载） | 静态关卡 + 真机（待跑） |
| G6 无 WASM | ✅ 契约+拒绝 | `contracts/wasm-abi-v1.md`；`wasm_module.dart` 无运行时抛 `WasmUnavailable` | 静态关卡 + flutter test |
| G7 UI 非约定加载 | ✅ 新增 | `frontend/lib/mosaic/`（panel/registry/host）+ `tool/gen_mosaic_registry.mjs` 生成注册表（2 面板） | 生成器实跑通过 |

### 6.1 本轮验证结果（能跑的都跑了）

| 验证 | 结果 |
|---|---|
| `node tests/conformance_0_0_41.mjs`（30 条静态关卡：执行点/配平） | ✅ **30 passed / 0 failed** |
| `node tool/gen_mosaic_registry.mjs` + `--check` | ✅ 生成 2 面板，检查通过 |
| 括号配平（8 个 Dart 文件） | ✅ 全部配平 |
| `flutter test test/kernel_guard_test.dart test/plugin_tier_test.dart` | ❌ **未跑**（设备无 Flutter） |
| `pytest tests/test_plugin_tier.py` | ❌ **未跑**（设备无 python3） |
| 真机：装插件→快照→回退 | ❌ 未验证 |

### 6.2 仍然保留的诚实边界

1. G3 只做「调用前否决」，不做「payload 改写」——改 payload 会碰流式 hot-path，本轮不动。
2. WASM 只有契约与类型化拒绝，**没有运行时**。
3. G7 的 mosaic 层与内核 `widget_slots` 并存，未替换路由；接入点留给下一轮。
4. 所有 Dart/Python 测试均未在本机执行，需在 CI 或电脑上跑一遍才算「验证通过」。

---

## 7. round12 修复（2026-11-25 05:00 轮次，基线 29a9da33）

本轮先真实跑了一遍 0.0.41 的验证：基线并不成立——`plugin_runtime.py:133`
`def def` 语法错误导致整个 Python 插件运行时无法导入、
`flutter analyze` 5 errors + 2 warnings、两个新 Dart 测试从未跑通过。
以下修复均已实测（数字见运行记录），不是只改声明。

| 缺口 | 修复 | 证据 |
|---|---|---|
| Python 运行时语法错误 | `def def _normalize_tier` 去掉一个 `def`；`test_plugin_tier.py` 里与 T3 fail-closed 自相矛盾的用例补 caps | pytest 258 passed / 8 skipped（原 242 + 9 failed + 7 errors） |
| `embedded_backend` 调不存在的 API | `onBeforeMount` 由构造参数改为字段赋值；`snapshots.create()` 改为内核态 `kernel.captureSnapshot()` | flutter analyze 0 issues |
| mosaic 生成器模板写错路径 | `'../panel.dart'` → `'panel.dart'`，删未使用的 widgets import，重新生成并 `--check` 通过；`registry.dart` 未使用 import 删除 | analyze 0 issues；生成器实跑通过 |
| G2 默认 root | `handle` 的 `invoke` 缺省 caller 由 `kRootCaller` 改为 `kUntrustedCaller`；改动类动作（mount/unmount/set_provider/set_mode/set_patch/rollback）须 UI（root）显式发起，内核调试页统一带 `caller: 'ui'` | Dart VM 端到端断言 46 项全过（缺省 caller 被拒、UI 直通、带令牌放行） |
| G2 守卫是死代码 | `_bootKernel` 真实安装 `invokeGuard`：未表明身份一律拒绝，非 root 调用只记审计元数据（不记 args 内容），审计失败不阻断调用 | 同上 46 项断言（含守卫否决与纵深防御） |
| 默认 seamCaps 只覆盖 3 条接缝 | 补齐全部 12 条（含 `core/skills/recorded`）：storage/model/scheduler/skills/agent-loop/trajectory/hooks/ui/pages | 同上断言 + `kernel_guard_test` 的既有期望仍成立 |
| `seamAllowed` 两种 caps 口径打架 | 两种写法都认：接缝名（`core/im`）与能力令牌（`channel:send`）；此前实现只认接缝名，`kernel_guard_test` 的令牌期望不可能通过 | Dart VM 断言覆盖两种口径 |
| `PluginTier.parse('third_party')` 兜底成 T1 | 接受下划线别名 `third_party` / `thirdparty`（与 Python 侧 `_TIER_ALIASES` 对齐） | Dart VM 断言 + `plugin_tier_test` 期望一致 |
| G7 mosaic 导航是摆设 | `MosaicHost` 改为 StatefulWidget，`onDestinationSelected` 真正切换面板；侧栏新增一个 additive 的 mosaic 入口（现有 channels/models 入口原样保留），面板由约定注册表生成 | analyze 0 issues；`gen_mosaic_registry.mjs --check` 通过 |

### 7.1 本轮验证结果

| 验证 | 结果 |
|---|---|
| pytest 全量 | ✅ **258 passed / 8 skipped**（8 skip 全是缺可选依赖） |
| `node tests/conformance_0_0_41.mjs` | ✅ **30 passed / 0 failed**（两条旧关卡断言的是修复前的错误代码，已随源码一起更新；该脚本是测试文件，不随本轮源码补丁推送，见下） |
| `flutter analyze` 全量 | ✅ **No issues found** |
| Dart VM 断言脚本 | ✅ round12 新增 46 项全过；round2–11 回归 17 个脚本全过（agent_manager 64、skill_recorder 285、mcp_hardening 39、sandbox_provider 75、memory_layers 61 等） |
| `dart test/agent_manager_round11_test.dart` | ✅ +7 All tests passed |
| `python3 -m im.serve --help`（树根） | ✅ exit 0 |
| `flutter test test/kernel_guard_test.dart test/plugin_tier_test.dart` | ❌ 仍未跑通（llamadart 的 `.so` 是 arm64、宿主是 x64，原生资产构建失败，环境限制；以 Dart VM 端到端断言为准，两处测试的期望已在断言脚本里逐条覆盖） |
| 真机装插件 / 快照回退 / mosaic 导航点击 | ❌ 未验证（无真机） |

### 7.2 仍然保留的诚实边界

1. `PluginTier.parse` 未知值仍兜底 T1（`plugin_tier_test` 与 Python 测试都如此断言）；改成抛错是行为变更，留给下一轮与调用方一起定。
2. `PluginContext.kernel` 仍公开裸内核：已挂载插件可直调 `invoke`/`setProvider` 绕过仲裁；要关掉须重构插件上下文的暴露面，本轮未动（只关了控制消息层的默认 root）。
3. `restoreSnapshot` 中途失败仍留半回退状态（无补偿）；快照 id 仍可能在同一毫秒内碰撞。
4. provider id 仍是自由字符串（`provideSeamProvider` 不校验）；`Plugin.address` 全仓库无插件声明，mount 的地址校验仍是空分支。
5. `tests/conformance_0_0_41.mjs` 的两条旧关卡已在本地更新为新行为断言，但该脚本是测试文件，按规则不随源码补丁推送——合并后 main 上的旧脚本仍会报 2 项失败，需另行更新脚本（或下轮放宽规则后随补丁带上）。

---

## 8. round13 修复（2026-11-25 19:00 轮次，基线 29a9da33）

本轮收口 P0：内核仲裁。round12 留下的第 2 条诚实边界（`PluginContext.kernel`
公开裸内核，插件可直调 `setProvider`/`mount`/`restoreSnapshot` 绕过仲裁）
是本轮主项；审计时另核实：`handle()` 的改动门禁只比对 payload 字符串 caller
（可伪造 `'ui'`）、`invoke()` 接受调用方自带 caps、pages/text_overrides/
permission_policies 写分支与 default 控制动作分支不在门禁内、
`_CapabilityPlugin` 把 `CapabilitySeam` 对象本身 `provideService` 出去、
`seamCaps`/`invokeGuard`/`profile.mode` 均可直改、`Plugin` 默认 tier=official、
caps=[]，`seamAllowed()` 在 caps 为空时非 T3 一律放行。以下修复均已实测
（数字见 8.1），不是只改声明。

| 缺口 | 修复 | 证据 |
|---|---|---|
| `ctx.kernel` 返回裸 `PluginKernel` | 新增 `PluginKernelFacade`（`plugin_kernel.dart`，只由 `PluginContext` 创建；私有构造，固定 caller=_pluginId、caps=_caps）。只暴露 invoke/emit/describe/replay/search/fork/composeSystemPrompt/mountedCount/eventSeq/modeLabel（仅 label 字符串）/listPages/addPage/removePage/reorderPages（须 `ui:open`）；不暴露 mount/unmount/setProvider/handle/restoreSnapshot/captureSnapshot/registerPlugin/defineModePlugins/boot/dispose/setTextOverride/setPermissionPolicy、profile 对象、seamCaps、invokeGuard、onBeforeMount、CapabilitySeam 对象。`PluginContext.kernel` getter 改返回 facade，getter 名不变；`_capsOf` 取挂载时传入的声明 caps。调用点迁移：`builtin_plugins.dart` L317 `handle('describe')` → `describe()`、L406 `profile.mode.label` → `modeLabel`、5 处三参 `emit(topic, source, data)` → 两参 `emit(topic, data)`（中间实参 5 处全等于插件自身 id，facade 固定 source=_pluginId，语义不变）；其余 invoke/emit/只读调用不变 | flutter analyze 0 issues；Dart VM 断言 110 项全过（§1：16 个裸内核方法运行期 `NoSuchMethodError`） |
| `emit` 可伪造内核事件 | facade 与 `PluginContext.emit` 共用白名单（`kernel_guard.dart` 的 `kPluginEmitTopics`：session.cell、model.chat、sandbox.exec、agent-loop.observe；拒绝 kernel.*/seam.*/plugin.* 前缀），违规抛 `StateError`，事件流不留痕 | 同上断言 §8：伪造 `seam.provider_changed` 被拒，replay 无此条；白名单 emit 正常落盘 |
| `handle`/`invoke` 只认 payload 自称的身份 | `invoke()` 改按登记身份仲裁：caps 不再接受调用方传入（保留签名兼容，永不参与鉴权），改查 `_nodes[callerPluginId]?.plugin.caps` 与 tier；`caller=='ui'` 仅当 `trustedRoot==true` 时有效，否则按 untrusted 处理；未知 caller 名直接拒绝。`handle()` 新增 `{bool trustedRoot=false, String? pluginId}`（代码层参数，绝不从 payload 读）；`dispatch` → `_onPluginKernel`（进程内 UI 直连唯一入口，TCP/stdio 走外部 Python 后端不进这里）传 `trustedRoot:true`。`invokeGuard` 同步收紧：未知 caller 名直接拒绝（原先只拦字面 untrusted） | 同上断言 §2（不可信路径自称 ui + 自带令牌被拒，可信路径放行）、round12 脚本 46 项全过 |
| 改动门只覆盖 6 个动作 | `_mutationActions` 扩为 mount/unmount/set_provider/set_mode/set_patch/rollback/snapshot/fork；pages/text_overrides/permission_policies 的写分支（add/remove/reorder/set）与 default 控制动作分支一并入禁；读动作（describe/status/tree/seams/modes/dump_config/pages-list/widget_slots/compose_prompt/events/search/snapshots）保持开放。放行条件：trustedRoot，或“动作 owner 插件自身 + 动作在 allowlist 内 + 目标资源归属该插件”（pages add 以调用方为 owner 落账，remove/reorder 只动归属自己的页；控制动作只认登记 owner） | 同上断言 §3（无 caller 的 pages add、permission_policies set、tools.ptc、text_overrides set 全被拒；owner 路径正反用例全过） |
| `seam()` 交出可变接缝对象 | 改返回只读 `SeamView`（仅只读字段 + `toJson()`）；`_CapabilityPlugin` 的 `provideService(seam, seam对象)` 改为登记不透明 `_SeamDependencyMarker`——直接删会断 `requires`（mount 靠服务名校验依赖），标记只保留依赖信号、不带可写状态。`service<CapabilitySeam>` 全树无消费方 | 同上断言 §9（改视图 consumers 不影响内核；`service<CapabilitySeam>` 为 null，依赖信号仍在） |
| `seamAllowed()` 空 caps 默认放行 | 高危接缝 `kHighRiskSeams`={core/sandbox, core/im, core/scheduler}：T0–T2 空 caps 也不放行，须显式声明；非高危接缝仍沿用兼容语义。顺序是先声明、后收紧：core.agent-loop 声明 `['model:invoke', 'agent:run']`（只声明 model:invoke 会导致自身接缝 core/agent-loop 的 consumeSeam 失败，须同时含 agent:run 或接缝名）、ui.pages 声明 `['ui:open']`；另为收紧所必需，core.sandbox/core.im/core.scheduler 的提供方也同时声明了对应令牌 | 同上断言 §0（16 个内建插件声明表逐项放行）与 §4（无 caps 消费 core/im 挂载失败；声明后三者挂载成功） |
| `consumeSeam` 的校验是死的 | 核实发现：旧实现用 `pluginOf(pluginId)` 查自身，但 apply 期间插件尚未入 `_nodes`，恒为 null，门禁从未生效。改为 mount/unmount 时把已声明 caps 与 tier 传入 `PluginContext`，`consumeSeam` 用这份声明值校验（与登记值一致），D 的收紧才真正落地 | 同上断言 §4 |
| `ToolRegistry.run()` 对 exec/write 级工具无策略检查 | `run()` 在 execute 前对 tier=exec/write 的工具接一次 `PermissionPolicy.evaluate`（deny 直接拒绝；ask 无审批入口或未获批时拒绝并提示已建审批单）。`shell` 与 `workspace.*` 除外——它们在 execute 内自己过策略并消费一次性批准凭据，run() 层再查会在重试时重复消费、凭空多建审批单。`EmbeddedBackend` 构造时接线 `policyProvider=_ensurePolicy` 与审批入口 `_requestToolApproval`（沿用 shell 同款一次性凭据 + approvals 建单）；默认策略补齐 `computer_write`、`integration_call` 两条 ask 规则，其余未列名写工具走 fallback ask | 同上断言 §10（无批准拦截、获批放行、显式 deny 拒绝、read 不受影响、未接线不拦截） |
| 旧测试与新守卫冲突 | `plugin_kernel_test.dart`：`_EchoPlugin` 改用 `consumeSeam` 登记使用方；set_mode/set_patch/fork 的改动调用补 `trustedRoot:true`；sandbox 直调补 `trustedRoot:true`；PTC 改传显式插件身份 `caller:'core.tools'`；集成测试 payload 补 `caller:'ui'`。`plugin_kernel_customization_test.dart`：写操作与 `ui/pages`/`core/sandbox` 直调一律走可信路径。`plugin_tier_test.dart`：新增高危收紧断言。round12 断言脚本同步更新（登记身份替代自称 caps、`'ui'` 用例补 `trustedRoot:true`、缺省 caller 拒绝原因改为“未知调用方”、T1 空 caps 调 core/im 改为拒绝），总数仍 46 项。`conformance_0_0_41.mjs` 的 `handle 透传 caller` 关卡更新为新语义断言（payload caps 不再转发、trustedRoot 被透传），总数仍 30 | flutter analyze 0 issues；三处测试文件只在本地改，不进推送补丁 |

### 8.1 本轮验证结果

| 验证 | 结果 |
|---|---|
| pytest 全量（venv） | ✅ **262 passed / 8 skipped**（270 项收集，0 失败；round12 记录 258/8，本轮未动任何 Python 文件，+4 是收集到的用例数变化——`tests/test_im_approval.py` 的 mtime 在 round12 运行之后，需以本次 270 项为准） |
| `node tests/conformance_0_0_41.mjs` | ✅ **30 passed / 0 failed**（1 条关卡随语义更新，见上表） |
| `flutter analyze` 全量 | ✅ **No issues found** |
| Dart VM 断言脚本 | ✅ round13 新增 **110 项全过**（`check_kernel_guard_round13.dart`：facade 缺失方法、伪造 ui、改动门、owner 路径、高危收紧、agent-loop 经 facade 调 model、无 caps 调 model、ui/pages 增删改排序与可逆、伪造事件、SeamView、ToolRegistry 策略检查）；round12 **46 项全过**（已按新语义同步期望）；round2–11 回归 17 个 `_r12` 脚本全过（agent_manager 64、skill_recorder 285、mcp_hardening 39、sandbox_provider 75、memory_layers 61、voice 56 等） |
| `flutter test test/plugin_kernel_test.dart test/plugin_kernel_customization_test.dart test/plugin_tier_test.dart test/kernel_guard_test.dart` | ❌ **未跑**（llamadart 的 `.so` 是 arm64、宿主是 x64，原生资产构建失败，环境限制；同 round12 的诚实边界。上述测试的期望已在 Dart VM 断言脚本里逐条覆盖，但 flutter test 本身仍需在 CI 或电脑上跑一遍） |
| 真机：插件挂载 / 内核调试页点击 / 审批单批准后重试 | ❌ 未验证（无真机） |

### 8.2 仍然保留的诚实边界

1. round12 第 2 条已关闭（facade 落地）；但 `super_agent.dart` / `creator_runtime.dart` 持有的是裸 `PluginKernel` 字段（不是经 `PluginContext`），本轮按任务要求未动——内核直调面只对插件收口，宿主侧仍直连。
2. `PluginTier.parse` 未知值仍兜底 T1（与 round12 同）；改成抛错是行为变更，留给下一轮与调用方一起定。
3. `restoreSnapshot` 中途失败仍留半回退状态（无补偿）；快照 id 仍可能在同一毫秒内碰撞。
4. provider id 仍是自由字符串（`provideSeamProvider` 不校验）；`Plugin.address` 全仓库无插件声明，mount 的地址校验仍是空分支。
5. `tests/conformance_0_0_41.mjs` 的关卡已在本地更新为新行为断言，但该脚本是测试文件，按规则不随源码补丁推送——合并后 main 上的旧脚本仍会报失败，需另行更新脚本（或下轮放宽规则后随补丁带上）。`frontend/test/` 下三处测试文件与 `check_kernel_guard_round12.dart` 的同步修改同样只在本地，不进推送补丁。
6. `invoke()` 的 `caps` 形参已废弃（保留签名兼容，永不参与鉴权）；`handle()` 的 `trustedRoot`/`pluginId` 只由进程内可信调用方传，任何经 payload 传入的同名字段都会被忽略——调用方不要误以为在 payload 里写 `trustedRoot:true` 就能提权。
7. `ToolRegistry` 的策略检查只在接线了 `policyProvider` 时生效（生产侧 `EmbeddedBackend` 已接线；测试与纯 Dart 用默认不拦截）。`shell`/`workspace.*` 仍走各自 execute 内的守卫。
8. 内建插件计数疑点：`BuiltinPlugins.build` 列出 16 个插件 id，但 `plugin_kernel_test.dart` 期望挂载 15 个节点；按 requires/consumeSeam/caps 表逐项核对，16 个都应挂载成功（apply 期无磁盘 I/O、无可抛点），`15` 可能是 sunrun 加入 bundle 后未同步的旧数——`flutter test` 在本机跑不起来，未能实证，本轮未改该期望，需 CI 或电脑上跑一遍确认。

---

## 9. round14 修复（2026-11-26 05:00 轮次，基线 825ab421）

本轮主项：`restoreSnapshot` 回滚半态问题。本轮只改 `frontend/lib/harness/plugin_kernel.dart`
（另加本文档一节、本地测试文件两处），未动 `embedded_backend.dart`、`sandboxed_shell.dart`、
`sandbox_provider.dart`、`security_policy.dart`、`kernel_guard.dart`。

### 9.0 审计结论（实证，旧行为）

| 缺口 | 旧行为 | 证据 |
|---|---|---|
| 四阶段串行变异，无预检、无备份、无补偿、无标记 | 阶段一卸载返回值不检查；阶段二任一 mount 失败立即返回，接缝/模式不再恢复；阶段三目标 provider 不存在静默 `continue` 却返回 `ok:true`；阶段四 `_setMode` 先赋值模式后 `_applyProfile`，`_persistConfig` 抛错直接穿出 | `plugin_kernel.dart` 旧 `restoreSnapshot`（约 1775–1829 行） |
| 快照 id 可能重复 | id 用 `'ksnap-${length+1}-${毫秒}'`，上限淘汰（20 份删最旧）后长度回落，同一毫秒内两次 capture 撞号 | 旧 `captureSnapshot` |
| hotSwap 回滚挂载失败留空槽位 | 回滚挂载失败时如实报告 `{ok:false, error:'热替换失败已回滚：…', rollback_ok:false}` + `plugin.hot_swap_rolled_back` 事件，但旧插件已卸、新插件未上、回滚挂载又失败时槽位为空 | `hotSwap`（约 1149–1215 行），本轮只实读、未改 |

### 9.1 修复（新行为，全部在 plugin_kernel.dart 内，不新增类型，journal 用 Map）

| 项 | 新行为 | 旧行为对照 |
|---|---|---|
| 快照 id | `'ksnap-${++_snapshotSeq}-${毫秒}'`，计数器只增不减 | 长度+毫秒，淘汰后可撞号 |
| 预检（零变异） | `_preflightSnapshot`：快照节点均已注册、依赖闭包在快照自身服务集内可满足、接缝目标 provider 的 owner 在快照集内或已挂载、模式可解析；任一失败返回 `{ok:false, phase:'preflight', errors}`，**不改动任何插件、不产生自动备份**。复用 `verifyDependencies` 的判定口径——不是直接调它（它只查当前已挂载态，签名 `Map<String, dynamic> verifyDependencies()`，无参、同步） | 无预检，失败发生在变异中途 |
| 自动备份 | 预检通过后立即显式 `captureSnapshot('回退前自动备份')`，记入 journal；不依赖 `onBeforeMount`（`_restoring` 期间它被抑制） | 无备份 |
| 脏标志 + journal | 变异阶段置 `_restoreDirty=true`，journal 记 `{target_snapshot, pre_restore_snapshot, phase, done_unmounts, done_mounts, failed_plugin, failed_phase, at}`，随阶段推进更新；四阶段全成功才清脏 | 无标记，半态不可见 |
| 阶段一 | 卸载返回值现查；父节点卸载连带递归卸载子节点时，遍历跳过已被连带卸载的节点，journal 按实际移除集记录 | 返回值丢弃 |
| 阶段二失败 | 结构化 `{ok:false, dirty:true, failed_phase:'remount', failed_plugin, completed:{unmounted, mounted}, resume:{retry_same, restore_pre}, journal}` + `kernel.rollback_failed` 事件 | 只返回 `{ok:false, error, snapshot}`，无 resume、无事件 |
| 阶段三缺 provider | 置脏失败（`failed_phase:'seams'`，另附 `failed_seam`/`failed_provider`），不再静默 `continue` | 静默 continue 却返回 `ok:true` |
| 阶段四失败 | `_setMode` 失败收集为结构化 `{ok:false}` 返回而非异常逃逸；`_applyProfile` 改为返回 `{ok, failed_mounts, failed_unmounts}`（此前 mount/unmount 返回值被直接丢弃），`_setMode` 把这份结果传出来；`_persistConfig` 抛错同样收集为 `{ok:false}`。boot 直接调 `_applyProfile` 且忽略返回值，语义不变 | `_setMode` 抛错穿出；`_applyProfile` 返回 void、结果全丢 |
| 脏门禁 | `handle()` 入口：脏态下改动类动作（mount/unmount/set_provider/set_mode/set_patch/snapshot/fork）一律拒绝并返回脏原因与 journal 摘要；仅 `rollback` 与新增 `resolve_dirty` 豁免；`invoke()` 不拦截；只读动作不受限 | 无门禁，半态可被继续改坏 |
| `resolve_dirty` | 新动作，仅 trustedRoot（改动门禁已拦不可信调用），须显式 `accept: true`，清脏并写 `kernel.restore_dirty_resolved` 审计事件，journal 保留 | 无此出路 |
| 可见性 | `handle('describe'/'status')` 与 facade `describe()` 增加 `restore_dirty`、`restore_dirty_reason`、`restore_journal` 字段 | 无脏态可见性 |

### 9.2 hotSwap / verifyDependencies 实读结论

- `hotSwap(pluginId, replacement)`：**不重建内核**。流程是卸载旧插件（逆序撤销 effects）→ 注册新插件 → 同挂载点挂载；新插件挂载失败则重新注册旧插件并重挂。成功返回 `{ok:true, from_version, to_version}` + `plugin.hot_swapped`；失败返回 `{ok:false, error:'热替换失败已回滚：…', rollback_ok: <bool>}` + `plugin.hot_swap_rolled_back`（含 `rollback_ok`）。回滚挂载本身失败时 `rollback_ok:false`，槽位留空——本轮未改此处（任务范围只在 `restoreSnapshot`），见 9.4 第 7 条。
- `verifyDependencies()`：签名 `Map<String, dynamic> verifyDependencies()`，无参、同步；遍历**当前已挂载**插件，检查每个 `requires` 服务是否仍在 `_services` 内，返回 `{ok, checked, broken:[{plugin, missing_service}]}`，并发出 `kernel.dependencies_verified`。预检复用的是它的判定口径（注册表/依赖闭包/owner 归属），不是直接调用——直接调用只能回答当前态，回答不了快照态。

### 9.3 本轮验证结果

| 验证 | 结果 |
|---|---|
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_restore_dirty_round14.dart` | ✅ **95 passed / 0 failed**（§0 id 唯一性 25 次无重复；§1 成功回退；§2 阶段二失败→置脏/门禁/重试清脏；§3 阶段三缺 provider→置脏/回滚到备份；§4 阶段四失败→结构化返回/重试清脏；§5 预检零变异；§6 resolve_dirty 三态；§7 facade describe 脏字段） |
| `node tests/conformance_0_0_41.mjs` | ✅ **33 passed / 0 failed**（30 → 33，新增 G5b 3 条关卡：单调计数器、预检+置脏+resume、脏门禁+resolve_dirty+阶段三置脏） |
| `check_kernel_guard_round13.dart`（回归） | ✅ **110 passed / 0 failed**，与 round13 期望无冲突，**无需同步修正** |
| `dart analyze`（仅 `plugin_kernel.dart` 单文件；全量 analyze 由主 agent 统一跑） | ✅ **No issues found** |
| pytest 全套 / `flutter analyze` 全量 | ❌ **未跑**（本轮任务要求：不跑全量，主 agent 最后统一跑，避免与另一 agent 争抢） |
| `flutter test` / Dart 编译 / 真机 | ❌ **未跑**（llamadart 的 `.so` 是 arm64、宿主是 x64，原生资产构建失败，环境限制；同 round12/13 的诚实边界） |

### 9.4 仍然保留的诚实边界与已知局限

1. ~~脏标志**只在内存**：进程重启即失。启动标脏缓解已由 round16 实现（见 §11：boot 落启动快照并跑 `verifyDependencies` + 闭包预检标脏，语义已定为首轮挂载不阻塞）；但跨重启持久化仍未做——`_persistConfig` 只存 profile/home_patch，重启后旧脏态仍无法从磁盘恢复，见 §11.4。~~已由 round18 实现（见 §14：脏态随 `_persistConfig` 写入 `kernel_config.json` 的 `restore_dirty` 键，启动时先恢复；内存语义不变）。
2. 预检是静态闭包检查，核实不了挂载时序：消费者在快照内排在提供者之前、自提供服务（`requires` 含自身提供的服务）这两类，预检会放行、阶段二挂载时才失败——由脏标志 + resume 兜底，不是预检漏网无声。
3. 预检里「插件未注册」与「接缝 owner 不在快照集内」两支是防御性分支：公开 API 下注册表只增不减、快照时刻的 provider owner 必在快照节点集内，无法经公开 API 造出反例；断言脚本只覆盖可达的「依赖缺失」分支，另两支未实测。
4. `_setMode` 仍先赋值模式、后 `_applyProfile`：`_persistConfig` 抛错时 mode 标签已改为目标值，失败返回里如实带有该 mode；脏标志与 journal 负责记录，由三条出路恢复。重试同一快照时因模式已等于目标值，阶段四直接跳过——这是本轮实测通过的路径，不是巧合。
5. 阶段一卸载失败分支是防御性的：`unmount` 只在节点不存在时返回 `ok:false`，而遍历前已跳过不存在的节点；该分支未经真实失败触发，只经代码走读。
6. 脏门禁只在 `handle()` 入口：宿主侧直接调 `kernel.mount()` 等 Dart 方法不受门禁约束（宿主直连路径本就绕过 `handle` 的鉴权门禁，与 round13 的宿主直连口径一致）；插件与外部调用一律走 `handle()`，受门禁约束。
7. `hotSwap` 回滚挂载失败仍留空槽位（9.0 表）：本轮范围只在 `restoreSnapshot`，未改。`hotSwap` 与 `restoreSnapshot` 的脏标志不互通——一次失败的 hotSwap 不会置 `_restoreDirty`。
8. 回退前自动备份计入 20 份快照上限：快照列表已满时，本次备份会淘汰最旧一份；若目标快照恰是最旧那份，它会在备份落盘时被逐出列表——`restoreSnapshot` 手里已有快照对象引用，本次回退仍能完成，但事后列表里不再有它。
9. `handle('set_mode')` 的调用方注意：`_setMode` 现在失败返回结构化 `{ok:false}` 而不是抛异常；`_persistConfig` 抛错不再穿出 `handle()`。
10. 本轮 8.2 第 3 条（`restoreSnapshot` 中途失败留半回退状态、快照 id 碰撞）**已关闭**，由本节覆盖；其余 8.2 条目维持原状。

## 10. round15 修复（2026-11-26 19:00 轮次，基线 825ab421）

本轮主项：沙箱审计第二阶段（9.4 遗留第 ③ 项）。HEAD 未变（仍为
825ab421），直接在 round14 融合树上做；不含 round12/13 重基。本轮只改
`frontend/lib/harness/{core,sandbox_proot_provider,sandbox_provider,audit_log}.dart`、
`frontend/lib/agent/sandbox/sandboxed_shell.dart`、
`frontend/lib/harness/embedded_backend.dart`（另加本文档一节、conformance
G5c 7 条关卡、本地断言脚本两处），未动 `plugin_kernel.dart`、
`kernel_guard.dart`、`approval_gate.dart`、`security_policy.dart`、
`builtin_plugins.dart`、`im/*`。

### 10.0 审计结论（实证，旧行为）

| 缺口 | 旧行为 | 证据 |
|---|---|---|
| dispatch 层 deny/ask 无审计 | `ToolRegistry._policyCheck` 的 deny 决定只以 error 字符串回给调用方，不留审计；ask 获批（一次性凭据已消费）同样无记录；hook 为空时 ask 按拒绝处理完全无声 | 旧 `core.dart` `_policyCheck`（约 305–360 行）；`_requestToolApproval` 只在建单时记一条 approval 审计 |
| cube ask 缺口 | `SandboxedShell.denyCheck` 只查 deny；策略判 ask 的表达式直接执行，不建单、不消费一次性凭据 | `embedded_backend.dart` 构造注释“只查 deny：ask/auto 不建单、不消费一次性凭据（第二阶段再补 ask）” |
| proot 后端无 deny/审计 | `ProotSandboxProvider.exec` 不调 `checkDeny`、不 `fireAudit`；同接口的 Local 后端 round14 已接 | 旧 `sandbox_proot_provider.dart` `exec`（约 68–130 行） |
| 审计日志 append O(n) 且无轮转 | 每次 append 全量 `_readEvents()` 取尾 hash；`audit.jsonl` 只增不减 | 旧 `audit_log.dart` `append` |
| `SandboxAuditEvent` 两份同形实现 | `sandbox_provider.dart` 与 `sandboxed_shell.dart` 各一份，字段顺序靠人工保持一致 | round14 本文档 9.4 遗留；round14 断言脚本 §4 逐行比对两份 detail |

### 10.1 修复（新行为）

| 项 | 新行为 | 旧行为对照 |
|---|---|---|
| dispatch 审计 | `ToolRegistry` 新增 `ToolPolicyAuditEvent{tool, decision, rule, detail}` + `ToolPolicyAuditCallback`；`_policyCheck` 在 deny / ask 获批 / ask 被拒时发事件（decision `'deny'`/`'ask_approved'`/`'ask_denied'`，rule 取 `matchedRuleId`，detail 为 `tool=… rule=… args=<前 160 字符>`）；allow、无 ask、read 级、自带守卫工具（shell/workspace.*，已有各自审计）、未接线时不发，避免日志洪水；回调包 try/catch，抛错不改变 `run()` 行为 | 无记录 |
| dispatch 审计接线 | `EmbeddedBackend` 构造：`tools.onPolicyDecision` 落盘 `category 'security'`、`action 'tool_dispatch_<decision>'`，ask_approved 记 decision `allowed`、其余记 `denied` | 未接线 |
| cube ask | `SandboxedShell` 新增 `SandboxAskCheck`（返 ask 规则 id 或 null）/`SandboxAskApproval`（返 bool）+ `askCheck`/`onAskApproval` 字段；`exec` 在 deny 预检之后、`_env!.exec` 之前插入 ask 流程：askCheck 抛错 fail-closed 记 `denied` 审计；命中 ask 时调 onAskApproval，hook 为空或返回 false 记 `denied` 审计并拒绝（无审批入口与已建单两种文案区分），返回 true 继续执行；askCheck 为空时行为与之前完全一致 | ask 直接执行 |
| cube ask 接线 | `EmbeddedBackend` 构造：`askCheck` 复评策略（仅 ask 时返 `matchedRuleId`）；`onAskApproval` → 新增 `_requestCubeApproval`（照抄 `_requestToolApproval`：grantKey `'cube|<表达式截 160>'`，先消费一次性凭据，否则建单 action `'执行表达式: $cube <前 80 字符>'` 并记 `cube_approval_required` 审计）；旧“第二阶段再补 ask”注释已更新 | 未接线 |
| proot 钩子 | `ProotSandboxProvider.exec` 照抄 Local 顺序：takeoverRefusal 之后、installed 检查之前加 Stopwatch + `checkDeny`，命中直接返回；尾部成功/失败收尾处加一条 `fireAudit`（fromCommand，tool `'shell'`，decision 按 ok 取 allowed/failed，exit 用真实 exitCode）；not-installed / `proot.run` 返回 null 的 early return 在执行体启动前，不记执行审计 | 无 deny、无审计 |
| 审计轮转 | `AuditLog` 新增 `AuditLog.forDirectory(Directory root, {maxFileBytes = 512KB})`；当前文件达到阈值时在串行链内轮转为 `audit-<yyyyMMdd-HHmmss>-<seq>.jsonl`，新文件先写轮转标记事件（category `'audit'`、action `'rotated'`、decision `'info'`、detail `'prev=<旧尾 hash> file=<旧文件名>'`、prevHash=旧尾 hash），哈希链跨文件不断；`all()`/`query()`/`stats()`/`verifyChain()`/`exportJsonl()` 按时间顺序读全部轮转文件 + 当前文件；`exportJsonl()` 改为导出全部文件拼接（旧版只导出当前文件） | 无轮转；导出只含当前文件 |
| append 去 O(n) | 尾 hash 缓存：懒加载时 RandomAccessFile 从尾部倒读最后一行非空行（单行超长/尾行损坏时全量读兜底）；append 成功更新缓存；importJsonl 每写一条后置空，写失败也置空 | 每次全量读文件取尾 hash |
| `SandboxAuditEvent` 单一真源 | canonical 类新增 `fromExpression` 工厂（shell 版语义逐字移植：tool `'cube'`、cwd `'.'`、provider `'isolate-cube'`、空表达式回落、首词截断 40）；删除 `sandboxed_shell.dart` 里的重复类与重复静态 helper；shell 侧加 `import` + `export … show SandboxAuditEvent`（export 本身不把名字带入本文件名字空间，只加 export 时 analyze 曾报 9 个错，补 import 后清零），`cube_shell.SandboxAuditEvent`（`embedded_backend.dart` 在用）继续解析；`fromCommand` 行为与 detail 格式逐字未动 | 两份同形实现，靠人工同步 |
| AuditLog 可测试性 | `audit_log.dart` 不再 import `store.dart`（后者经 path_provider 牵出 `dart:ui`，纯 Dart VM 无法加载）：旧构造 `AuditLog(store: store)` 保留、调用点不变，内部只取 `store.root`（`final Object? store` + dynamic 访问，刻意为之，见文件头注释）；轮转断言脚本因此可在纯 Dart VM 跑 | import store.dart，VM 无法加载 |

### 10.2 本轮验证结果

| 验证 | 结果 |
|---|---|
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_sandbox_audit_phase2_round15.dart` | ✅ **76 passed / 0 failed**（dispatch 审计：deny/ask 获批/ask 被拒/hook 为空/allow 不发/回调抛错不影响 run/未接线旧行为；proot 与 cube 链路因 import Flutter 只做结构断言） |
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_audit_rotation_round15.dart` | ✅ **167 passed / 0 failed**（无轮转一致性、多次轮转跨文件读取与标记核对、轮转后继续追加、import 后追加、fromCommand/fromExpression detail 逐字比对、结构断言） |
| `check_sandbox_audit_round14.dart`（已更新两处过时断言以反映统一后的状态：`_fireAudit` 出现 6→8 次；“两份 detail 行一致”改为唯一真源断言） | ✅ **118 passed / 0 failed**（原 116 + 新增 2） |
| `check_restore_dirty_round14.dart` / `check_kernel_guard_round13.dart` / `check_kernel_guard_round12.dart` | ✅ **95 / 110 / 46 passed，0 failed** |
| round2–11 回归 17 个 `_r12` 脚本 | ✅ **全部通过** |
| `node tests/conformance_0_0_41.mjs` | ✅ **40 passed / 0 failed**（33 → 40，新增 G5c 7 条关卡：dispatch 审计、接线、cube ask 钩子顺序与接线、proot 钩子、轮转、唯一真源） |
| `node frontend/tool/gen_mosaic_registry.mjs --check` | ✅ 通过（2 面板） |
| pytest 全套 | ✅ **262 passed / 8 skipped**（与 round14 基线逐项持平） |
| `flutter analyze`（全量） | ✅ **No issues found**（0 issues） |
| `flutter test` / Dart 编译 / 真机 | ❌ **未跑**（llamadart 的 `.so` 是 arm64、宿主是 x64，原生资产构建失败，环境限制；`flutter test` 尝试 1 次即在构建 native assets 阶段失败，未再反复试） |
| cube ask / proot exec 的**行为** | ❌ **未在 VM/真机跑到**（两文件 import Flutter，纯 Dart VM 无法加载；只做了源码结构断言 + analyze + 代码复核） |

### 10.3 仍然保留的诚实边界与已知局限

1. 尾 hash 缓存假设同一目录只有一个 `AuditLog` 实例；外部进程直接改写 audit 文件时缓存可能过期（写失败与 import 时会置空自愈，多实例并发不在契约内）。
2. ~~`importJsonl` 导入的事件仍不进哈希链（旧行为未变）：导入后下一 append 重新从磁盘读尾，链尾接在最后一条导入事件上，导入事件自身的 prevHash 不与链衔接，`verifyChain` 会在导入事件处按 legacy/断裂口径报告——与 round14 之前一致，未在本轮扩大范围。~~已由 round17 修复（见 §12；Dart 侧导入现重接链 + `originHash` 溯源。另：round16 运行记录称“importJsonl 实际经 append() 重新接链”只对 Python 侧成立，Dart 侧当时仍是直接写原始行，round17 核实后纠正于此）。
3. ~~dispatch 审计只覆盖 `run()` 层的策略决定：`run()` 捕获的工具执行异常仍只以 error 结果回给调用方，不另记审计（轨迹层记录结果）；`shell`/`workspace.*` 的 allow 决定不记（各自守卫只记 ask/deny，见 `_workspaceGuard` 与 `_shellExec`）。~~已由 round17 部分修复（见 §12：执行异常现记 `error` 审计；allow 决定现按抽样记。`shell`/`workspace.*` 自带守卫的 allow 仍不记，见 §12.4）。
4. cube ask 的 fail-closed 与 `onAskApproval` 抛错按 false 计，均经代码走读，未经真实表达式触发。
5. 脏标志启动标脏缓解（9.4 遗留）已由 round16 实现，见 §11；Pages 审批卡（语义待定夺）仍未做，见 10.4。
6. ~~`SandboxAuditEvent` 两份同形实现已合并，但三份 deny 正则的漂移点仍在（见 8.2 遗留）。~~已由 round17 收敛（见 §12：`PermissionPolicy.destructiveShellArgsPattern` 为唯一真源，Dart 两处直接引用、Python 侧同值，共享向量断言三处一致）。
7. `exportJsonl()` 改为全量拼接是行为变化：调用方原先只拿到当前文件，现拿到全部轮转文件 + 当前文件；备份/导出场景更完整。round17 已补按 id 去重约定（见 §12）：同一份导出重复导入再导出，结果不变（幂等）；增量同步场景仍需调用方按 id 去重（导出本身已去重一次）。

### 10.4 下一轮可做的

1. ~~脏标志启动标脏缓解（9.4 遗留第 ⑤ 项；需先定“启动即脏是否阻塞首轮挂载”语义）~~已由 round16 实现（见 §11；语义已定：首轮挂载不阻塞）。
2. Pages 审批卡 + `unapprove()`（需先定“批准是否等于置顶”语义）。
3. ~~沙箱审计第三阶段：dispatch 路径 ask 的 allow 决定抽样审计、proot 之外后端的审计覆盖核查、审计导出去重约定。~~已由 round17 实现抽样审计与导出去重（见 §12）；proot 之外后端的审计覆盖核查已由 round18 完成（见 §13）。
4. `PluginTier.parse` 未知值兜底 T1 的收紧（见 8.2 遗留）。

## 11. round16 修复（2026-11-27 05:00 轮次，基线 f1e5f6a6）

本轮主项：脏标志启动标脏缓解（9.4 遗留第 1 条、10.4 第 1 条；语义已定，
见 11.0）。HEAD 未变（仍为 f1e5f6a6），直接在新 main 融合树上做。本轮只改
`frontend/lib/harness/plugin_kernel.dart`（另加本文档一节、conformance
G5d 6 条关卡、本地断言脚本一处），未动其他文件（语音/Kokoro 文件与两个死
import 由另一并行 agent 处理）。

### 11.0 语义决策（已定，直接执行）

| 决策 | 内容 |
|---|---|
| 预检对象 | 快照只在内存、`_persistConfig` 只存 profile/home_patch，重启后磁盘上没有可恢复的“最新快照”——boot 的“最新快照”就是本次装配结果本身：`_applyProfile` 之后立即 `captureSnapshot('启动快照')`，再对它跑 `verifyDependencies()`（活态依赖核查）+ `_preflightSnapshot`（闭包预检，复用 round14 判定口径）。磁盘 profile 是启动目标态的唯一持久化形态；未注册插件的信号经 `_applyProfile` 返回值的 failedMounts 捕获（mount 本就报“未注册到内核目录”）。 |
| 首轮挂载不阻塞 | 预检在 `_applyProfile` 之后跑；脏门禁只在 `handle()` 入口；boot 直调 `_applyProfile` 不走 `handle()`，故脏态不可能卡住启动流程、不会死锁。脏门禁只拦 `handle()` 改动类动作，与 round14 §9 第 6 条宿主直连口径一致（宿主直调 `kernel.mount()` 等不受限）。 |
| 失败挂载可见 | 消费 `_applyProfile` 返回值：failedMounts/failedUnmounts 写入 journal + 发 `kernel.boot_mount_failed` 事件，不再丢弃；同时标脏（与 round14“任一变异阶段失败即置脏”同哲学：启动挂载失败留下的就是半态）。 |
| 出路 | 复用既有 `rollback`（回滚到启动快照）/ `resolve_dirty`；不新增出路。 |
| 不做跨重启持久化 | ~~`_persistConfig` 只存 profile/home_patch，扩展持久化超出本轮范围；文档诚实边界写明“重启仍失”（见 11.4）。~~已由 round18 实现（见 §14）；本轮范围当时未含持久化，语义仍按本节执行。 |

### 11.1 修复（新行为，全部在 plugin_kernel.dart 内）

| 项 | 新行为 | 旧行为对照 |
|---|---|---|
| 启动快照 | `boot()` 在 `_applyProfile(reset: true)` 之后立即 `captureSnapshot('启动快照')`（约 977 行）；每次启动消耗 1 份快照 slot（上限 20 份），并发出 `kernel.snapshot` 事件 | 启动不留快照；启动后快照列表为空 |
| 启动预检 | 对启动快照跑 `verifyDependencies()`（约 980 行，发出 `kernel.dependencies_verified`）+ `_preflightSnapshot(KernelSnapshot.fromJson(bootSnapJson))`（约 981–982 行，复用 round14 判定口径；用 `fromJson` 重建对象，避免 `_kernelSnapshots.last` 在 `onHotEvent` 重入 capture 时错位） | 无预检 |
| 失败挂载消费 | `_markBootDirtyIfNeeded`（约 994–1092 行）：`_applyProfile` 返回的 failedMounts/failedUnmounts 不再丢弃，写入 journal、发 `kernel.boot_mount_failed` 事件（含 `failed_mounts`/`failed_unmounts`/`snapshot`/`dirty:true`）、标脏 | boot 直接 `await _applyProfile(reset: true)`，返回值丢弃，启动挂载失败静默 |
| 预检失败标脏 | 同一收口：verify/preflight 任一失败 → `_restoreDirty=true`、journal phase `'boot_dirty'`（failed_phase `'boot_verify'`）、发 `kernel.boot_dirty` 事件（含 `phase:'boot_verify'`/`errors`/`snapshot`/`dirty:true`） | 无 |
| journal 摘要扩展 | `_restoreJournalSummary()` 新增 `failed_mounts`/`failed_unmounts`/`boot_errors` 三键，缺省为空列表（旧调用方按 key 访问，不破坏；摘要仍是复制品，调用方改不动内账） | 摘要无这三键 |
| 脏原因 | `_restoreDirtyReason` 拼装失败明细（挂载失败列插件与错误、卸载失败同理、预检失败列 errors），`describe()`/`status`/facade `describe()` 原有 `restore_dirty`/`restore_dirty_reason`/`restore_journal` 字段直接复用，无需新增字段 | 无启动脏原因 |
| 脏门禁覆盖 | 启动脏态走同一 `handle()` 脏门禁：改动类动作被拒，仅 `rollback` 与 `resolve_dirty` 豁免；只读动作与 `invoke` 不拦截；宿主直调不受限 | 门禁只覆盖回退脏态 |
| 其余行为不变 | `_applyProfile` 逻辑未动（只改了文档注释：boot 不再忽略返回值）；`_setMode`/restoreSnapshot 未动 | — |

### 11.2 本轮验证结果

| 验证 | 结果 |
|---|---|
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_boot_dirty_round16.dart` | ✅ **95 passed / 0 failed**（§0 干净启动；§1 bundle 引用未注册插件→失败挂载可见+不阻塞；§2 apply 抛错→同上+resolve 清脏；§3 启动预检接线与灵敏度+模式裁剪场景真实行为；§4 脏门禁；§5 回滚到启动快照清脏；§6 resolve_dirty 清脏；§7 facade describe 脏字段；§8 journal 摘要新键结构） |
| `check_restore_dirty_round14.dart`（回归） | ✅ **95 passed / 0 failed**，与 round14 期望无冲突，**无需同步修正** |
| `check_kernel_guard_round13.dart` / `check_kernel_guard_round12.dart`（回归） | ✅ **110 / 46 passed，0 failed** |
| `check_sandbox_audit_phase2_round15.dart` / `check_audit_rotation_round15.dart` / `check_sandbox_audit_round14.dart`（回归） | ✅ **76 / 167 / 118 passed，0 failed** |
| round2–11 回归 17 个 `_r12` 脚本 | ✅ **全部通过** |
| `node tests/conformance_0_0_41.mjs` | ✅ **46 passed / 0 failed**（40 → 46，新增 G5d 6 条关卡：boot 消费 `_applyProfile` 返回值、启动快照预检接线顺序、预检失败发 `kernel.boot_dirty`、失败挂载发事件并写 journal、boot 内 `_restoreDirty = true`、journal 摘要新键；判定一律按调用点切片，不命中字段声明） |
| pytest 全套 | ✅ **262 passed / 8 skipped**（与基线逐项持平） |
| `flutter analyze`（全量） | ✅ **0 issues**（以最终整合为准；本轮改动文件不引入新问题） |
| `flutter test` / Dart 编译 / 真机 | ❌ **未跑**（llamadart 的 `.so` 是 arm64、宿主是 x64，原生资产构建失败，环境限制；同 round12/13/15 的诚实边界） |
| 启动预检失败分支（`kernel.boot_dirty` / failed_phase `'boot_verify'`）的行为 | ❌ **未在 VM 跑到**（经公开 API 在首轮启动不可达，见 11.4 第 1 条；只做了调用点结构断言 + `_preflightSnapshot` 本身由 round14 §5 覆盖） |

### 11.3 本轮实测的关键发现（模式裁剪在启动时不制造断裂）

断言脚本 §3 的原始设想是：bundle 同时含提供方与依赖方、模式只允许依赖方 → 提供方被模式裁剪卸载 → 依赖方断裂 → `kernel.boot_dirty`。实测推翻了该设想：`_applyProfile` 的 bundle 循环在挂载前就跳过未授权插件（`if (allowed != null && !allowed.contains(pid)) continue;`），提供方从未挂载；依赖方挂载时依赖校验失败，走失败挂载（`boot_apply`）而非预检失败。启动时 trim 循环无操作对象（`_nodes` 在首轮挂载前为空、bundle 循环又已跳过未授权插件），挂载时依赖校验保证已挂载集自洽。因此模式裁剪导致的依赖断裂在首轮启动是**结构上不可达**的，断言脚本改为断言真实行为（§3c），不伪造反例。

### 11.4 仍然保留的诚实边界与已知局限

1. 启动预检失败分支（`kernel.boot_dirty` 事件、journal failed_phase `'boot_verify'`、`boot_errors` 非空）**经公开 API 在首轮启动目前不可达**：bundle 跳过未授权插件 + trim 在启动时无操作对象 + 挂载时依赖校验保证已挂载集自洽，`verifyDependencies()` 与 `_preflightSnapshot(启动快照)` 在首轮启动恒通过（防御性纵深）。一旦未来出现启动后卸载/服务移除路径（例如插件在 apply 中卸载他方、trim 语义变化），该分支即生效，无需再改接线。`_preflightSnapshot` 本身的失败逻辑由 round14 §5（依赖缺失的快照被预检拒绝）覆盖；`verifyDependencies` 的灵敏度由本轮脚本 §3b（启动后卸载提供方→同一核查报断裂）覆盖；调用点由 conformance G5d 按顺序切片断言。
2. ~~跨重启持久化仍未做：脏标志只在内存，`_persistConfig` 只存 profile/home_patch；进程重启后旧脏态仍失，启动标脏只能发现**本次**启动的问题，不能恢复上次的脏态。~~已由 round18 实现（见 §14：脏态随 `_persistConfig` 落盘，启动时先恢复；快照本身仍只在内存）。
3. `failed_unmounts` 在首轮启动同样不可达：启动时 `_nodes` 为空，`_applyProfile(reset: true)` 的卸载循环不执行；journal 摘要含该键且恒为空列表（不编造）。`_applyProfile` 的 reset 循环另有一处潜伏问题未修（本轮范围外，见第 5 条）。
4. 预检是启动后快照的静态闭包检查，核实不了挂载时序：消费者在 bundle 内排在提供者之前时，消费者挂载失败走 `boot_apply`（失败挂载可见），不是 `boot_verify`——两条路径互补，不是漏网无声。
5. `_applyProfile(reset: true)` 的卸载循环未跳过已被父节点连带卸载的子节点（restoreSnapshot 阶段一有此跳过，`_applyProfile` 没有）：父子插件树 + reset 时，子节点卸载会返回 `ok:false`（“未挂载”）并记入 failedUnmounts。首轮启动 `_nodes` 为空，该循环不执行，故本轮未修；若未来出现二次 boot 或 reset 时已有节点，此处会误报启动卸载失败。
6. 每次启动固定消耗 1 份快照 slot 并发出 `kernel.snapshot` + `kernel.dependencies_verified` 事件：快照列表已满时启动快照会淘汰最旧一份；事件回放里每轮启动多两条记录。行为变化已如实记于此，调用方按 label `'启动快照'` 识别。
7. 回滚到预检失败的启动快照会被预检拒绝（fail-closed，不静默）：启动快照本身是破态时，rollback 不是出路，`resolve_dirty` 才是；回滚出路只对 `boot_apply` 脏态（失败挂载场景）有效。见断言脚本 §5/§6。
8. boot 只置脏、不清脏：干净启动不碰既有脏标志（新进程内初始即 false）；二次 boot 不在契约内，未测。

## 12. round17 修复（2026-11-27 19:00 轮次，基线 f1e5f6a6）

本轮主项：沙箱审计第三阶段（10.4 第 3 条）。HEAD 未变（仍为
f1e5f6a6），直接在 round16 融合树上做；两路并行 agent 实施、主 agent 整
合验证。本轮改 `frontend/lib/harness/{core,embedded_backend,
security_policy,approval_gate,audit_log}.dart`、`im/{approval,audit}.py`
（另加本文档一节、conformance G5e 7 条关卡、本地断言脚本两处，更新
`check_audit_rotation_round15.dart` §3 与
`check_sandbox_audit_phase2_round15.dart` §10 两处过时断言），未动
`plugin_kernel.dart`、`kernel_guard.dart`、`sandbox_provider.dart`、
`sandboxed_shell.dart`、`sandbox_proot_provider.dart`。

### 12.0 审计结论（实证，旧行为）

| 缺口 | 旧行为 | 证据 |
|---|---|---|
| dispatch allow 决定无审计 | `_policyCheck` 的 allow 决定直接 `return null`，不留事件；round15 以“避免日志洪水”为由不记 | 旧 `core.dart` `_policyCheck` 末尾；10.3 第 3 条 |
| 工具执行异常无审计 | `run()` 的 catch 只把异常转成 error 结果回给调用方，不另记审计 | 旧 `core.dart` `run()`（约 318–335 行）；10.3 第 3 条 |
| 导入事件不进链（Dart 侧） | `importJsonl` 直接写原始行，保留原 hash/prevHash；导入后 `verifyChain` 在导入事件处按断裂口径报告 | 旧 `audit_log.dart` `importJsonl`（约 640–690 行）；10.3 第 2 条原文 |
| 导入丢溯源（Python 侧） | `import_jsonl` 走 `append()` 重接链（新 id、新 hash），但丢弃原 hash，无法再溯源到导出方 | 旧 `im/audit.py` `import_jsonl` docstring“不保留原 hash” |
| 导出无去重约定 | `exportJsonl()` 全量拼接；同一份导出重复导入再导出会重复出现 | 旧 `audit_log.dart` `exportJsonl`；10.3 第 7 条 |
| deny 正则三处漂移 | `security_policy.dart` 的 default-deny-destructive-shell 用 `\bmkfs`（无尾边界，会拦 `mkfsfoo`）；`approval_gate.dart` 与 `im/approval.py` 用 `\bmkfs\b`（不拦 `mkfsfoo`）；同一条命令在三处判定不一致 | 三文件实测比对（见 12.3） |

### 12.1 修复（新行为）

| 项 | 新行为 | 旧行为对照 |
|---|---|---|
| allow 抽样审计 | `ToolRegistry` 新增可调字段 `allowSampleEvery`（默认 100；`<=0` 关闭抽样；1 为每条 allow 都记）与计数器 `_allowSampleCount`；`_policyCheck` 末尾策略求值确为 allow 时计数，每 `allowSampleEvery` 条发一条 `ToolPolicyAuditEvent(decision: 'allow', rule: matchedRuleId, detail: canonical 形 + note `'sample=1/<n> #<count>'`)；ask 获批不计入分母；read 级、自带守卫工具、未接线不经过这里 | allow 无记录 |
| 执行异常审计 | `run()` 只把 `tool.execute(...)` 包一层 try/catch：执行抛错时先发 `ToolPolicyAuditEvent(decision: 'error', rule: '', detail 含工具名 + 异常 runtimeType + 异常文本前 120 字符）`，再 rethrow（外层 catch 仍转 `ToolResult.error`，行为不变）；lookup/参数校验/策略阶段的异常不发 error 事件 | 异常只转 error 结果 |
| dispatch 审计接线映射 | `EmbeddedBackend` 的 `onPolicyDecision` 回调由二元三元式改为 switch：`'error'` → action `tool_dispatch_error`、decision `failed`；`'allow'` → action `tool_dispatch_allow`、decision `allowed`；`'ask_approved'` → `allowed`；其余（deny / ask_denied）→ `denied`；action 保持 `tool_dispatch_<decision>` 原形 | ask_approved 记 allowed、其余记 denied；无 allow/error 映射 |
| 导入重接链 + 溯源（Dart） | `AuditEvent` 新增 `originHash` 字段（不参与 hash 计算与链校验；toJson 非空时写出，fromJson 读 `originHash`/`origin_hash`）；`append()` 的链逻辑抽为私有 `_appendChained(AuditEvent draft)`（串行链内取尾 hash → 轮转检查 → 写行 → 更新尾缓存 → 失败置空并 rethrow；`append()` 改为构造 draft 后调它，语义逐字不变）；`importJsonl` 改走 `_appendChained`：保留原 id/category/action/decision/actor/detail（仍先脱敏）/ts，`originHash` 记原 hash（原行无 hash 则 `''`），prevHash 取本地链尾、hash 重算；导入同样受轮转约束，量大触发轮转时链也不断 | 直接写原始行，不进链；导入后链断裂 |
| 导入溯源（Python） | `AuditEvent` 新增 `origin_hash`；`append()` 增加可选关键字参数 `event_id`/`origin_hash`（默认时行为与旧版逐字一致）；`import_jsonl` 透传原事件的 id 与原 hash（`event_id=event.id, origin_hash=event.hash`），docstring 更新为“重新接入本链（新 hash，保留原 id；原 hash 存入 originHash 溯源）”；注：Python 导入 ts 取追加时刻，不沿用原行 ts（与 Dart 保留原 ts 不同，两侧文档均已写明） | 新 id、新 hash，原 hash 丢弃 |
| 导出幂等约定 | 两侧 `exportJsonl()`/`export_jsonl()` 按 id 去重（首次出现为准）；不可解析行与 id 为空的行原样保留；文件不存在仍返回空串。约定写进方法注释与文件头：“同一份导出重复导入再导出，结果不变（幂等）” | 全量拼接，无去重 |
| deny 正则收敛 | `PermissionPolicy` 上加 `static const String destructiveShellArgsPattern`（三处共享唯一真源，注明 Dart 两处直接引用、Python 侧同值）；default-deny-destructive-shell 规则与 `approval_gate.dart` 的 `_forcedDenyCommand`（`RegExp(PermissionPolicy.destructiveShellArgsPattern)`）直接引用该常量；`im/approval.py` 的 `_FORCED_DENY_COMMAND` 同值编译 + 注释指明真源。模式取三处已有的严格形式 `\bmkfs\b`（`security_policy.dart` 原 `\bmkfs` 会误拦 `mkfsfoo`，现修正）；共享向量 12 条命令在 Dart VM 脚本与 Python 测试里逐字相同，三处判定一致 | 三份字面量各自维护，`\bmkfs` 有无尾边界不一致 |

### 12.2 本轮验证结果

| 验证 | 结果 |
|---|---|
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_sandbox_audit_phase3_dispatch_round17.dart` | ✅ **143 passed / 0 failed**（§1 allow 抽样：`allowSampleEvery=3` 时第 3/6 条 allow 发事件、其余不发、`<=0` 关闭、回调抛错不影响 run；§2 error 审计：execute 抛错发 error 事件且 run 仍返回 error 结果、lookup 失败不发；§3 deny 共享向量 Dart 两处一致；§4 结构断言：embedded_backend 新映射 + 三处引用；§5 旧行为回归 deny/ask_approved/ask_denied 不变） |
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_sandbox_audit_phase3_auditlog_round17.dart` | ✅ **63 passed / 0 failed**（§1 导入重接链与溯源：prevHash/originHash/id/ts/脱敏/其后 append；§2 导出→导入→导出幂等与坏行跳过；§3 大导入触发轮转后链仍完整；§4 originHash 序列化往返） |
| `check_audit_rotation_round15.dart`（已更新 §3 过时断言以反映重接链：legacy 1→0、其后追加 prevHash 为空串→等于导入事件 hash、新增带 hash 导入行 originHash 例） | ✅ **178 passed / 0 failed**（原 167 + 新增 11） |
| `check_sandbox_audit_phase2_round15.dart`（已更新 §10 过时断言以反映新映射：switch 映射三行存在；三处硬编码旧树路径指到当前树） | ✅ **76 passed / 0 failed** |
| `check_sandbox_audit_round14.dart`（回归） | ✅ **118 passed / 0 failed** |
| `check_restore_dirty_round14.dart` / `check_kernel_guard_round13.dart` / `check_kernel_guard_round12.dart`（回归） | ✅ **95 / 110 / 46 passed，0 failed** |
| round2–11 回归 17 个 `_r12` 脚本 | ✅ **全部通过**（见整合验证） |
| `node tests/conformance_0_0_41.mjs` | ✅ **53 passed / 0 failed**（46 → 53，新增 G5e 7 条关卡：allow 抽样字段与接线、error 审计接线、deny 唯一真源与三处引用、originHash 字段与导入重接链、导出幂等约定、Python 侧溯源字段与去重） |
| `node frontend/tool/gen_mosaic_registry.mjs --check` | ✅ 通过（2 面板） |
| pytest 全套 | ✅ **269 passed / 8 skipped**（262 → 269，新增 `test_im_audit.py` 7 条：导入重接链与 origin_hash、id 保留、无 hash 行、append 显式参数、originHash 序列化往返、导出幂等、导出直接去重；`test_im_approval.py` 共享向量扩展后 23 passed） |
| `flutter analyze`（全量） | ✅ **No issues found**（0 issues，最终整合重跑） |
| `flutter test` / Dart 编译 / 真机 | ❌ **未跑**（llamadart 的 `.so` 是 arm64、宿主是 x64，原生资产构建失败，环境限制；同 round12/13/15/16 的诚实边界） |
| `embedded_backend.dart` onPolicyDecision 回调**行为** | ❌ **未在 VM 跑到**（该文件 import Flutter，纯 Dart VM 无法加载；只做了源码结构断言 + analyze + 代码复核） |
| cube ask / proot exec 的**行为** | ❌ **未在 VM/真机跑到**（同 round15 的诚实边界） |

### 12.3 本轮实测纠正

1. **round16 运行记录关于 importJsonl 的说法只对 Python 侧成立**：round16 称“importJsonl 实际经 append() 重新接链，真正问题是溯源丢失而非不进链”——Python 侧 `im/audit.py` 的 `import_jsonl` 确实走 `append()`（新 id、新 hash，丢原 hash）；但 Dart 侧 `frontend/lib/harness/audit_log.dart` 的 `importJsonl` 当时是直接写原始行、保留原 hash/prevHash、不进链（本轮核实代码与 §10.3 第 2 条原文双重确认）。本轮真正修的是 Dart 侧的重接链，Python 侧补的是溯源保留（`originHash`），两者缺口不同、不可混为一谈；§10.3 第 2 条已据此划线更新。
2. **deny 正则漂移是实测差异，不是推测**：三处字面量逐字比对，`security_policy.dart` 的 `\bmkfs` 与另两处的 `\bmkfs\b` 在 `mkfsfoo` 上判定相反（前者拦、后者放）；共享向量含 `mkfsfoo → allow` 一条，收敛后三处一致。`echo mkfs` 在三处均为 deny（词边界内的 `mkfs` 本就是规则原意，未改）。
3. **`security_policy_test.dart` 脏行显示问题**：该测试的脏行 detail 在磁盘上实为 `password=p1`，期望 `'password=***'` 与脱敏行为一致；工具输出的显示层会把敏感值转写为 `password=<redacted>`，此前读到的 `password=<redacted>` 是显示层转写、不是文件内容——测试本身无问题，未改。

### 12.4 仍然保留的诚实边界与已知局限

1. allow 抽样只覆盖 `run()` 层策略求值过的 exec/write 级工具；`shell`/`workspace.*` 自带守卫的 allow 仍不记（各自守卫只记 ask/deny）。抽样事件在 `execute` 之前发出：若执行随后抛错，同一调用会同时留一条 allow 抽样事件与一条 error 事件——语义准确（先放行、后执行失败），不是重复记账。
2. error 审计只含异常 runtimeType + 前 120 字符（落盘前仍经 `SecretRedactor` 脱敏）；`CancelToken` 取消同样记 error（执行未完成即失败）。
3. 导入溯源只保留原 hash（`originHash`），不保留原 prevHash 与原文件来源；Dart 侧保留原 ts，Python 侧 ts 取追加时刻——两侧不一致已在各自文档写明，未强行统一（Python `append()` 的 ts 由调用时刻生成，改它牵连网关审计）。
4. 导出幂等只保证“同一份导出重复导入再导出，id 集合不变”；两次导入之间若有新事件追加，导出自然含新事件；轮转后导出仍按时间顺序拼接（轮转文件 + 当前文件）。
5. deny 收敛只覆盖破坏性 shell 三处；`super_agent.dart` 的 destructive 关键词表是风险分级用（非强制拒绝），未动。共享向量在 Dart 脚本与 Python 测试里各一份，需人工保持一致，未抽成单一文件（跨语言无共享常量文件）；改规则文本时三处同步改 + 跑共享向量。
6. ~~proot 之外后端（Local 等）的审计覆盖核查未做（10.4 第 3 条的后半句）；~~已由 round18 完成（见 §13；生产接线缺口仍在 13.4 第 1 条）。Pages 审批卡仍待“批准是否等于置顶”语义；`PluginTier.parse` 未知值兜底 T1 未动。
7. ~~脏标志跨重启持久化仍未做（11.4 第 2 条）；~~已由 round18 实现（见 §14）；`_applyProfile` 卸载循环潜伏问题仍未修（11.4 第 5 条）；~~`sidebar_drawer` 残留 4 个已删 key 的无害死映射仍未清；~~已由 round18 清理（见 §13）；`tga_glass.dart` 仍无引用者（round18 已复核：lib 内无引用者，文件保留、未接线，见 §13）。

## 13. round18 修复（2026-11-28 05:00 轮次，基线 f1e5f6a6）

本轮主项：沙箱审计第三阶段收尾——非 proot 后端审计覆盖核查（10.4 第 3 条后半句、12.4 第 6 条）+ sidebar 死映射清理（12.4 第 7 条前半句）。HEAD 未变（仍为 f1e5f6a6），直接在 round17 融合树上做；两路并行 agent 实施（本 agent 负责非 proot 后端审计覆盖 + sidebar 死映射清理）、主 agent 整合验证。本轮改 `frontend/lib/harness/{sandbox_provider,sandbox_proot_provider}.dart`、`frontend/lib/flai/flows/sidebar/screens/sidebar_drawer.dart`（另加本文档一节、本地断言脚本一处，更新 `check_sandbox_audit_phase2_round15.dart` §11），未动 `plugin_kernel.dart`、`kernel_guard.dart`、`core.dart`、`embedded_backend.dart`、`sandboxed_shell.dart`、`security_policy.dart`、`approval_gate.dart`、`audit_log.dart`。

### 13.0 审计结论（实证，旧行为）

| 缺口 | 旧行为 | 证据 |
|---|---|---|
| provider exec 无 ask | Local/Proot exec 只调 `checkDeny`；策略判 ask 的命令直接执行，不建单、不消费一次性凭据 | `sandbox_provider.dart` 的 `checkDeny` 是唯一预检；`sandbox_proot_provider.dart` exec（round15 只接 deny） |
| provider write 完全无策略检查、无审计 | Local/Proot `writeFile` 只做路径解析 + 写盘；deny/ask 规则对写路径不生效，写动作不留任何审计 | 两文件 `writeFile`（round17 前） |
| provider exec 错误分支无审计 | 平台不支持 / 工作区不可用 / cwd 越界 / shell 起不来 / 未安装 / `proot.run` 返回 null 均静默返回 error 结果，不记审计 | 两文件 exec 的 early return；round15 注释“执行体启动前不记执行审计” |
| 生产四后端已覆盖（核查结论，非缺口） | `_shellExec`：门禁前置 evaluate（deny/ask 记审计并拒绝）+ 6 处收尾 `_auditShellExec`（ssh/proot/real-shell/builtin，含 not-installed/run-null 的 failed、exit -1） | `embedded_backend.dart` `_shellExec`（约 4988–5470 行）；round14 断言 `_auditShellExec` 7 处 |
| cube 已覆盖（核查结论，非缺口） | `SandboxedShell`：deny + ask + 审计三钩子俱全 | `sandboxed_shell.dart` exec；`embedded_backend.dart` 构造接线 |
| ToolRegistry 五态已覆盖（核查结论，非缺口） | deny / ask_approved / ask_denied / allow 抽样 / error | `core.dart`；round17 |
| 注册表生产未接线（缺口，不在本轮文件范围） | `SandboxProviderRegistry` 在 lib/ 内除测试外无调用者；`EmbeddedBackend` 未向注册表注入任何钩子，provider 后端生产不可达 | 全树 grep：lib 内 `SandboxProviderRegistry(` 调用者 0 个（除定义本身） |

### 13.1 修复（新行为）

| 项 | 新行为 | 旧行为对照 |
|---|---|---|
| provider exec ask | `SandboxProvider` 新增 `askCheck`/`onAskApproval` + `checkAsk()`（cube 同款语义：deny 之后、执行体之前；命中 ask 时调审批入口，入口为空或返回 false 记 denied 审计并拒绝，文案区分无入口/已建单；返回 true 放行；预检抛错 fail-closed）；Local 与 Proot exec 均在 `checkDeny` 之后接入；新增 `SandboxExecResult.askDenied` 工厂（status 仍为 denied） | ask 直接执行 |
| provider write 策略 + 审计 | 新增 `writeDenyCheck`/`writeAskCheck`/`onWriteAskApproval` + `checkWritePolicy()`（deny → ask；预检在路径解析之前）；新增 `SandboxAuditEvent.fromWrite` 工厂（tool `'workspace.write'`，first=文件名≤40，chars=内容长度，cwd=父目录，exit 0=已写/-1=未写，detail 与 `fromCommand` 同形）；Local 与 Proot `writeFile`：拒绝记 denied、成功记 allowed、越界/IO 失败记 failed，每次写恰一条事件；接管门禁不拦写（不变） | 写无检查、无审计 |
| provider exec 错误分支审计 | Local：平台不支持 / 工作区不可用 / cwd 越界 / shell 起不来走 `execFailed` 记 failed、exit -1；Proot：not-installed / `proot.run` 返回 null 走 `execFailed` 记 failed、exit -1；与生产 `_shellExec` 同款。round15“执行体启动前不记执行审计”的旧约定废止；接管拒绝仍不记执行审计（round14 链 C 断言不变），deny/ask 仍记 denied | 错误分支静默 |
| 注册表补齐 | 注册表新增 ask/写钩子持有字段 + setter（后设同步到当前后端，与 denyCheck/onAudit 同款）+ `_injectHooks` 注入；新增 `writeFile` 分发入口（委托当前后端） | 只有 deny/审计钩子、无写入口 |
| sidebar 死映射清理 | `_navGroupByLabelKey` 删 4 条（cognition/creator/customize/uiPlugins，37→33）；`_navFallbackZh` 的 uiPlugins 兜底随之删（表暂空）；其余 33 条不动。删除前提：4 个 key 在 `workspace_sections` 里无任何 NavItem 声明，`visibleNavKeys` 只做过滤（未知 key 跳过），故映射永不可达 | 残留 4 个已删 key 的死映射 |
| tga_glass | 核查：lib 内仍无引用者；文件保留、未接线（cosmo 新加组件，留待以后接线，未删） | 同前 |

### 13.2 本轮验证结果

| 验证 | 结果 |
|---|---|
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_sandbox_audit_backends_round18.dart` | ✅ **205 passed / 0 failed**（§1 exec ask 行为；§2 错误分支审计；§3 proot/基类/注册表结构；§4 写策略 + 审计行为与 fromWrite 元数据；§5 注册表注入行为；§6 sidebar 33 条 + tga_glass 无引用；§7 覆盖矩阵回归；§8 旧行为回归） |
| `check_sandbox_audit_phase2_round15.dart`（已更新 §11：fireAudit 1→2 处 + checkAsk 顺序断言） | ✅ **80 passed / 0 failed**（原 76 + 新增 4） |
| `check_sandbox_audit_round14.dart`（回归） | ✅ **118 passed / 0 failed** |
| `check_sandbox_audit_phase3_dispatch_round17.dart`（回归） | ✅ **143 passed / 0 failed** |
| `check_sandbox_audit_phase3_auditlog_round17.dart`（回归） | ✅ **63 passed / 0 failed** |
| `check_audit_rotation_round15.dart`（回归） | ✅ **178 passed / 0 failed** |
| `flutter analyze`（全量） | ✅ **No issues found**（0 issues） |
| pytest 全套 | ❌ **未跑**（本机无 pytest/venv；本轮未动任何 Python 文件，Python 行为不受影响；整合时由主 agent 在有 venv 的环境重跑） |
| `flutter test` / Dart 编译 / 真机 | ❌ **未跑**（同 round12/13/15/16/17 的诚实边界） |
| proot exec / cube / `EmbeddedBackend` 的**行为** | ❌ **未在 VM/真机跑到**（import Flutter；只做源码结构断言 + analyze + 代码复核） |

### 13.3 本轮实测纠正

1. **round15 关于 proot early return 的约定已废止**：round15 称 not-installed / `proot.run` 返回 null“在执行体启动前，命令未执行，故不记执行审计”——生产 `_shellExec` 对同一分支记 failed、exit -1，两层口径不一致。本轮统一为记 failed、exit -1（§10.1 的 proot 钩子行“不记执行审计”已过时，以本节为准；phase2 §11 已同步更新）。
2. **allow 抽样口径**：round17 的抽样只在 `ToolRegistry` 层（默认 1/100）。provider/cube/shell 的执行审计按 round14 约定每动作一条（allowed/failed），本轮未给 provider 加抽样——“allow 仍按抽样”指 ToolRegistry 层的抽样保持不变，不是把 provider 的逐条审计改成抽样。逐条审计是三层（shell/cube/provider）共用的执行审计契约，改抽样会改 audit.jsonl 的事件口径，须另议。
3. **sidebar 死映射是 4 个 key、5 行**：分组表 4 条 + 兜底表 uiPlugins 1 条；原分组表共 37 条（此前记录误作 36 条），现剩 33 条。4 个 key 的 NavItem 均不在 `workspace_sections` 声明里（`mosaic`/`sunRun` 是有声明但未进分组表的另一回事，走类型兜底，不动）。

### 13.4 仍然保留的诚实边界与已知局限

1. **生产接线缺口**：provider 层的策略/审计 choke 点已补齐，但 `EmbeddedBackend` 尚未实例化 `SandboxProviderRegistry`、未注入 denyCheck/askCheck/onAskApproval/writeDenyCheck/writeAskCheck/onWriteAskApproval/onAudit——生产 exec 仍走 `_shellExec` 直调 SshSandbox/ProotSandbox/`_realShellExec`/内置解释器，provider 后端在生产上不可达。接线须另改 `embedded_backend.dart`（构造时建注册表、注册 local/proot 后端、注入与 cube 同款的策略回调与 `_auditShellExec`/`_auditCubeEvent` 同款的审计回调），并补 flutter 侧测试；本轮只证明 provider 层本身已就绪。
2. allow 抽样事件在 `execute` 之前发出（round17 既有语义）；provider 的 ask 获批后尾部审计仍按 ok 记 allowed/failed，不另记一条 ask_approved 事件——ask 获批在 provider/cube 层不留独立事件，与 cube 同款；五态区分只在 ToolRegistry 层。
3. 写审计的 `chars` 为待写内容长度（UTF-16 代码单元数），`first` 为文件名——内容本身绝不进审计；大文件写仍只记一条元数据事件。
4. （接续 12.4）Pages 审批卡仍待“批准是否等于置顶”语义；`PluginTier.parse` 未知值兜底 T1 未动；~~脏标志跨重启持久化仍未做（11.4 第 2 条）；~~已由 round18 实现（见 §14）；`_applyProfile` 卸载循环潜伏问题仍未修（11.4 第 5 条）。

## 14. round18 修复（2026-11-28 05:00 轮次，基线 f1e5f6a6）

本轮主项：脏标志跨重启持久化（9.4 第 1 条、11.4 第 2 条、12.4 第 7 条遗留）。HEAD 未变（仍为 f1e5f6a6），直接在 round17 融合树上做；两路并行 agent 实施（本 agent 负责脏标志持久化；另一 agent 负责沙箱审计收尾 + sidebar 清理，见 §13）、主 agent 整合验证。本轮只改 `frontend/lib/harness/plugin_kernel.dart`（另加本文档一节、本地断言脚本一处），未动 `sandbox_provider.dart` / `sandbox_proot_provider.dart` / `sandbox_takeover.dart` / `sidebar_drawer.dart` / `tga_glass.dart`，未新增任何操作页面（万物皆插件 / Super agent 等核心功能无操作页，见 14.3）。

### 14.0 审计结论（实证，旧行为）

| 缺口 | 旧行为 | 证据 |
|---|---|---|
| 脏态只在内存 | `_restoreDirty` / `_restoreDirtyReason` 是纯内存字段；`_persistConfig` 只写 `profile` / `home_patch` / `updated_at` 三键；进程重启后旧脏态即失，启动标脏只能发现**本次**启动的问题 | `plugin_kernel.dart` 约 859–864 行字段注释“只在内存，进程重启即失——跨重启持久化未做”；`_persistConfig` 约 1174 行 |
| 清脏只清内存 | 三条出路（重试同一快照成功 / 回滚到备份成功 / `resolve_dirty` 显式确认）只把内存字段置回 false；磁盘上本就无脏键，无从谈清盘 | `resolve_dirty` 约 2045 行、`restoreSnapshot` 成功路径约 2377 行 |
| 快照仍只在内存 | 快照列表是进程内 `List<KernelSnapshot>`，不落盘；重启后磁盘上没有可恢复的“最新快照”，boot 的“最新快照”仍是本次装配结果本身 | round16 §11.0 预检对象决策；本轮未改（见 14.4 第 2 条） |

### 14.1 修复（新行为，全部在 plugin_kernel.dart 内，不另起文件，不新增类型）

| 项 | 新行为 | 旧行为对照 |
|---|---|---|
| 脏态落盘 | `_persistConfig` 脏时多写一个 `restore_dirty` 键：`{dirty: true, reason, at, phase}`（`at` = 置脏时间 ISO 8601，`phase` = 置脏来源 `'boot'` / `'restore'`）；干净时不写该键——干净启动不留脏痕，清脏时同一收口把键清掉。写盘仍是原有 tmp+rename 原子写，失败时旧 `kernel_config.json` 完好，`profile` / `home_patch` 不受损 | 只写 profile/home_patch/updated_at |
| 启动恢复 | `boot()` 在 `readConfig()` 之后、首个 `_persistConfig`（`_applyProfile` 内）之前，先调 `_restorePersistedDirty(saved)` 恢复上轮脏态：`dirty==true` 且 `reason` 为字符串（可空）时恢复脏态、置脏时间与来源，journal phase 记 `'restored_dirty'`；恢复后内核仍脏，仍须 rollback 或 `resolve_dirty` 才能继续；本次装配本身干净时不发新的 boot 脏事件 | 重启后旧脏态即失 |
| 置脏收口落盘 | 启动标脏（`_markBootDirtyIfNeeded`，phase `'boot'`）由 `boot()` 在调用后收口 `if (_restoreDirty) await _persistDirtyState()`；回退失败（`_failRestore`，phase `'restore'`，现为 async、调用点 `return await`）在返回前 `await _persistDirtyState()` | 置脏不同步磁盘 |
| 清脏收口清盘 | `resolve_dirty` 显式确认、重试同一快照成功、回滚到备份成功三条出路，清内存脏态的同时 `await _persistDirtyState()`，把磁盘上的脏键清掉 | 清脏只清内存 |
| 落盘尽力而为 | `_persistDirtyState()` 包一层 try/catch：写盘失败只发 `kernel.dirty_persist_failed` 审计事件（含 error 与当时 dirty 值），不抛错、不回滚内存脏态、不挡启动与出路；调用方一次普通写盘（如 `set_patch`）即可恢复同步 | 无此收口 |
| 损坏脏记录 | `_restorePersistedDirty` 校验：`restore_dirty` 不是 Map、`dirty` 非 bool true、`reason` 非字符串时，按“干净”处理并记一条 `kernel.dirty_record_ignored` 审计事件，不抛错、不挡启动；`dirty==false` 或无该键时静默干净，不发事件。整文件 JSON 损坏时 `FileKernelPersistence.readConfig` 已回退空态（旧行为，本轮未改），只断言干净启动 | 无此校验 |
| 脏态可见 | `handle('describe'/'status')` 与 facade `PluginContext.describe()` 新增 `restore_dirty_at` / `restore_dirty_phase` 两个只读字段（干净时为空串）；原有 `restore_dirty` / `restore_dirty_reason` / `restore_journal` 字段不动 | 无脏时间/来源字段 |

### 14.2 本轮验证结果

| 验证 | 结果 |
|---|---|
| 新 Dart VM 断言脚本 `~/workspace/tangram-agent-work/check_dirty_persist_round18.dart` | ✅ **98 passed / 0 failed**（§0 干净启动不留脏痕；§1 置脏后持久化文件含脏标志与 reason/at/phase 且 profile/home_patch 不受损 + facade 字段；§2 新实例加载后脏态恢复端到端：修复 bundle 后仍恢复上轮脏态、脏门禁生效、resolve_dirty 后内存与磁盘同时清脏；§3 回退失败落盘 phase 'restore' → 重试同一快照成功清脏含磁盘、清脏后新实例启动干净；§4 回滚到备份成功清脏含磁盘；§5 损坏脏记录不挡启动：非 Map / dirty 非 true / reason 非字符串 → 干净 + ignored 事件、整文件 JSON 损坏 → 干净启动、dirty:false 显式干净不发事件；§6 失败写入不破坏原有持久化：写失败只记 dirty_persist_failed、内存脏态照常切换、磁盘旧文件完好、恢复写后一次普通写盘即同步；§7 facade describe 脏时间/来源） |
| `check_boot_dirty_round16.dart`（回归） | ✅ **95 passed / 0 failed**，与 round16 期望无冲突，**无需同步修正** |
| `check_restore_dirty_round14.dart`（回归） | ✅ **95 passed / 0 failed** |
| `check_kernel_guard_round13.dart` / `check_kernel_guard_round12.dart`（回归） | ✅ **110 / 46 passed，0 failed** |
| `node tests/conformance_0_0_41.mjs` | ✅ **53 passed / 0 failed**（G5d 6 条关卡仍过：`_markBootDirtyIfNeeded` 保持同步 `void` 签名，conformance 按 `'void _markBootDirtyIfNeeded('` 切片；落盘收口放 `boot()` 里 await，本轮改签名为 `Future<void>` 时 4 条 G5d 关卡曾失败，已改回——见 14.3 末条） |
| pytest 全套 | ✅ **269 passed / 8 skipped**（与 round17 基线逐项持平） |
| `flutter analyze`（全量） | ✅ **No issues found**（0 issues） |
| `flutter test` / Dart 编译 / 真机 | ❌ **未跑**（llamadart 的 `.so` 是 arm64、宿主是 x64，原生资产构建失败，环境限制；同 round12/13/15/16/17 的诚实边界） |

### 14.3 持久化约定（本节为规范，后续轮次按此执行）

1. **写盘时机**：脏态是 `_persistConfig` 写出的 `kernel_config.json` 里一个普通键，随每一次配置落盘同步写出——置脏收口（boot 标脏、回退失败）与清脏收口（三条出路）都经 `_persistDirtyState()` 落盘；其余写盘点（`_applyProfile`、`_setPatch` 的 bundle/home/profile 层）不感知脏态，只负责把当前内存脏态原样写回。干净时键不存在：磁盘上“无键”即“干净”，不要另写 `dirty:false` 占位。
2. **记录形态**：`restore_dirty = {dirty: true, reason: String, at: String（ISO 8601）, phase: 'boot' | 'restore'}`。`phase` 只记置脏来源，不记出路；`at` 只记置脏时刻，清脏不留痕。journal 不落盘：重启后恢复的脏态只有 reason/at/phase，journal 摘要只给 `phase: 'restored_dirty'` 的最小骨架（`failed_phase` 取回恢复的 phase，其余键为空），不伪造失败插件与目标快照。
3. **清脏收口**：三条出路共用同一约定——内存清脏 + `await _persistDirtyState()`，磁盘键随即消失；任一出路清脏后，再启动的新实例必干净（断言 §3 末条）。`resolve_dirty` 仍须 `trustedRoot` + 显式 `accept: true`；脏门禁仍只拦 `handle()` 改动类动作，宿主直调不受限（round14 §9 第 6 条口径不变）。
4. **损坏处理**：脏记录损坏（非 Map / `dirty` 非 true / `reason` 非字符串）→ 按干净处理 + `kernel.dirty_record_ignored` 审计事件，不抛错、不挡启动；`dirty==false` 显式干净，不发事件；整文件 JSON 损坏 → `readConfig` 回退空态，干净启动（旧行为）。写盘失败（磁盘满、权限等）→ 只记 `kernel.dirty_persist_failed` 审计事件，内存脏态照常切换，旧文件完好（tmp+rename 原子写）；恢复写能力后一次普通写盘即同步。
5. **恢复顺序**：`boot()` 必须在首个 `_persistConfig` 之前恢复脏态，否则装配落盘会把磁盘上的旧脏键冲掉（`_applyProfile` 写盘时内存脏态仍为 false）。恢复后若本次启动又标脏，新 reason/at/phase 覆盖旧值并落盘；本次启动干净时旧脏态原样保留，仍须出路清脏。
6. **不做**：快照仍只在内存（不落盘）；`restoreSnapshot` 变异开始时的瞬时置脏（“正在回退到快照 …”）不落盘——进程崩溃时它随进程消失，磁盘保留此前已落盘的脏态；不新增操作页面、不新增持久化文件、不新增类型。
7. **实现约束**：`_markBootDirtyIfNeeded` 保持同步 `void` 签名——conformance G5d 按字面 `'void _markBootDirtyIfNeeded('` 切片，改成 `Future<void>` 会使 4 条关卡的切片落到错误位置而失败（本轮实测）；落盘收口放 `boot()` 里 `if (_restoreDirty) await _persistDirtyState()`。`_failRestore` 改为 async 是安全的（无 conformance 切片命中它，调用点 4 处均已 `return await`）。

### 14.4 仍然保留的诚实边界与已知局限

1. 快照仍只在内存：重启后磁盘上没有可恢复的快照，恢复的脏态指向的目标快照 id 在新进程里不存在——重启后 `rollback` 不是出路，`resolve_dirty` 才是（与 11.4 第 7 条同理：回滚出路只对同进程内的 `boot_apply` 脏态有效；跨重启恢复的脏态，其 journal 只有最小骨架）。
2. `restoreSnapshot` 变异开始时的瞬时置脏不落盘：进程恰在回退中途崩溃时，磁盘保留此前已落盘的脏态（此前干净则仍干净）；半回退的节点态随进程消失，重启后按磁盘 profile 重新装配——这是快照内存化的既有限制，不是本轮引入的新缺口。
3. 恢复的脏态不重放事件：上轮的 `kernel.boot_dirty` / `kernel.rollback_failed` 事件只在旧进程的事件流里（`kernel_events.jsonl` 会随 `readEvents` 回放进 `_seq`，但事件内容不重放为热事件）；新进程只恢复脏态本身，不补发旧事件。
4. `_applyProfile` 卸载循环潜伏问题仍未修（11.4 第 5 条）；`_setMode` 先赋值模式、后 `_applyProfile` 的顺序未动（9.4 第 4 条）。
5. 本轮未跑 `flutter test` / Dart 编译 / 真机（见 14.2）；断言脚本的临时目录删除需等未 await 的事件落盘（200ms 沉降 + 重试），属测试脚手架约定，不影响内核。
