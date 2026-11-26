# Rakazo 架构参考融合说明

## 基线
- TGA 基线分支：`main`。
- 已合并 `round14-push` 的插件内核、沙箱、审计、安全策略与内嵌后端修复。
- Rakazo 仓库：`https://github.com/elie222/rakazo`，许可证 Apache-2.0；许可证、NOTICE 与参考源码保留在 `third_party/rakazo/`。

## 融合边界
Rakazo 是 pnpm + TypeScript monorepo，TGA 是 Flutter/Dart + Python 运行时。直接迁移 TypeScript 运行时代码会破坏现有构建，因此本次融合采用**架构契约参考**方式：
1. 借鉴 bot/routine/run/skill/thread/computer/integration 的模块职责划分；
2. 插件与工具注册继续走 TGA 现有 `PluginKernel` / Python `PluginRuntime`；
3. 沙箱能力继续复用现有 Proot/本地 shell provider，不引入未编译验证的 Node 侧 computer provider；
4. 第三方源码仅作为参考与法律归属保留，不参与 Dart/Python 编译。

## 模块对应关系
| Rakazo 概念 | TGA 落地位置 | 说明 |
| --- | --- | --- |
| Bot / persistent agent | `frontend/lib/harness/super_agent*.dart`、`backend/app/runtime/agent_service.py` | 常驻智能体控制域与任务委派 |
| Routine | `frontend/lib/harness/routine_store.dart`、后端例程运行模块 | 定时与可复用任务流程 |
| Skill / Plugin | `frontend/lib/harness/plugin_kernel.dart`、`backend/app/runtime/plugin_runtime.py` | 分级、能力声明、审计与失败关闭 |
| Computer / sandbox | `frontend/lib/harness/sandbox_provider.dart`、`sandboxed_shell.dart` | 本地/隔离 shell、命令边界与审计 |
| Integration / tool source | `frontend/lib/harness/integration_registry.dart`、MCP client | 外部工具与 MCP 接入契约 |
| Thread / memory | memory store 与持久化记忆模块 | 跨会话上下文与召回 |

## 安全与验证
- 不执行 `eval` / `exec` / `pickle`；shell 与 HTTP 工具按 manifest 权限放行；
- 所有插件注册、调用、拒绝、超时进入审计；
- Python 回归测试在本地运行；Dart/Flutter analyze 与 widget 测试需要 Flutter SDK 环境执行，当前沙箱未安装 SDK，不能谎称通过。


## 本轮验证记录
- Python 回归：`python3 -m pytest tests -q` → 146 passed, 5 skipped。
- Python 编译：`python3 -m compileall -q backend im shared skills` 通过。
- 当前沙箱未安装 Flutter/Dart SDK，`flutter analyze` / `flutter test` 无法在本机执行；Dart 改动需在装有 Flutter 3.41+ 的 CI 或开发机上复跑。
- Rakazo TypeScript 源码不参与 TGA 构建；保留其 Apache-2.0 LICENSE、NOTICE、README 与文档作为架构参考。
