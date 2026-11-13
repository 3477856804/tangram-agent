"""Tangram 个人 IM 网关可运行服务（沙箱外独立进程）。

职责：
- HTTP 面板（仅回环）：网关状态、已注册 Adapter、扫码接入入口。
- QQ NapCat（OneBot v11）：
    GET  /api/login/qq/qr      向本地 NapCat 拉取真实登录二维码（get_login_qrcode），
                                渲染为 PNG 供用户扫码；会话可轮询状态。
    GET  /api/login/qq/status  轮询扫码/在线状态（get_login_info）。
    POST /webhook/qq_napcat    接收 OneBot message 事件 -> Gateway.handle_inbound
                                -> 本地 Agent 运行时（RuntimeService）-> 出站回复。
- 微信官方（iLink ClawBot webhook）：
    POST /webhook/wechat_official  HMAC 验签后入站 -> Agent -> 出站。
- 出站统一经 Gateway 风控守卫（pre_send）后由对应 Adapter 下发。
- TGA 手机 APP 扫码接入（`im/agp_bridge.py`）：
    GET  /api/login/wechat/qr    腾讯 iLink 真二维码 PNG（APP 直接显示，不伪造）
    GET  /api/login/qq/qr        NapCat 真二维码 PNG
    GET  /api/login/feishu/qr    飞书官方设备授权流：扫码一键建应用（需 lark-oapi）
    POST /api/login/feishu/cancel 取消飞书登录并清除本地凭据
    GET  /api/discover          局域网发现 HTTP 兜底
    UDP  50433                  局域网自动发现（APP 免填网关地址）
    GET  /api/login/*/status    登录成功时附带 ws_url / guid / token
    GET  /ws                    AGP WebSocket（Upgrade）：入站消息转
                                session.prompt 交给手机端小模型推理，
                                回复经 session.promptResponse 原路发回 IM。

约束：仅标准库（二维码渲染可用 segno，缺失时降级返回原始 URL）。
真实接入前提：本机已启动 NapCat（默认 http://127.0.0.1:3000）并放行 HTTP 反向 API；
微信渠道需用户在服务端配置 app_secret。未配置时接口返回可读错误，不伪造在线。

用法：
    python3 -m im.serve --port 50432 [--onebot http://127.0.0.1:3000]
    环境变量：TANGRAM_MODEL（本地 GGUF 模型路径）、TANGRAM_DATA、NAPCAT_TOKEN、
    TANGRAM_API_BASE / TANGRAM_API_KEY / TANGRAM_API_MODEL（三者齐备时 IM 应答
    优先走该 OpenAI 兼容云端 API，调用失败自动回落本地运行时）
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from im.gateway import Gateway, MultimodalMessage  # noqa: E402
from im import brain  # noqa: E402
from im.agp_bridge import (  # noqa: E402
    AGP_HUB,
    issue_credentials,
    verify_token,
    ws_accept,
    ws_frame,
    ws_read_frame,
    ws_text_frame,
)

# 微信 context_token 登记表：主动推送（提醒）需要最近会话的 context_token
wx_ctx: dict[str, str] = {}


def _wx_ctx_path() -> str:
    import os as _os
    d = _os.environ.get("TANGRAM_DATA", _os.path.expanduser("~/.tangram"))
    Path(d).mkdir(parents=True, exist_ok=True)
    return str(Path(d) / "wx_ctx.json")


def _wx_ctx_persist() -> None:
    try:
        Path(_wx_ctx_path()).write_text(json.dumps(wx_ctx, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def _wx_ctx_restore() -> None:
    try:
        p = Path(_wx_ctx_path())
        if p.is_file():
            wx_ctx.update(json.loads(p.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        pass


def _media_answer(items, kind: str, key: str) -> str:
    q = "请用简体中文描述这张图片的内容与关键信息。" if kind == "image" else "视频里发生了什么？用简体中文简述。"
    return brain.describe_media(items, q)


def _agent_reply(text: str, key: str) -> str:
    """统一应答：brain 确定性能力优先，回落本地 LLM（带记忆）。"""
    def _llm(t: str) -> str:
        ans = AGENT.answer(t, key)
        brain.remember_code(ans)
        return ans
    ans = brain_default.handle(text, key) if brain_default is not None else None
    if ans is None:
        ans = _llm(text)
    return ans or "（空回复）"


brain_default = brain.Brain()  # deliver/llm 在 build_gateway 里接线


def _bridge_reply(text: str, key: str, target: str, connector: str) -> Optional[str]:
    """手机 APP 在线时优先用端侧小模型推理；不可用返回 None 回落本地 Agent。

    绝不编造回复：APP 超时 / 异常 / 未连接一律返回 None，由调用方走
    `_agent_reply`（检索式能力或本地 LLM），行为与原网关一致。
    """
    if not text or not AGP_HUB.has_client(connector):
        return None
    try:
        reply = AGP_HUB.prompt(
            text,
            connector,
            target,
            timeout=float(os.environ.get("TANGRAM_AGP_TIMEOUT", "180")),
        )
    except Exception as exc:
        print(f"[agp] 手机端推理异常，回落本地 Agent：{exc}", flush=True)
        return None
    if reply:
        print(f"[agp] 由手机端模型回复（{len(reply)} 字，key={key}）", flush=True)
    return reply


def _scan_status(login_state: str, logged: bool) -> str:
    """把网关内部扫码状态映射为 APP 侧 QrLoginStatus.wire。"""
    if logged:
        return "confirmed"
    return {
        "waiting_scan": "waiting",
        "scanned": "scanned",
        "logged_in": "confirmed",
        "expired": "expired",
        "idle": "waiting",
    }.get(str(login_state), "waiting")



# --------------------------------------------------------------------------
# Agent 运行时桥接：优先真实本地模型（TANGRAM_MODEL），否则检索式/占位降级
# --------------------------------------------------------------------------
def _cloud_config() -> tuple[str, str, str] | None:
    """读取云端 API 配置：TANGRAM_API_BASE / _KEY / _MODEL 三者齐备才生效。"""
    base = (os.environ.get("TANGRAM_API_BASE") or "").rstrip("/")
    key = os.environ.get("TANGRAM_API_KEY") or ""
    model = os.environ.get("TANGRAM_API_MODEL") or ""
    if base and key and model:
        return base, key, model
    return None


_CLOUD_SYSTEM = (
    "你是 TGA（Tangram），一个简洁、诚实、有用的中文助手。"
    "你有真实可用的工具：sandbox（TGA 唯一的沙箱，Termux 式工作区终端：在你的专属"
    "工作区 /workspace 里执行 shell 命令，能读写工作区文件、运行 python3、建 venv 装包，"
    "文件会持久保存；看不到也改不了沙箱以外的东西，单条命令超时 60 秒）、"
    "current_time（查当前时间）、recall_memory（检索你和用户的历史对话记忆）、"
    "remember_note（把重要事项记入长期记忆）。"
    "需要计算、验证、执行代码或在沙箱里干活时必须调用 sandbox，不要心算或猜测；"
    "涉及当前时间先调 current_time；用户让你记住事情时调 remember_note。"
    "工具返回的是真实执行结果，据实转述，失败就如实说失败原因。"
)


def _cloud_post(cfg: tuple[str, str, str], payload: dict) -> dict:
    """向云端 API 发一次 chat/completions 请求，返回解析后的 JSON。"""
    base, key, _model = cfg
    import urllib.request

    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        base + "/chat/completions",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 - 地址来自服务端配置
        return json.loads(resp.read().decode("utf-8"))


def _cloud_answer(text: str) -> str | None:
    """真实调用已配置的 OpenAI 兼容云端 API（纯对话）；未配置或失败返回 None。"""
    cfg = _cloud_config()
    if cfg is None:
        return None
    _base, _key, model = cfg
    try:
        data = _cloud_post(cfg, {
            "model": model,
            "messages": [
                {"role": "system", "content": _CLOUD_SYSTEM},
                {"role": "user", "content": text},
            ],
            "temperature": 0.7,
            "max_tokens": 2048,
        })
        content = str(data["choices"][0]["message"]["content"]).strip()
        return content or None
    except Exception as exc:  # noqa: BLE001 - 云端失败不吞消息，回落本地引擎
        print(f"[cloud] 云端推理失败，回落本地引擎：{exc}", flush=True)
        return None


# ---- 云端 Agent 工具循环：模型自主决定调用本地工具，网关真实执行后回喂 ----

_AGENT_TOOLS: list[dict] = [
    {
        "type": "function",
        "function": {
            "name": "sandbox",
            "description": "TGA 唯一的沙箱（Termux 式工作区）：在专属工作区 /workspace 里执行 shell 命令。"
                           "可读写工作区文件、运行 python3、用 venv/pip 装包，可联网，文件持久保存；"
                           "宿主已授权的目录会映射在 /host/<名称> 下（系统提示会列出），在那里的修改会真实作用到宿主文件；"
                           "除此之外看不到宿主其他任何东西；单条命令超时 60 秒。",
            "parameters": {
                "type": "object",
                "properties": {"command": {"type": "string", "description": "要执行的 shell 命令（在 /workspace 目录下运行）"}},
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "current_time",
            "description": "查询当前本地时间与 UTC 时间（真实时钟）。",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "recall_memory",
            "description": "按关键词检索与用户的历史对话记忆，返回最相关的若干条真实记录。",
            "parameters": {
                "type": "object",
                "properties": {"query": {"type": "string", "description": "检索关键词"}},
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "remember_note",
            "description": "把一件重要事项写入长期核心记忆，之后可被 recall_memory 检索到。",
            "parameters": {
                "type": "object",
                "properties": {"text": {"type": "string", "description": "要记住的事项"}},
                "required": ["text"],
            },
        },
    },
]


def _sandbox_mounts() -> list[dict]:
    """读取已授权的宿主目录映射（~/.tangram/sandbox_mounts.json）。

    授权只能由宿主侧操作者写入这份配置，沙箱内的 Agent 无权修改；
    凭据类目录与系统关键路径一律拒绝映射（即使写进配置也不生效）。
    返回 [{"name": ..., "host": ..., "mode": "rw"|"ro"}, ...]。
    """
    from pathlib import Path

    cfg_path = Path.home() / ".tangram" / "sandbox_mounts.json"
    try:
        data = json.loads(cfg_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    home = Path.home().resolve()
    # home 本身只做精确匹配拒绝（映射整个 home 等于不设防）；敏感子目录做前缀拒绝
    denied_exact = [home, Path("/"), Path("/etc"), Path("/root")]
    denied_roots = [
        home / ".tangram", home / ".ssh", home / ".gnupg", home / ".aws",
        Path("/etc"), Path("/root"), Path("/run/hatch"), Path("/proc"), Path("/sys"),
    ]
    out: list[dict] = []
    for item in data.get("mounts", []) if isinstance(data, dict) else []:
        name = str(item.get("name") or "")
        host = str(item.get("host") or "")
        mode = "ro" if item.get("mode") == "ro" else "rw"
        if not name.replace("-", "").replace("_", "").isalnum():
            continue
        try:
            resolved = Path(host).resolve()
        except (OSError, RuntimeError):
            continue
        if not resolved.is_dir():
            continue
        if resolved in denied_exact or any(
            resolved == d or str(resolved).startswith(str(d) + "/") for d in denied_roots
        ):
            print(f"[sandbox] 拒绝映射敏感路径：{resolved}", flush=True)
            continue
        out.append({"name": name, "host": str(resolved), "mode": mode})
    return out


def _sandbox_exec(command: str, timeout_s: float = 60.0) -> str:
    """TGA 唯一的沙箱（Termux 式工作区）：在独立 mount 命名空间 + chroot 里执行 shell 命令。

    可见文件系统只有只读的系统目录（/usr、/etc 等）与可写的工作区
    （宿主 ~/.tangram/agent_ws，沙箱内为 /workspace）；宿主 home、凭据、
    代码仓库都不在挂载视图里，看不到也改不了。命令经文件传入，不拼 shell 字符串。
    """
    import subprocess
    from pathlib import Path

    ws = Path.home() / ".tangram" / "agent_ws"
    ws.mkdir(parents=True, exist_ok=True)
    root = Path.home() / ".tangram" / "agent_root"
    root.mkdir(parents=True, exist_ok=True)
    (ws / ".agent_cmd.sh").write_text(command, encoding="utf-8")
    import shlex

    mount_lines = ""
    for m in _sandbox_mounts():
        target = f"$R/host/{m['name']}"
        ro = " -o ro" if m["mode"] == "ro" else ""
        mount_lines += (
            f'mkdir -p "{target}"\n'
            f"mount --bind{ro} {shlex.quote(m['host'])} \"{target}\"\n"
        )
    inner = r"""
set -e
R="$AGENT_ROOT"; W="$AGENT_WS"
mount -t tmpfs tmpfs "$R"
mkdir -p "$R/usr" "$R/etc" "$R/workspace" "$R/proc" "$R/dev" "$R/tmp"
ln -s usr/bin "$R/bin"; ln -s usr/lib "$R/lib"; ln -s usr/lib64 "$R/lib64"
mount --bind -o ro /usr "$R/usr"
for f in resolv.conf passwd group hosts nsswitch.conf localtime; do
  if [ -e "/etc/$f" ]; then touch "$R/etc/$f"; mount --bind -o ro "/etc/$f" "$R/etc/$f" 2>/dev/null || true; fi
done
if [ -d /etc/ssl ]; then mkdir -p "$R/etc/ssl"; mount --bind -o ro /etc/ssl "$R/etc/ssl" 2>/dev/null || true; fi
mount --bind "$W" "$R/workspace"
__MOUNT_LINES__
if [ -d /run/hatch/egress-tls ]; then
  mkdir -p "$R/run/hatch/egress-tls"
  mount --bind -o ro /run/hatch/egress-tls "$R/run/hatch/egress-tls" 2>/dev/null || true
fi
mount -t proc proc "$R/proc" 2>/dev/null || true
mount -t tmpfs tmpfs "$R/dev"
for d in null zero urandom full; do touch "$R/dev/$d"; mount --bind "/dev/$d" "$R/dev/$d"; done
export HOME=/workspace PATH=/usr/local/bin:/usr/bin:/bin TERM=dumb
exec timeout -s KILL "__TIMEOUT__" /usr/sbin/chroot "$R" /bin/bash -c 'cd /workspace && bash /workspace/.agent_cmd.sh'
"""
    inner = inner.replace("__TIMEOUT__", str(int(timeout_s)))
    inner = inner.replace("__MOUNT_LINES__", mount_lines)
    env = dict(os.environ, AGENT_ROOT=str(root), AGENT_WS=str(ws))
    try:
        proc = subprocess.run(
            ["unshare", "-rmpf", "bash", "-c", inner],
            capture_output=True, text=True, timeout=timeout_s + 15, env=env,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        out = out.strip()
        if proc.returncode == 137:
            out = (out + f"\n[命令超时 {int(timeout_s)}s 已强杀]").strip()
        elif proc.returncode != 0:
            out = (out + f"\n[exit={proc.returncode}]").strip()
        return out[:4000] if out else "(无输出)"
    except subprocess.TimeoutExpired:
        return f"工具执行失败：命令超时（>{int(timeout_s) + 15}s）已终止"
    finally:
        try:
            (ws / ".agent_cmd.sh").unlink(missing_ok=True)
        except OSError:
            pass


def _exec_agent_tool(name: str, args: dict, svc) -> str:
    """真实执行一个工具调用，返回给模型的结果文本。失败如实返回原因，绝不编造。"""
    try:
        if name == "sandbox":
            command = str(args.get("command") or "")
            if not command.strip():
                return "工具执行失败：command 为空"
            return _sandbox_exec(command)
        if name == "current_time":
            from datetime import datetime, timezone

            now = datetime.now()
            return (f"本地时间：{now.strftime('%Y-%m-%d %H:%M:%S')}（星期{'一二三四五六日'[now.weekday()]}）；"
                    f"UTC：{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')}")
        if name == "recall_memory":
            query = str(args.get("query") or "")
            lines: list[str] = []
            # 核心记忆（remember_note 写入处）：按词项包含粗筛，命中的优先给出
            tokens = [t for t in query.replace("，", " ").replace("？", " ").split() if t]
            for _cid, ctext in svc.memory.list_core():
                if not tokens or any(t in ctext for t in tokens) or any(
                    w in ctext for w in (query[i:i + 2] for i in range(max(0, len(query) - 1)))
                ):
                    lines.append(f"- [核心记忆] {ctext}")
            # 对话轮次：向量最近邻（返回 (MemoryEntry, score) 元组）
            for entry, _score in svc.memory.nearest_neighbors(query, k=4):
                if entry.text:
                    lines.append(f"- {entry.role}: {entry.text}")
            if not lines:
                return "没有检索到相关记忆。"
            return "\n".join(lines)[:2000]
        if name == "remember_note":
            note = str(args.get("text") or "").strip()
            if not note:
                return "工具执行失败：text 为空"
            core_id = svc.memory.core_commit(note)
            return f"已记入长期核心记忆（id={core_id}）：{note}"
        return f"工具执行失败：未知工具 {name}"
    except Exception as exc:  # noqa: BLE001 - 工具失败如实回喂给模型
        return f"工具执行失败：{type(exc).__name__}: {exc}"


def _cloud_agent_answer(text: str, svc) -> str | None:
    """带工具循环的云端应答：模型可多轮调用本地工具完成 agent 任务。

    端点不支持 tool_calls 或任一步失败时返回 None，由调用方回落纯对话/本地。
    """
    cfg = _cloud_config()
    if cfg is None:
        return None
    _base, _key, model = cfg
    mounts = _sandbox_mounts()
    if mounts:
        mount_note = "当前已获宿主授权映射进沙箱的目录：" + "；".join(
            f"/host/{m['name']}（{'只读' if m['mode'] == 'ro' else '可读写'}）" for m in mounts
        ) + "。在这些目录里的操作会真实作用到宿主文件。"
    else:
        mount_note = "当前没有已授权的宿主目录映射，沙箱只能操作自己的 /workspace。"
    messages: list[dict] = [
        {"role": "system", "content": _CLOUD_SYSTEM + mount_note},
        {"role": "user", "content": text},
    ]
    try:
        for _step in range(6):
            data = _cloud_post(cfg, {
                "model": model,
                "messages": messages,
                "tools": _AGENT_TOOLS,
                "temperature": 0.7,
                "max_tokens": 2048,
            })
            msg = data["choices"][0]["message"]
            calls = msg.get("tool_calls") or []
            if not calls:
                content = str(msg.get("content") or "").strip()
                return content or None
            messages.append(msg)
            for call in calls:
                fn = (call.get("function") or {})
                name = str(fn.get("name") or "")
                try:
                    args = json.loads(fn.get("arguments") or "{}")
                except (ValueError, TypeError):
                    args = {}
                result = _exec_agent_tool(name, args if isinstance(args, dict) else {}, svc)
                print(f"[agent] 工具调用 {name} -> {result.splitlines()[0][:120]}", flush=True)
                messages.append({
                    "role": "tool",
                    "tool_call_id": str(call.get("id") or ""),
                    "content": result,
                })
        print("[agent] 工具循环达到步数上限，回落纯对话", flush=True)
        return None
    except Exception as exc:  # noqa: BLE001 - 工具循环失败不吞消息，回落纯对话
        print(f"[agent] 工具循环失败，回落纯对话：{exc}", flush=True)
        return None


class AgentBridge:
    def __init__(self) -> None:
        self._svc = None
        self._lock = threading.Lock()
        self.mode = "pending"

    def _ensure(self):
        with self._lock:
            if self._svc is None:
                data_dir = os.environ.get("TANGRAM_DATA") or str(Path.home() / ".tangram")
                from app.runtime.agent_service import RuntimeService  # backend/ 在 path

                self._svc = RuntimeService(data_dir=data_dir)
                if _cloud_config() is not None:
                    self.mode = "cloud-agent"
                else:
                    self.mode = "native-llm" if os.environ.get("TANGRAM_MODEL") else "placeholder"
            return self._svc

    def answer(self, text: str, session_key: str) -> str:
        svc = self._ensure()
        cloud = _cloud_agent_answer(text, svc) or _cloud_answer(text)
        if cloud:
            with self._lock:
                try:  # 云端轮次同样落记忆库，保持本地/云端记录连续
                    svc.memory.add_turn("user", text, session_id=session_key)
                    svc.memory.add_turn("assistant", cloud, session_id=session_key)
                except Exception:  # noqa: BLE001 - 落库失败不影响已拿到的回复
                    pass
            return cloud
        with self._lock:
            try:
                return "".join(svc.chat_stream(text)).strip() or "（空回复）"
            except Exception as exc:  # 对话失败不吞消息：回可读错误
                return f"[Tangram] 运行时暂不可用：{exc}"


AGENT = AgentBridge()

# ---- 微信 iLink 登录状态机（qr 获取 -> 后台轮询扫码 -> 登录成功起接收循环）----
wx_login: dict[str, Any] = {"adapter": None, "route": None, "qrcode": "", "state": "idle",
                            "lock": threading.Lock()}

# ---- 飞书扫码接入（官方设备授权流；lark-oapi 缺失时如实降级）----
feishu_session: Any = None  # 由 _feishu_ensure() 惰性创建，避免导入期依赖
feishu_client: dict[str, Any] = {}


def _feishu_ensure() -> Any:
    """惰性创建飞书会话；登录成功后回调里启动长连接接送消息。"""
    global feishu_session
    if feishu_session is None:
        from im.feishu_bot import FeishuBotSession

        feishu_session = FeishuBotSession(on_connected=_feishu_on_connected)
    return feishu_session


def _feishu_on_connected(cred: dict[str, str]) -> None:
    """飞书扫码成功后，启动长连接接收消息并接入 Gateway / AGP 应答。"""
    def _run() -> None:
        try:
            import lark_oapi as lark  # type: ignore
            from lark_oapi.api.im.v1 import (  # type: ignore
                CreateMessageRequest, CreateMessageRequestBody,
            )

            client = (lark.Client.builder()
                      .app_id(cred["client_id"])
                      .app_secret(cred["client_secret"])
                      .build())

            def on_message(data: Any) -> None:
                try:
                    event = getattr(data, "event", None)
                    message = getattr(event, "message", None)
                    if message is None or not getattr(message, "content", None):
                        return
                    content = json.loads(message.content or "{}")
                    text = str(content.get("text") or "").strip()
                    if not text:
                        return
                    gw: Gateway = Handler.gateway
                    msg = MultimodalMessage(
                        user_id=str(getattr(message, "sender_id", {}).get("open_id", "feishu")),
                        platform="feishu", modality="text", payload=text, ts=time.time(),
                    )
                    answer = _agent_reply(text, f"feishu:{msg.user_id}") if text else ""
                    if answer:
                        req = (CreateMessageRequest.builder()
                               .receive_id_type("open_id")
                               .request_body(CreateMessageRequestBody.builder()
                                             .receive_id(msg.user_id)
                                             .msg_type("text")
                                             .content(json.dumps({"text": answer}, ensure_ascii=False))
                                             .build())
                               .build())
                        client.im.v1.message.create(req)
                except Exception as exc:  # noqa: BLE001
                    print(f"[feishu] 处理消息失败：{exc}", flush=True)

            # 长连接（WebSocket）无需公网回调；SDK 事件订阅已由扫码预置。
            handler = (lark.EventDispatcherHandler.builder("", "")
                       .register_p2_im_message_receive_v1(on_message).build())
            ws = lark.ws.Client(cred["client_id"], cred["client_secret"],
                                event_handler=handler, log_level=lark.LogLevel.INFO)
            feishu_client["ws"] = ws
            print("[feishu] 长连接启动", flush=True)
            ws.start()
        except Exception as exc:  # noqa: BLE001
            print(f"[feishu] 长连接启动失败：{exc}", flush=True)

    threading.Thread(target=_run, daemon=True, name="feishu-longconn").start()


def _msg_text(msg: MultimodalMessage) -> str:
    return extract_text(msg)


def _start_wechat_loop(wx, route) -> None:
    def _loop():
        print("[wx] getupdates 接收循环启动", flush=True)
        while True:
            try:
                msgs, _ = wx.get_updates(timeout=35)
                if msgs:
                    route(msgs)
            except Exception as exc:
                # 单次长轮询失败不能让接收线程永久退出（原实现无保护）。
                print(f"[wx] getupdates 本轮失败，1s 后重试：{exc}", flush=True)
                time.sleep(1.0)

    threading.Thread(target=_loop, daemon=True, name="wx-getupdates").start()


def _qr_png_bytes(content: str) -> Optional[bytes]:
    """把登录 URL 渲染为 PNG 二维码；segno 缺失返回 None（调用方降级）。"""
    try:
        import io

        import segno

        buf = io.BytesIO()
        segno.make(content, error="m").save(buf, kind="png", scale=8)
        return buf.getvalue()
    except Exception:
        return None


# --------------------------------------------------------------------------
# HTTP 处理器
# --------------------------------------------------------------------------
# ---- 多模态文本抽取# ---- 多模态文本抽取：语音用本机 whisper 真实转写（绝不伪造识别结果） ----
_ASR_FN: Any = None


def module_asr():
    global _ASR_FN
    if _ASR_FN is None:
        try:
            import sys
            backend_dir = str(_ROOT / "backend")
            if backend_dir not in sys.path:
                sys.path.insert(0, backend_dir)
            from voice.asr import whisper_transcriber

            fn = whisper_transcriber(
                model_size=os.environ.get("TANGRAM_ASR_MODEL", "base"),
                language=os.environ.get("TANGRAM_ASR_LANG", "zh") or None,
            )
            if fn is None:
                raise RuntimeError("whisper 后端不可用")
            _ASR_FN = fn
        except Exception as exc:
            _ASR_FN = False
            print(f"[asr] 降级：{exc}", flush=True)
    return _ASR_FN


def extract_text(msg: MultimodalMessage) -> str:
    if msg.modality == "text":
        if isinstance(msg.payload, dict):
            return str(msg.payload.get("text") or "")
        return str(msg.payload or "")
    if msg.modality == "voice" and isinstance(msg.payload, dict):
        hint = str(msg.payload.get("text") or "").strip()
        url = str(msg.payload.get("url") or "")
        asr = module_asr()
        if asr is not False and url and brain.is_safe_url(url):
            try:
                import urllib.request

                data = urllib.request.urlopen(url, timeout=15).read()  # noqa: S310
                pcm16k = to_pcm16k(data)
                if pcm16k is not None:
                    got = asr(pcm16k)
                    if got:
                        return got
            except Exception as exc:
                print(f"[asr] 转写失败：{exc}", flush=True)
        return hint or "（语音未能转写）"
    if msg.modality == "image" and isinstance(msg.payload, dict):
        return ""
    return str(msg.payload or "")


def to_pcm16k(data: bytes) -> Optional[bytes]:
    """wav/裸 PCM -> 16k mono s16le；非 wav 或需重采样且无 ffmpeg 时返回 None。"""
    import subprocess

    if data[:4] == b"RIFF":
        import io
        import wave

        try:
            with wave.open(io.BytesIO(data)) as w:
                if w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2:
                    return w.readframes(w.getnframes())
        except Exception:
            pass
    try:
        proc = subprocess.run(
            ["ffmpeg", "-loglevel", "error", "-i", "pipe:0",
             "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
            input=data, capture_output=True, timeout=30,
        )
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None

class Handler(BaseHTTPRequestHandler):
    # WebSocket 升级与 Host 头需要 HTTP/1.1；普通响应统一 Connection: close。
    protocol_version = "HTTP/1.1"
    gateway: Gateway = None  # 由 serve() 注入
    server_base: str = ""

    # ---- 基础 ----
    def _send(self, code: int, body: bytes, ctype: str = "application/json; charset=utf-8") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _json(self, obj: Any, code: int = 200) -> None:
        self._send(code, json.dumps(obj, ensure_ascii=False).encode())

    def log_message(self, fmt: str, *args: Any) -> None:  # 静音访问日志
        return

    # ---- AGP WebSocket：手机 APP 接入（im/agp_bridge.py）----
    def _ws_host(self) -> str:
        return (
            os.environ.get("TANGRAM_PUBLIC_HOST")
            or self.headers.get("Host")
            or f"127.0.0.1:{self.server.server_port}"
        )

    def _agp_websocket(self) -> None:
        from urllib.parse import parse_qs, urlparse

        qs = parse_qs(urlparse(self.path).query)
        token = (qs.get("token") or [""])[0]
        cred = verify_token(token)
        if cred is None:
            return self._json(
                {"ok": False, "error": "invalid-agp-token：请先在 APP 里完成扫码登录"}, 401
            )
        connector = (
            (qs.get("connector") or [cred.get("connector") or ""])[0] or "wechat"
        )
        key = self.headers.get("Sec-WebSocket-Key") or ""
        if not key:
            return self._json({"ok": False, "error": "missing-websocket-key"}, 400)

        handshake = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {ws_accept(key)}\r\n\r\n"
        )
        try:
            self.wfile.write(handshake.encode("ascii"))
            self.wfile.flush()
        except OSError:
            return
        self.close_connection = True

        sock = self.connection
        send_lock = threading.Lock()
        AGP_HUB.register(connector, sock, send_lock)
        try:
            while True:
                opcode, data = ws_read_frame(self.rfile.read)
                if opcode == 0x8:  # close
                    break
                if opcode == 0x9:  # ping -> pong
                    with send_lock:
                        sock.sendall(ws_frame(0xA, data))
                    continue
                if opcode == 0xA:
                    continue
                if opcode not in (0x1, 0x2):
                    continue
                try:
                    env = json.loads(data.decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    continue
                if not isinstance(env, dict):
                    continue
                if env.get("method") == "ping":
                    pong = {
                        "msg_id": str(uuid.uuid4()),
                        "method": "ping",
                        "payload": {"ts": int(time.time() * 1000)},
                    }
                    with send_lock:
                        sock.sendall(ws_text_frame(json.dumps(pong).encode()))
                    continue
                AGP_HUB.on_app_message(env)
        except (ConnectionError, OSError, ValueError):
            pass
        finally:
            AGP_HUB.unregister(connector, sock, send_lock)
            try:
                with send_lock:
                    sock.sendall(ws_frame(0x8, b""))
            except OSError:
                pass

    # ---- 路由 ----
    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/ws" and (self.headers.get("Upgrade") or "").lower() == "websocket":
            return self._agp_websocket()
        if path in ("/", "/index.html"):
            return self._dashboard()
        if path == "/api/status":
            adp = {
                n: {"enabled": a.enabled, "name": a.name} for n, a in self.gateway.adapters.items()
            }
            stats = self.gateway.stats()
            return self._json({
                "product": "Tangram IM Gateway",
                "version": "0.0.1",
                "running": self.gateway.running,
                "adapters": adp,
                "inbound_count": stats["inbound"],
                "outbound_count": stats["outbound"],
                "blocked_count": stats["blocked"],
                "circuit_open": stats["circuit_open"],
                "agent_mode": AGENT.mode,
                "onebot_base": self.server_base,
                "time": time.strftime("%F %T"),
            })
        if path == "/api/login/qq/qr":
            return self._qq_login_qr()
        if path == "/api/login/qq/status":
            return self._qq_login_status()
        if path == "/api/login/whatsapp/qr":
            return self._whatsapp_qr()
        if path == "/api/login/whatsapp/status":
            return self._whatsapp_status()
        if path == "/api/models/store":
            from urllib.parse import urlparse, parse_qs
            qs = parse_qs(urlparse(self.path).query)
            from app.models.store import search_models
            res = search_models((qs.get("q") or [""])[0])
            return self._json({"source": "ModelScope 魔搭社区", "count": len(res), "models": res})
        if path == "/api/login/wechat/qr":
            return self._wechat_login_qr()
        if path == "/api/login/wechat/status":
            return self._wechat_login_status()
        if path == "/api/login/feishu/qr":
            return self._feishu_login_qr()
        if path == "/api/login/feishu/status":
            return self._feishu_login_status()
        if path == "/api/discover":
            # 局域网发现的 HTTP 兜底（UDP 被防火墙拦时 APP 可直连探测）
            return self._json({"ok": True, "product": "Tangram IM Gateway",
                               "version": "0.0.1"})
        return self._json({"error": "not-found"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            body = json.loads(raw.decode("utf-8", "replace") or "{}")
        except Exception:
            return self._json({"error": "bad-json"}, 400)
        if path == "/webhook/qq_napcat":
            return self._webhook_onebot(body)
        if path == "/webhook/whatsapp":
            return self._webhook_whatsapp(body)
        if path == "/webhook/qq_openapi":
            return self._webhook_qq_openapi(body)
        if path == "/webhook/wechat_official":
            return self._webhook_wechat(body)
        if path == "/api/login/feishu/cancel":
            return self._feishu_cancel()
        return self._json({"error": "not-found"}, 404)

    # ---- QQ NapCat：真实登录二维码 ----
    def _onebot_get(self, action: str, params: Optional[dict] = None) -> tuple[Optional[dict], str]:
        from .util import NetClient

        net = NetClient(base_url=self.server_base, timeout=8)
        # OneBot v11 官方 HTTP API 路径为 /{action}（NapCat / go-cqhttp 同款）；
        # 部分协议端额外带 /onebot/v11 前缀，404 时回退兼容，避免整条通道不可用。
        data, why = net.get_json(f"/{action}", params or {})
        if data is not None:
            return data, why
        return net.get_json(f"/onebot/v11/{action}", params or {})

    def _qq_login_qr(self) -> None:
        # 路径一：NapCat 已上线 OneBot HTTP API（登录后），直接取实时二维码
        data, why = self._onebot_get("get_login_qrcode", {"type": "1"})
        if data is not None:
            url = (data.get("data") or {}).get("url") or (data.get("data") or {}).get("qrcode") or ""
            if url:
                png = _qr_png_bytes(url)
                if png is not None:
                    session = uuid.uuid4().hex[:12]
                    self.gateway.accounts.begin_scan("qq_napcat", session)
                    return self._send(200, png, "image/png")
                return self._json({"ok": True, "render": "text-only", "url": url})
        # 路径二：未登录阶段，读 NapCat 控制台落盘的实时二维码（NapCat 会过期自动刷新）
        cache = os.environ.get("NAPCAT_QR_CACHE", "")
        if cache and os.path.isfile(cache):
            try:
                with open(cache, "rb") as f:
                    png = f.read()
                if png:
                    self.gateway.accounts.begin_scan("qq_napcat", uuid.uuid4().hex[:12])
                    return self._send(200, png, "image/png")
            except OSError:
                pass
        return self._json({
            "ok": False,
            "reason": why,
            "hint": "NapCat 未提供二维码：需 NapCat 进程在线且控制台已生成登录二维码"
                    "（本服务不伪造二维码）。",
        }, 503)

    def _qq_login_status(self) -> None:
        data, why = self._onebot_get("get_login_info")
        if data is None:
            # 不把「暂不可达」当成登录失败：APP 仍在等待 NapCat 启动。
            print(f"[qq] get_login_info 暂不可达：{why}", flush=True)
            return self._json({"ok": True, "online": False, "status": "waiting"})
        d = data.get("data") or {}
        online = bool(d.get("user_id"))
        if online:
            self.gateway.accounts.mark_connected("qq_napcat", str(d.get("user_id")), True)
        out = {
            "ok": True,
            "online": online,
            "user_id": d.get("user_id"),
            "nickname": d.get("nickname"),
            "status": "confirmed" if online else "waiting",
        }
        if online:
            out.update(issue_credentials(self._ws_host(), "qq"))
        return self._json(out)

    # ---- webhook：入站 -> Agent -> 出站 ----
    def _webhook_onebot(self, body: dict) -> None:
        if body.get("post_type") != "message":
            return self._json({"ignored": body.get("post_type")})
        try:
            msg = self.gateway.handle_inbound(body, "qq_napcat")
        except Exception as exc:
            return self._json({"error": str(exc)}, 500)
        if msg.modality == "image" and isinstance(msg.payload, dict):
            answer = _media_answer([msg.payload], "image", f"qq:{msg.user_id}")
        else:
            text = extract_text(msg)
            answer = (
                (_bridge_reply(text, f"qq:{msg.user_id}", msg.user_id, "qq")
                 or _agent_reply(text, f"qq:{msg.user_id}"))
                if text else "（没听清/没识别到内容，换个说法试试）"
            )
        # 语音回复：消息以「语音：」开头则合成真实 wav，用 OneBot record 段下发
        modality, payload = "text", answer
        # 语音进→语音出；或用户显式要求语音
        want_voice = msg.modality == "voice" or answer.startswith("语音：") or answer.startswith("用语音说")
        if want_voice:
            say = answer.split("：", 1)[-1] if answer.startswith(("语音：", "用语音说")) else answer
            import os as _os
            wav = _os.path.join(_os.environ.get("TANGRAM_DATA", "/tmp"),
                                f"tts_{int(time.time()*1000)}.wav")
            from im.brain import synth_speech
            if synth_speech(say, wav):
                modality, payload = "voice", {"file": wav}
        reply = MultimodalMessage(
            user_id=msg.user_id, platform="qq_napcat", modality=modality,
            payload=payload, ts=time.time(),
        )
        ok, reason = self.gateway.send_outbound(reply)
        self._json({"ok": ok, "reason": reason, "reply_chars": len(answer)})

    def _webhook_wechat(self, body: dict) -> None:
        adp = self.gateway.adapters.get("wechat_official")
        sig, ts, nonce = (self.headers.get("X-Tangram-Signature", ""),
                          self.headers.get("X-Tangram-Timestamp", ""),
                          self.headers.get("X-Tangram-Nonce", ""))
        # fail-closed：早期实现把 `server_base` 非空作为验签前置条件，而默认
        # 注册的 WeChatOfficialAdapter() 恰好 server_base=""，整段验签被短路，
        # 任意伪造的 webhook 都能驱动 Agent 出站。现在未注册适配器、未配置
        # app_secret 或签名不匹配，一律 403。
        if adp is None or not adp.verify_message_signature(
            sig, ts, nonce, json.dumps(body, ensure_ascii=False, sort_keys=True)
        ):
            return self._json({"error": "bad-signature"}, 403)
        try:
            msg = self.gateway.handle_inbound(body, "wechat_official")
        except Exception as exc:
            return self._json({"error": str(exc)}, 500)
        answer = _agent_reply(str(msg.payload), f"wx:{msg.user_id}")
        self.gateway.send_outbound(MultimodalMessage(
            user_id=msg.user_id, platform="wechat_official", modality="text",
            payload=answer, ts=time.time(),
        ))
        self._json({"ok": True})

    def _webhook_qq_openapi(self, body: dict) -> None:
        """QQ 官方 APIv2 HTTP 回调：加密事件解密后进同一 Agent 管线。"""
        from .adapters.qq_openapi import QQOpenAPIAdapter

        adp = self.gateway.adapters.get("qq_openapi")
        if adp is None or not getattr(adp, "ready", False):
            return self._json({"ok": False, "hint": "qq_openapi 未配置凭据（TANGRAM_QQ_APPID/SECRET）"}, 503)
        event = body
        if isinstance(body.get("data"), str) and body.get("nonce"):
            event = QQOpenAPIAdapter.decrypt_callback(body, adp.client_secret)
            if event is None:
                return self._json({"ok": False, "reason": "decrypt-failed"}, 400)
        etype = str(event.get("type") or "")
        if etype in ("URL_VALIDATION", "aes/0") or (event.get("plain_token") and not etype):
            # 平台配置回调时的验证请求：按官方要求回显 plain_token（signature 校验由平台公钥体系完成）
            return self._json({"plain_token": event.get("plain_token", "")})
        if etype not in ("C2C_MESSAGE_CREATE", "GROUP_AT_MESSAGE_CREATE"):
            return self._json({"ignored": etype or "unknown"})
        try:
            msg = self.gateway.handle_inbound(event, "qq_openapi")
        except Exception as exc:
            return self._json({"error": str(exc)}, 500)
        text = extract_text(msg)
        answer = _agent_reply(text, f"qq2:{msg.user_id}") if text else "（未识别到内容）"
        ok, reason = self.gateway.send_outbound(MultimodalMessage(
            user_id=msg.user_id, platform="qq_openapi", modality="text",
            payload={"text": answer,
                     "msg_id": str((event.get("content") or {}).get("id") or ""),
                     "scope": "groups" if etype == "GROUP_AT_MESSAGE_CREATE" else "users"},
            ts=time.time(),
        ))
        self._json({"ok": ok, "reason": reason})

    def _webhook_whatsapp(self, body: dict) -> None:
        try:
            msg = self.gateway.handle_inbound(body, "whatsapp_baileys")
        except Exception as exc:
            return self._json({"error": str(exc)}, 500)
        text = extract_text(msg)
        answer = _agent_reply(text, f"wa:{msg.user_id}") if text else "（未识别到有效内容）"
        ok, reason = self.gateway.send_outbound(MultimodalMessage(
            user_id=msg.user_id, platform="whatsapp_baileys", modality="text",
            payload=answer, ts=time.time(),
        ))
        self._json({"ok": ok, "reason": reason})

    # ---- WhatsApp：真实配对二维码（Baileys 桥进程落盘） ----
    # ---- 微信 iLink：真实登录二维码 + 扫码监控 ----
    def _wechat_login_qr(self) -> None:
        wx = wx_login.get("adapter")
        if wx is None:
            return self._json({"ok": False, "hint": "微信渠道未装配"}, 500)
        if wx.has_token:
            return self._json({"ok": True, "already_logged_in": True,
                               "hint": "本机已有登录凭据；如需换号请删除 TANGRAM_DATA/weixin_ilink.json 后重试"})
        qrcode, url, why = wx.fetch_qr()
        if not qrcode or not url:
            return self._json({"ok": False, "reason": why,
                               "hint": "iLink 接口未返回二维码（网络或平台侧限制），本服务不伪造"}, 503)
        with wx_login["lock"]:
            wx_login["qrcode"] = qrcode
            wx_login["state"] = "waiting_scan"
        if wx_login.get("watcher") is None:
            wx_login["watcher"] = threading.Thread(
                target=self._wechat_watch_login, daemon=True, name="wx-login-watch")
            wx_login["watcher"].start()
        png = _qr_png_bytes(url)
        if png is None:
            return self._json({"ok": True, "render": "text-only", "url": url})
        return self._send(200, png, "image/png")

    @staticmethod
    def _wechat_watch_login() -> None:
        wx = wx_login["adapter"]
        while wx is not None and not wx.has_token:
            with wx_login["lock"]:
                qrcode = wx_login.get("qrcode", "")
            if not qrcode:
                time.sleep(1)
                continue
            resp = wx.poll_qr_status(qrcode)
            status = str(resp.get("status") or "wait")
            if status in ("expired", "expire", "timeout", "cancelled", "canceled"):
                # 二维码已失效：置 expired 并结束监视。旧实现把未知状态一律
                # 映射成 waiting_scan、对着死码无限轮询，APP 永远等不到结果；
                # 置 expired 后 APP 会重新申请新码（_scan_status 已映射 expired）。
                with wx_login["lock"]:
                    wx_login["state"] = "expired"
                    wx_login["qrcode"] = ""
                    wx_login["watcher"] = None
                print("[wx] 二维码已过期，监视结束（等待重新申请）", flush=True)
                return
            wx_login["state"] = {"scaned": "scanned", "scanned": "scanned",
                                 "confirmed": "logged_in", "success": "logged_in"}.get(status, "waiting_scan")
            if wx.has_token:
                wx_login["state"] = "logged_in"
                route = wx_login.get("route")
                if route is not None:
                    _start_wechat_loop(wx, route)
                print("[wx] 登录成功，接收循环已启动", flush=True)
                return
            time.sleep(1)

    def _wechat_login_status(self) -> None:
        wx = wx_login.get("adapter")
        logged = bool(wx and wx.has_token)
        state = str(wx_login.get("state", "idle"))
        out = {
            "ok": True,
            "logged_in": logged,
            "bot_id": (wx.bot_id if wx else ""),
            "login_state": state,
            # APP 侧 QrLoginStatus.wire
            "status": _scan_status(state, logged),
            "nickname": (wx.bot_id if wx else ""),
        }
        if logged:
            # 下发真实 AGP 连接凭据，APP 扫码成功后据此自动建立 WebSocket。
            out.update(issue_credentials(self._ws_host(), "wechat"))
        return self._json(out)

    def _whatsapp_qr(self) -> None:
        qr_path = os.environ.get("WHATSAPP_QR", "/root/wa-bridge/whatsapp_qr.png")
        if os.path.isfile(qr_path) and (time.time() - os.path.getmtime(qr_path)) < 300:
            with open(qr_path, "rb") as f:
                return self._send(200, f.read(), "image/png")
        return self._json({
            "ok": False,
            "hint": "WhatsApp 桥进程未运行或已登录（登录成功后二维码失效属正常）。"
                    "启动：node scripts/whatsapp-bridge/bridge.mjs",
        }, 503)

    def _whatsapp_status(self) -> None:
        adp = self.gateway.adapters.get("whatsapp_baileys")
        if adp is None:
            return self._json({"registered": False})
        data, why = adp.bridge_status()
        return self._json(data if data is not None else {"online": False, "reason": why})

    # ---- 飞书：官方设备授权流扫码一键建应用 ----
    def _feishu_login_qr(self) -> None:
        snap = _feishu_ensure().begin()
        if not snap.get("ok"):
            return self._json(snap, 503)
        qr_url = snap.get("qr_url", "")
        if not qr_url and not snap.get("already_logged_in"):
            # SDK 未就绪或还没拿到 URL：如实回错误，绝不画占位码。
            return self._json({"ok": False, "reason": snap.get("error") or "尚无可用的官方验证链接",
                               "hint": snap.get("error") or "稍后重试"}, 503)
        out: dict[str, Any] = {
            "ok": True, "qr_content": qr_url,
            "expires_in": snap.get("expire_in", 300) or 300,
            "status": snap.get("status", "waiting"),
        }
        if snap.get("already_logged_in"):
            out["already_logged_in"] = True
        png = _qr_png_bytes(qr_url) if qr_url else None
        if png is not None:
            return self._send(200, png, "image/png")
        return self._json(out)

    def _feishu_login_status(self) -> None:
        snap = _feishu_ensure().snapshot()
        out = dict(snap)
        if snap.get("logged_in"):
            out.update(issue_credentials(self._ws_host(), "feishu"))
        return self._json(out)

    def _feishu_cancel(self) -> None:
        from im.feishu_bot import clear_credentials

        session = _feishu_ensure()
        with session._lock:
            session.state, session.qr_url, session.error = "idle", "", ""
        clear_credentials()
        return self._json({"ok": True, "status": "idle"})

    # ---- 面板 ----
    def _dashboard(self) -> None:
        html = """<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>Tangram IM 接入面板</title><style>
body{font-family:system-ui;background:#0d1117;color:#e6edf3;margin:0;padding:32px}
.card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:20px;margin:12px 0;max-width:720px}
h1{font-size:22px} h3{margin-top:0} img.qr{width:260px;height:260px;border-radius:8px;background:#fff;padding:8px}
.muted{color:#8b949e;font-size:13px} button{background:#238636;color:#fff;border:0;border-radius:8px;padding:10px 18px;font-size:15px;cursor:pointer;margin-top:6px}
code{background:#21262d;padding:2px 6px;border-radius:4px}
</style></head><body>
<h1>檀阁瑞木 Tangram · IM 接入面板</h1>
<div class="card" id="st">状态加载中…</div>
<div class="card"><h3>微信（iLink Bot 官方协议 · 腾讯官方开源 openclaw-weixin 同款端点）</h3>
<div id="wxbox" class="muted">加载中…</div><button onclick="wxLogin()">获取微信登录二维码</button></div>
<div class="card"><h3>QQ 扫码接入（NapCat / OneBot v11 · 真实登录二维码，2 分钟自动刷新）</h3>
<div id="qqbox" class="muted">加载中…</div></div>
<div class="card"><h3>WhatsApp（Baileys · OpenClaw 官方同款协议，需境外网络出口）</h3>
<div id="wabox" class="muted">加载中…</div></div>
<div class="card"><h3>Telegram（Bot API 长轮询 · OpenClaw 官方同款渠道，需境外出口 + Bot Token）</h3><div id="tgbox" class="muted"></div></div>
<div class="card"><h3>微信旧渠道（公众号 / ClawBot 回调模式）</h3><p class="muted">在你自己的平台服务端配置回调到
<code>POST /webhook/wechat_official</code>（带 HMAC 签名头），验签通过后进入同一 Agent 管线。</p></div>
<script>
async function refresh(){const r=await fetch('/api/status').then(x=>x.json());
document.getElementById('st').innerHTML='<b>网关</b>：'+(r.running?'运行中':'已停止')+
' ｜ Agent：<b>'+r.agent_mode+'</b><br>渠道：'+Object.keys(r.adapters).map(a=>a+(r.adapters[a].enabled?'(启)':'(停)')).join('、')+
'<br>入站 '+r.inbound_count+' / 出站 '+r.outbound_count+' / 拦截 '+r.blocked_count;}
async function qq(){const r=await fetch('/api/login/qq/qr');
if(r.ok){document.getElementById('qqbox').innerHTML='<img class=qr src="/api/login/qq/qr?x='+Date.now()+'"><br><span class="muted">用 QQ 手机版扫码；NapCat 在线时每 2 分钟自动刷新</span>';}
else{const j=await r.json();document.getElementById('qqbox').innerHTML='<span class=muted>'+j.hint+'</span>';}}
let wxState='idle';
async function wxStatus(){const s=await fetch('/api/login/wechat/status').then(x=>x.json());wxState=s.login_state;
if(s.logged_in){document.getElementById('wxbox').innerHTML='<b>已登录（bot_id '+ (s.bot_id?s.bot_id.slice(0,10)+'…':'') +'）</b><br><span class=muted>消息接收循环运行中，私信即达本地模型</span>';return;}
if(wxState==='waiting_scan'||wxState==='scanned'){document.getElementById('wxbox').innerHTML='<img class=qr src="/api/login/wechat/qr?x='+Date.now()+'">'+(wxState==='scanned'?'<br><b>已扫码，请在手机上确认</b>':'<br><span class=muted>用手机微信扫码并确认授权</span>');}}
async function wxLogin(){const r=await fetch('/api/login/wechat/qr');
if(r.ok){document.getElementById('wxbox').innerHTML='<img class=qr src="/api/login/wechat/qr?x='+Date.now()+'"><br><span class=muted>用手机微信扫码并确认授权</span>';}
else{const j=await r.json();document.getElementById('wxbox').innerHTML='<span class=muted>'+(j.hint||j.reason||'获取失败')+'</span>';}}
async function wa(){const r=await fetch('/api/login/whatsapp/qr');
if(r.ok){document.getElementById('wabox').innerHTML='<img class=qr src="/api/login/whatsapp/qr?x='+Date.now()+'"><br><span class="muted">WhatsApp→设备配对→扫码</span>';}
else{const s=await fetch('/api/login/whatsapp/status').then(x=>x.json());
document.getElementById('wabox').innerHTML=s.online?'<b>已登录</b>':('<span class=muted>'+(s.hint||s.reason||'桥未运行（本机无国际网络出口，境外机房可用）')+'</span>');}}
async function tg(){const r=await fetch('/api/status').then(x=>x.json());
const on=r.adapters.telegram&&r.adapters.telegram.enabled;
document.getElementById('tgbox').innerHTML=on?'<b>已启用</b>':'<span class=muted>未配置 TANGRAM_TG_TOKEN（暂不启用，不伪造连接）</span>';}
async function tick(){try{await refresh();await qq();await wxStatus();await wa();await tg();}catch(e){}}
tick();setInterval(tick,8000);
</script></body></html>"""
        self._send(200, html.encode(), "text/html; charset=utf-8")


# --------------------------------------------------------------------------
# 装配
# --------------------------------------------------------------------------
def build_gateway(onebot_base: str, napcat_token: str) -> Gateway:
    gw = Gateway()
    gw.register_default_adapters()
    from .adapters.qq_napcat import QQNapCatAdapter
    from .adapters.telegram_bot import TelegramBotAdapter
    from .adapters.wechat_ilink import WeChatILinkAdapter
    from .adapters.whatsapp_baileys import WhatsAppBaileysAdapter

    adp = gw.adapters.get("qq_napcat")
    if adp is not None:
        adp.onebot_base = onebot_base
        adp.access_token = napcat_token or adp.access_token
    wa = WhatsAppBaileysAdapter(bridge_base=os.environ.get("WA_BRIDGE", "http://127.0.0.1:50433"))
    gw.register(wa)
    tg = TelegramBotAdapter()
    gw.register(tg)
    if tg.ready:
        tg.enabled = True

    def _route_tg(update: dict) -> None:
        try:
            msg = gw.handle_inbound(update, "telegram")
            answer = _agent_reply(str(msg.payload), f"tg:{msg.user_id}")
            gw.send_outbound(MultimodalMessage(
                user_id=msg.user_id, platform="telegram", modality="text",
                payload=answer, ts=time.time(),
            ))
        except Exception as exc:
            print(f"[tg] 处理失败：{exc}", flush=True)

    tg.start_polling(_route_tg)

    # 大脑接线：提醒到点后按 key 前缀走对应渠道出站（真实主动推送）
    def _deliver(key: str, text: str) -> None:
        chan, _, uid = key.partition(":")
        plat = {"wx": "wechat_ilink", "qq": "qq_napcat", "qq2": "qq_openapi",
                "wa": "whatsapp_baileys", "tg": "telegram"}.get(chan)
        if not plat or not uid:
            return
        payload: Any = text
        if plat == "wechat_ilink":
            payload = {"text": text, "context_token": wx_ctx.get(uid, "")}
        elif plat == "qq_openapi":
            payload = {"text": text, "msg_id": "", "scope": "users"}
        gw.send_outbound(MultimodalMessage(user_id=uid, platform=plat, modality="text",
                                           payload=payload, ts=time.time()))

    brain_default.deliver = _deliver
    brain_default._stop.clear()  # 启动提醒调度线程
    brain_default._ensure_timer()

    # 微信 iLink 官方协议渠道（腾讯官方开源 openclaw-weixin 同款端点与报文）
    wx = WeChatILinkAdapter()
    gw.register(wx)
    wx_login["adapter"] = wx

    # QQ 官方机器人 APIv2 渠道（协议对齐 tencent-connect/botpy 官方开源 SDK）
    from .adapters.qq_openapi import QQOpenAPIAdapter

    qq = QQOpenAPIAdapter()
    gw.register(qq)
    if qq.ready:
        qq.enabled = True

    def _route_wx(raw_msgs: list[dict]) -> None:
        for item in raw_msgs:
            try:
                msg = gw.handle_inbound(item, "wechat_ilink")
                if isinstance(msg.payload, dict):
                    tok = str(msg.payload.get("context_token") or "")
                    if tok:
                        wx_ctx[msg.user_id] = tok
                        _wx_ctx_persist()
                if msg.modality == "image" and isinstance(msg.payload, dict):
                    answer = _media_answer([msg.payload], "image", f"wx:{msg.user_id}")
                elif msg.modality == "voice" and isinstance(msg.payload, dict):
                    heard = extract_text(msg)
                    if not heard or heard.startswith("（语音"):
                        answer = "这条语音平台没给转写结果，我没听清，麻烦再说一次或打字发我。"
                    else:
                        answer = _agent_reply(heard, f"wx:{msg.user_id}")
                        # 语音进→语音出：合成 mp3 以文件消息回传（官方 FILE 通道）
                        if os.environ.get("TANGRAM_WX_VOICE", "1") == "1":
                            try:
                                from im.brain import synth_speech
                                import subprocess as _sp
                                wav = f"/tmp/wx_tts_{int(time.time()*1000)}.wav"
                                mp3 = wav.replace(".wav", ".mp3")
                                if synth_speech(heard and answer[:200] or "你好", wav):
                                    _sp.run(["ffmpeg", "-loglevel", "error", "-y", "-i", wav,
                                             "-codec:a", "libmp3lame", "-qscale:a", "6", mp3],
                                            check=True, timeout=60)
                                    ctx = wx_ctx.get(msg.user_id, "")
                                    wx_adp = gw.adapters.get("wechat_ilink")
                                    if wx_adp is not None and Path(mp3).is_file():
                                        wx_adp.send_file(msg.user_id, mp3,
                                                         caption="Tangram语音回复",
                                                         context_token=ctx)
                            except Exception as exc:
                                print(f"[wx] 语音文件回传失败：{exc}", flush=True)
                else:
                    text = extract_text(msg)
                    answer = (
                        (_bridge_reply(text, f"wx:{msg.user_id}", msg.user_id, "wechat")
                         or _agent_reply(text, f"wx:{msg.user_id}"))
                        if text else "（这条消息里没有我能解析的文本/图片内容）"
                    )
                payload: Any = answer
                ctx = msg.payload.get("context_token", "") if isinstance(msg.payload, dict) else ""
                if ctx:
                    payload = {"text": str(payload), "context_token": ctx}
                gw.send_outbound(MultimodalMessage(
                    user_id=msg.user_id, platform="wechat_ilink", modality="text",
                    payload=payload, ts=time.time(),
                ))
            except Exception as exc:
                print(f"[wx] 处理失败：{exc}", flush=True)

    wx_login["route"] = _route_wx
    if wx.has_token:
        _start_wechat_loop(wx, _route_wx)
    return gw


def serve(
    port: int = 50432,
    onebot_base: str = "",
    token: str = "",
    bind: str = "0.0.0.0",
) -> int:
    backend = str(_ROOT / "backend")
    if backend not in sys.path:
        sys.path.insert(0, backend)
    _wx_ctx_restore()
    gw = build_gateway(onebot_base, token)
    gw.start()
    # 预热：提前加载聊天模型与语音转写，避免首条消息冷启动 30-60s
    def _warm():
        try:
            AGENT._ensure()
            print("[warm] 聊天模型就绪", flush=True)
        except Exception as e:
            print(f"[warm] 聊天预热失败：{e}", flush=True)
        try:
            if os.environ.get("TANGRAM_ASR_WARM", "1") == "1":
                module_asr()
                print("[warm] 语音转写就绪", flush=True)
        except Exception as e:
            print(f"[warm] ASR 预热失败：{e}", flush=True)
    threading.Thread(target=_warm, daemon=True, name="warmup").start()
    Handler.gateway = gw
    Handler.server_base = onebot_base
    # 默认监听所有网卡：手机 APP 要能访问扫码端点与 AGP WebSocket。
    # 只放本机时可设 TANGRAM_BIND=127.0.0.1（此时需自行做端口转发）。
    class _Server(ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    httpd = _Server((bind, port), Handler)
    # 局域网自动发现：APP 在同一 WiFi 下点「连接」即可自动取到本网关地址，
    # 无需手填 IP。失败不影响主服务（公网部署可设 TANGRAM_DISCOVERY=0 关闭）。
    from im.discovery import DiscoveryServer

    discovery = DiscoveryServer(http_port=port)
    discovery_ok = discovery.start()
    print(
        f"[im-gateway] http://{bind}:{port}  面板 / 扫码 / AGP 就绪；"
        f"OneBot={onebot_base}  agent={AGENT.mode}  "
        f"局域网发现={'开' if discovery_ok else '关'}",
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        discovery.stop()
        gw.stop()
        httpd.shutdown()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Tangram IM 网关服务")
    ap.add_argument("--port", type=int, default=50432)
    ap.add_argument("--bind", default=os.environ.get("TANGRAM_BIND", "0.0.0.0"))
    ap.add_argument("--onebot", default=os.environ.get("NAPCAT_HTTP", "http://127.0.0.1:3000"))
    ap.add_argument("--napcat-token", default=os.environ.get("NAPCAT_TOKEN", ""))
    args = ap.parse_args()
    return serve(args.port, args.onebot, args.napcat_token, args.bind)


if __name__ == "__main__":
    raise SystemExit(main())
