# WASM 模块级契约 `wasm/1`（提案 + 类型化拒绝）

> 状态：**未实现运行时**。本文件只定义 ABI，任何平台在运行时缺位时必须
> **类型化拒绝**（`WasmUnavailable`），绝不静默降级为「执行成功」。
> 纪律来源：NewAgentUniverseByDeepSeek（MIT）——「没实现就说没实现」。

## 1. 模块形态

- 一个 `.wasm` 模块只导出三个函数：`alloc`、`free`、`call`。
- 参数与返回值走**线性内存的 JSON 帧**（UTF-8，4 字节小端长度前缀），
  禁止跨语言直接传指针语义。
- 导入：默认**无 WASI、无网络**。需要文件/网络能力必须显式声明 `caps`，
  由宿主代理调用（宿主侧仍走既有权限校验）。

## 2. ABI

| 导出 | 签名 | 说明 |
|---|---|---|
| `alloc` | `(size: i32) -> i32` | 返回可写指针；失败返回 0 |
| `free` | `(ptr: i32) -> void` | 释放 `alloc` 的内存 |
| `call` | `(ptr: i32, len: i32) -> i32` | 入参为 JSON 帧；返回新帧指针（长度前缀） |

帧格式：`[u32 little-endian length][utf-8 json]`。

## 3. 资源上限（超限即拒绝）

| 项 | 默认 | 说明 |
|---|---|---|
| `memoryPages` | 64 | 最大 256 |
| `fuel` | 1_000_000 | 计算燃料，耗尽即中止 |
| `timeoutMs` | 5000 | 最大 60000 |
| `allowWasi` | false | 默认不导入 WASI |
| `allowNetwork` | false | 默认无网络 |

## 4. 能力令牌

模块必须声明 `caps`，取值同插件清单：`fs:read` / `fs:write` / `net:fetch` / `model:call`。
未声明即拒绝加载（与 T3 插件同一套 fail-closed 规则）。

## 5. 本机状态

- Android：无成熟 wasm FFI → `WasmModule` 构造即抛 `WasmUnavailable`。
- 桌面/服务端：接 wasmtime 后按本契约实现；未接之前同样抛 `WasmUnavailable`。
- 跨语言工具级需求，走 MCP（`mcp_client.dart` 已实现 initialize/tools.list/tools.call）。
