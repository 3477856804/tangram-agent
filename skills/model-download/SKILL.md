---
name: model-download
description: 用内置 edwl 多线程分片下载器从魔搭 ModelScope 拉模型文件，支持 Range 分片、断点续传、镜像切换与整体 SHA-256 校验；edwl 不可用时自动回退单流 urllib。
params: model_id,url,dest,sha256,threads
---
# 模型下载（edwl 多线程分片）

## 什么时候用它

用户要“下载模型 / 拉权重 / 取 GGUF / 换本地模型”时走本技能。两条真实路径：

- **整模型**：模型商店的 `model_store` 控制域，`action=download` + `model_id`
- **单文件**：直接调 edwl（多线程分片，比单流快，断了能续）

## 参数

- `model_id` — 魔搭的 `owner/name`，如 `Qwen/Qwen2.5-0.5B-Instruct-GGUF`
- `url` — 单文件下载时才需要；与 `model_id` 二选一
- `dest` — 目标路径或目录（以 `/` 结尾视为目录）
- `sha256` — 可选的整文件校验值；ModelScope 的文件清单里自带 `Sha256`，直接传
- `threads` — 分片并发数，默认 8（环境变量 `TANGRAM_EDWL_THREADS` 可改，1..64）

## 步骤

## 1. 确认引擎

`python -m app.models.edwl` 打印二进制路径与版本；返回非 0 说明没编译，先跑
`scripts/build_edwl.sh`（或 `make build-edwl`）。没有 edwl 也能下，只是退回单流。

## 2. 整模型：交给模型商店

- 发起：`model_store` → `{"action": "download", "model_id": "<owner/name>"}`
- 返回里看 `engine` 字段：`edwl` 表示走多线程分片，`urllib` 表示回退
- 进度：`model_store` → `{"action": "download_status", "job_id": "<job_id>"}`
  `downloaded` / `total` 是真实字节数；`warnings` 里若有回退原因会写清楚

## 3. 单文件：直接调 edwl

```
edwl -q --no-progress --no-config -j 8 -T 30 \
     --sha256 <64位十六进制> -O <目标文件> <URL> [镜像URL ...]
```

- `--no-config` 必须在：否则会读当前目录的 `edwl.ini`，行为被环境悄悄改掉
- 断点续传默认开启，续传依据输出文件旁的 `<文件名>.edwl` 边车文件
- 服务器不认 Range 时自动退化为单连接，不必手动降级

## 4. 判定结果，别猜

退出码就是结论：`0` 成功、`1` 出错、`2` 用法错误、`3` SHA-256 不匹配、`130` 被中断。
非 0 时不要报告“已下载完成”；把真实退出码和最后一行输出给用户。

## 边界

- edwl 只做 http/https 匿名下载：不带 cookie、不做认证，也别指望 FTP
- 下载目录默认 `TANGRAM_MODELS_ROOT`（缺省 `models/`），不写系统路径
- 二进制不入库：`backend/app/models/bin/` 与 `third_party/edwl/build/` 都被 gitignore
