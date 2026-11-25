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
