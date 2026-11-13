# Tangram Agent（TGA）

个人专属 AI Agent 全平台运行时：手机 / 桌面 APP + 本地纯 Dart 后端 + 隔离沙箱，
可接云端 API 模型或本地 GGUF 模型，支持在微信 / QQ / 飞书里对话，
带工作轨迹、蒸馏模型管理、知识图谱、日记与定时任务等能力。

版本：**0.0.1**

> 本仓库为闭源专有软件（All rights reserved）。仓库内全部源码与资源版权归
> 檀阁瑞木 / COSMOn 所有，未经授权不得复制、修改、再分发或用于商业用途。

## 组成

- `frontend/` — Flutter APP（Android / Windows / Linux / macOS / Web），
  内置纯 Dart 后端（`lib/harness/embedded_backend.dart`）、受限 Isolate 沙箱、
  真实模型推理链路与全部业务页面。
- `im/` — IM 网关（微信 iLink / QQ NapCat / 飞书设备授权流三渠道扫码接入、
  消息收发、局域网 UDP 自动发现）。
- `harness/` — 能力契约 / 工具注册表 / 工作轨迹 / 蒸馏与教师接口的 Python 参考实现。
- `skills/` — 内置技能清单。
- `schema/` `shared/` — 协议与共享定义。
- `scripts/` — 构建脚本（`build_frontend.sh` 等）。
- `.github/workflows/` — 全平台云端构建工作流。

## 快速开始（构建 APP）

```bash
# 依赖：Flutter 3.50+（含 Dart 3.10.7+）
cd frontend && flutter pub get
bash ../scripts/build_frontend.sh android        # 出 APK
bash ../scripts/build_frontend.sh linux          # 出 Linux 桌面
bash ../scripts/build_frontend.sh windows        # 出 Windows
bash ../scripts/build_frontend.sh macos          # 出 macOS
```

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
