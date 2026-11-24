# TGA 架构融合说明（0.0.41）

> 目的：把外部三个参考（NORP-Agent / NewAgentUniverseByDeepSeek / MCP+WASM）的结论，
> **对齐到仓库里已经存在的实现**上，而不是再引入第二套内核。
> 结论先行：本仓库已有可用的插件内核，0.0.41 只做版本号统一，不做架构替换。

## 1. 现状（已存在的实现，勿重复造）

| 能力 | 现有文件 | 规模 |
|---|---|---|
| 插件内核（能力缝 CapabilitySeam / 事件 KernelEvent / 文件与内存持久化） | `frontend/lib/harness/plugin_kernel.dart` | 1445 行 |
| 插件运行时（清单归一化 / 工具调用 / 沙箱） | `backend/app/runtime/plugin_runtime.py` | 877 行 |
| 快照与回退 | `frontend/lib/harness/snapshot_service.dart` | 279 行 |
| 集成注册表（**已含 MCP 客户端** / 密钥库 / OAuth 刷新 / 退避重试） | `frontend/lib/harness/integration_registry.dart` | 1236 行 |
| 内置插件 / 自定义插件 UI / 内核页 / 快照页 | `harness/builtin_plugins.dart`、`ui/pages/tga_{plugins,ui_plugins,kernel,snapshot}_page.dart` | — |
| 插件相关测试 | `frontend/test/plugin_kernel_test.dart`、`plugin_kernel_customization_test.dart`、`tests/test_plugin_runtime.py` | — |

## 2. 三个参考 → 现有代码的映射

| 参考结论 | 本仓库对应 | 差距 |
|---|---|---|
| NORP：一切皆槽位 + 地址函数 + 热挂载 | `CapabilitySeam`（provider/consumer + activeProviderId） | 地址函数（`pkg.mod:attr`）未统一；热挂载需确认是否重建 |
| NAU：内核只做四件事、分级、fail-closed | `PluginRuntime` 清单归一化 | **能力分级 T0–T3 缺**；未声明能力是否默认拒绝需确认 |
| NAU：没实现就类型化拒绝 | — | **WASM 模块级契约缺**（本报告不实现，只登记） |
| MCP：工具级跨语言 | `IntegrationRegistry._mcp` | 已有客户端；工具清单是否与内核 seam 打通需核对 |
| 快照回退（NORP） | `SnapshotService` | 已有；是否有「装插件前自动快照」需确认 |

## 3. 0.0.41 做了什么 / 没做什么

**做了**：五处版本声明点统一到 `0.0.41`（VERSION / pubspec / app_version.dart /
backend/pyproject.toml / backend/app/__init__.py），README 版本行同步。
校验方式：`python -c "from harness.version import assert_version_frozen; print(assert_version_frozen())"`
必须返回 `0.0.41`，否则 CI 直接失败。

**没做**：不改内核、不改插件协议、不改 UI。理由见 §1：现有实现已覆盖，替换只会制造两套真相。

## 4. 下一步（P1 融合，按缺口逐个补，每项独立可验证）

1. 能力分级：在 `PluginRuntime._normalize_manifest` 增加 `tier` 字段，默认 `T2`；
   T0 仅内核自带；T3 默认禁网禁写。验收：`tests/test_plugin_runtime.py` 新增用例。
2. 未声明能力默认拒绝：核对 `CapabilitySeam` 的 consumer 校验，缺声明即抛错而非放行。
3. 地址函数统一：seam provider 的 id 采用 `pkg.mod:attr`，与 Python 侧清单对齐。
4. 装插件前自动快照：`SnapshotService` 增加 mount 前置钩子。
5. WASM 模块级契约：**先不实现**，仅在 `third_party/` 与本文件登记 ABI 提案
   （`wasm/1`：alloc/free/call + 内存/燃料/超时上限）；运行时缺位时按类型化拒绝返回，
   不静默降级为「执行成功」。

## 5. 许可与归属

本仓库为 AGPL-3.0（见根 `LICENSE`）。参考项目 NORP-Agent 与 NewAgentUniverseByDeepSeek
均为 MIT，本轮**只借鉴设计结论，未复制其代码**，因此不产生额外署名义务。

---

## 6. 已落地（0.0.41 第二笔推送，2026-11-24）

按 §4 的缺口，先落**不破坏既有行为**的三项（opt-in，默认值保持原语义）：

| 缺口 | 实现 | 兼容策略 |
|---|---|---|
| 能力分级缺 | 新增 `frontend/lib/harness/plugin_tier.dart`：`PluginTier{T0..T3}` + `wire` + `parse()`；Python 侧 `_normalize_manifest` 接受 `tier` 并写入清单 | 未声明 tier → **T1 official**（与内置插件原行为一致）；未知值兜底 T1，不静默升 T0 |
| 未声明能力放行 | `Plugin.caps`（默认空＝不限制）；`PluginContext.consumeSeam()` 在 caps 非空时校验，缺声明抛 `CapabilityDenied` | 既有插件 caps 为空 → 判定通过，行为不变 |
| T3 第三方未声明即放行 | Python 侧 fail-closed：`tier=T3` 且 `caps` 为空 → `invalid_manifest` 拒绝加载 | 仓库当前无 T3 插件，不影响现有清单 |
| 地址函数缺 | `parsePluginAddress()`（`scheme:path`，非法即抛 `FormatException`）+ `Plugin.address` 可选声明 | 默认 null＝沿用 id，不强制改现有 provider id |
| 装插件前无快照 | `PluginKernel.onBeforeMount` 钩子（默认 null）；钩子抛异常即拒绝挂载 | 默认不挂钩子 → 行为不变；快照服务可按需接入 |

新增测试（未在本机执行，需 CI 或电脑跑）：
- `frontend/test/plugin_tier_test.dart`（分级解析 / caps 判定 / 地址解析 / 异常消息）
- `tests/test_plugin_tier.py`（默认 T1、别名、未知兜底、caps 去重排序、T3 fail-closed、caps 类型校验）

未做（原因如实写）：`onBeforeMount` 与 `SnapshotService` 的接线需运行时验证；
UI 侧的「约定接口加载」（mosaic 式静态注册）当前由 `tga_ui_plugins_page.dart`
的 `widget_slots/pages` 白名单宿主承担，改成编译期约定加载会动到路由，留待下一轮。
