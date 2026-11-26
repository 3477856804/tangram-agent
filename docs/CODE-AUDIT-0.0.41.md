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

1. 脏标志**只在内存**：进程重启即失。任务要求的缓解（启动时跑 `verifyDependencies` 比对最新快照标脏）**本轮未实现**——要在 `boot` 里对最新快照做预检并标脏，需先定「启动即脏是否阻塞首轮挂载」等语义，超出本轮范围，写明为已知局限，不硬塞。
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
2. `importJsonl` 导入的事件仍不进哈希链（旧行为未变）：导入后下一 append 重新从磁盘读尾，链尾接在最后一条导入事件上，导入事件自身的 prevHash 不与链衔接，`verifyChain` 会在导入事件处按 legacy/断裂口径报告——与 round14 之前一致，未在本轮扩大范围。
3. dispatch 审计只覆盖 `run()` 层的策略决定：`run()` 捕获的工具执行异常仍只以 error 结果回给调用方，不另记审计（轨迹层记录结果）；`shell`/`workspace.*` 的 allow 决定不记（各自守卫只记 ask/deny，见 `_workspaceGuard` 与 `_shellExec`）。
4. cube ask 的 fail-closed 与 `onAskApproval` 抛错按 false 计，均经代码走读，未经真实表达式触发。
5. 脏标志启动标脏缓解（9.4 遗留）与 Pages 审批卡（语义待定夺）仍未做，见 10.4。
6. `SandboxAuditEvent` 两份同形实现已合并，但三份 deny 正则的漂移点仍在（见 8.2 遗留）。
7. `exportJsonl()` 改为全量拼接是行为变化：调用方原先只拿到当前文件，现拿到全部轮转文件 + 当前文件；备份/导出场景更完整，增量同步场景需注意去重。

### 10.4 下一轮可做的

1. 脏标志启动标脏缓解（9.4 遗留第 ⑤ 项；需先定“启动即脏是否阻塞首轮挂载”语义）。
2. Pages 审批卡 + `unapprove()`（需先定“批准是否等于置顶”语义）。
3. 沙箱审计第三阶段：dispatch 路径 ask 的 allow 决定抽样审计、proot 之外后端的审计覆盖核查、审计导出去重约定。
4. `PluginTier.parse` 未知值兜底 T1 的收紧（见 8.2 遗留）。
