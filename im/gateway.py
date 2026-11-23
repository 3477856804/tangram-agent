"""个人 IM 网关核心装配（沙箱外独立进程）。

职责：
- 统一多模态消息规范 ``MultimodalMessage``（user_id / platform / modality / payload / ts）。
- Adapter 注册表：register / unregister。
- inbound 规范化：handle_inbound(raw) 把各平台原始事件解析为标准消息并路由给 Agent 运行时。
- outbound 规范化：send_outbound(msg) 经风控守卫 pre_send 检查后下发到对应平台 Adapter。
- 把消息路由给 Agent 运行时：真实持久化 inbox（JSONL）+ 可注入处理器 /
  工作线程，消息不丢、可审计、可回放。
- 生命周期：start() / stop()。

约束：仅标准库；import 阶段不联网、不写文件；网络与加密惰性导入 + 降级。
"""

from __future__ import annotations

import json
import os
import queue
import threading
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

from .account.pool import AccountPool
from .approval import (
    CATEGORY_OUTBOUND,
    LEVEL_ASK,
    LEVEL_AUTO,
    LEVEL_DENY,
    ApprovalPolicy,
)
from .audit import AuditLog, safe_append
from .risk.guard import RiskGuard
from .util import now_ts


@dataclass
class MultimodalMessage:
    """跨平台统一多模态消息规范。

    Attributes:
        user_id: 平台用户唯一标识（openid / QQ 号等）。
        platform: 来源平台标识，对应 Adapter.name。
        modality: 主模态，取值如 text / image / voice / video / file。
        payload: 模态负载；文本为 str，图片/文件为 {url, media_id, ...} 字典。
        ts: 消息时间戳（秒）。
        message_id: 平台消息唯一 ID（缺省派生）。
    """

    user_id: str
    platform: str
    modality: str
    payload: Any
    ts: float = field(default_factory=now_ts)
    message_id: str = ""

    def __post_init__(self) -> None:
        if not self.message_id:
            self.message_id = f"{self.platform}:{self.user_id}:{self.ts:.3f}"


def _platform_key(platform: str) -> str:
    """审批键：同一平台的不同 Adapter 共用一个键。

    例如 wechat_ilink / wechat_official / wechat_unofficial 都归到 wechat，
    qq_napcat / qq_official 都归到 qq；用户按渠道设一次即可。
    未知平台返回原名，不合并。
    """
    p = (platform or "").strip().lower()
    if p.startswith("wechat"):
        return "wechat"
    if p.startswith("qq"):
        return "qq"
    if p.startswith("feishu"):
        return "feishu"
    if p.startswith("telegram"):
        return "telegram"
    if p.startswith("whatsapp"):
        return "whatsapp"
    return p


class Adapter(ABC):
    """IM Adapter 统一接口。

    所有平台接入实现本接口；子类需声明 ``name`` 与 ``enabled``，
    并实现 connect / parse_inbound / send_outbound。
    """

    name: str = "base"
    enabled: bool = True  # 默认启用；非官方/高风险 Adapter 可覆写为 False

    @abstractmethod
    def connect(self, account: Any) -> None:
        """用账号凭据建立/校验真实连接。

        子类必须真的向平台端点发起校验请求（如 OneBot ``get_login_info`` /
        桥 ``/status``），失败抛异常；不允许「什么都不做就返回成功」的占位实现。
        """
        raise NotImplementedError

    @abstractmethod
    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        """把平台原始事件归一化为 MultimodalMessage。"""
        raise NotImplementedError

    @abstractmethod
    def send_outbound(self, msg: MultimodalMessage) -> None:
        """把标准消息下发到平台（文本/图片等，按 modality 分支）。"""
        raise NotImplementedError

    def start(self) -> None:
        """可选：启动长轮询 / 监听（默认空实现）。"""
        return None

    def stop(self) -> None:
        """可选：停止监听（默认空实现）。"""
        return None


class AgentRuntimeHook:
    """真实 Agent 运行时路由：持久化 inbox + 可注入处理器 + 工作线程。

    * 每条入站消息都真实追加到 ``inbox_path`` 的 JSONL（重启可回放、可审计），
      不再是一个没人消费、进程一退就丢的内存队列。
    * ``handler(msg) -> str|None`` 由部署方注入（IM 网关里就是真实的
      ``_agent_reply`` / 手机端桥接推理）；``reply(msg, text)`` 注入真实出站。
    * 未注入 handler 时消息只入队，供 ``drain(handler)`` / 外部消费者取用；
      绝不伪造回复、绝不静默丢弃。
    * ``start()`` / ``stop()`` 管理后台工作线程的真实生命周期。
    """

    def __init__(self, inbox_path: str | Path | None = None) -> None:
        self.queue: "queue.Queue[MultimodalMessage]" = queue.Queue()
        self.on_reply: Optional[Callable[[MultimodalMessage], None]] = None
        self.handler: Optional[Callable[[MultimodalMessage], Optional[str]]] = None
        self.reply: Optional[Callable[[MultimodalMessage, str], None]] = None
        if inbox_path is None:
            data_dir = os.environ.get("TANGRAM_DATA") or str(Path.home() / ".tangram")
            inbox_path = Path(data_dir) / "im_inbox.jsonl"
        self.inbox_path = Path(inbox_path)
        self._lock = threading.Lock()
        self._thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._processed = 0
        self._failed = 0

    # ---- 真实持久化 ----
    def _persist(self, msg: MultimodalMessage) -> None:
        try:
            self.inbox_path.parent.mkdir(parents=True, exist_ok=True)
            record = {
                "ts": msg.ts,
                "platform": msg.platform,
                "user_id": msg.user_id,
                "modality": msg.modality,
                "payload": msg.payload if isinstance(msg.payload, (str, int, float, dict, list)) else str(msg.payload),
                "message_id": msg.message_id,
            }
            with self._lock, self.inbox_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, ensure_ascii=False) + "\n")
                fh.flush()
        except OSError as exc:
            # 落盘失败如实计数，不假装成功；消息仍在内存队列里可消费
            self._failed += 1
            print(f"[gateway] inbox 落盘失败：{exc}", flush=True)

    def replay(self, limit: int = 200) -> list[dict]:
        """从真实磁盘读回最近若干条入站消息（可审计 / 可回放）。"""
        if not self.inbox_path.is_file():
            return []
        lines = self.inbox_path.read_text(encoding="utf-8").splitlines()[-limit:]
        out: list[dict] = []
        for line in lines:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
        return out

    # ---- 注入与投递 ----
    def set_handler(
        self,
        handler: Callable[[MultimodalMessage], Optional[str]],
        reply: Optional[Callable[[MultimodalMessage, str], None]] = None,
    ) -> None:
        """注入真实的推理处理器与出站回调。"""
        self.handler = handler
        self.reply = reply

    def deliver(self, msg: MultimodalMessage) -> None:
        """入站消息真实落盘 + 入队 + （有处理器时）真实同步处理。"""
        self._persist(msg)
        self.queue.put(msg)
        if self.on_reply is not None:
            self.on_reply(msg)
        if self.handler is not None:
            self._process(msg)

    def _process(self, msg: MultimodalMessage) -> None:
        try:
            answer = self.handler(msg) if self.handler else None
        except Exception as exc:  # noqa: BLE001 - 处理器失败如实计数，不编造回复
            self._failed += 1
            print(f"[gateway] runtime handler 失败：{exc}", flush=True)
            return
        if answer and self.reply is not None:
            try:
                self.reply(msg, answer)
            except Exception as exc:  # noqa: BLE001
                self._failed += 1
                print(f"[gateway] runtime reply 失败：{exc}", flush=True)
        self._processed += 1

    def pop(self, block: bool = True, timeout: Optional[float] = None) -> Optional[MultimodalMessage]:
        """取出一条待处理入站消息。"""
        try:
            return self.queue.get(block=block, timeout=timeout)
        except queue.Empty:
            return None

    def drain(self, handler: Callable[[MultimodalMessage], Optional[str]],
              max_items: int = 1000) -> int:
        """用真实处理器消费队列里积压的消息，返回处理条数。"""
        done = 0
        while done < max_items:
            msg = self.pop(block=False)
            if msg is None:
                break
            old = self.handler
            self.handler = handler
            try:
                self._process(msg)
            finally:
                self.handler = old
            done += 1
        return done

    # ---- 工作线程 ----
    def start(self) -> bool:
        """启动真实后台分发线程；只在注入了 handler 时有意义。"""
        if self.handler is None or (self._thread is not None and self._thread.is_alive()):
            return False
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, daemon=True, name="agent-runtime")
        self._thread.start()
        return True

    def _run(self) -> None:
        while not self._stop_event.is_set():
            msg = self.pop(block=True, timeout=0.3)
            if msg is not None:
                self._process(msg)

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def stats(self) -> dict:
        return {
            "queued": self.queue.qsize(),
            "processed": self._processed,
            "failed": self._failed,
            "inbox": str(self.inbox_path.resolve()),
            "inbox_bytes": self.inbox_path.stat().st_size if self.inbox_path.is_file() else 0,
            "worker_alive": bool(self._thread and self._thread.is_alive()),
        }


class Gateway:
    """个人 IM 网关装配中心。

    装配关系：Adapter 注册表 + 风控守卫 + 加密账号池 + Agent 运行时路由。
    """

    def __init__(self, agent_runtime: Optional[AgentRuntimeHook] = None,
                 audit_log: Optional[AuditLog] = None,
                 approval_policy: Optional[ApprovalPolicy] = None) -> None:
        self.adapters: dict[str, Adapter] = {}
        self.risk: RiskGuard = RiskGuard()
        self.accounts: AccountPool = AccountPool()
        self.agent_runtime: AgentRuntimeHook = agent_runtime or AgentRuntimeHook()
        # 审计日志：默认落 TANGRAM_DATA/im_audit.jsonl；可注入测试实例。
        # 构造时不写文件；写盘失败只警告，绝不阻断出站（见 im/audit.py）。
        self.audit_log: AuditLog = audit_log if audit_log is not None else AuditLog()
        # 分级审批：默认落 TANGRAM_DATA/approval_policy.json；可注入测试实例。
        # 构造时不写文件；写盘失败只警告，绝不阻断出站（见 im/approval.py）。
        self.approval_policy: ApprovalPolicy = (
            approval_policy if approval_policy is not None else ApprovalPolicy()
        )
        self.running: bool = False
        self._lock = threading.Lock()
        # 统计与上下文隔离
        self._inbound_count: int = 0
        self._outbound_count: int = 0
        self._blocked_count: int = 0
        self._contexts: dict[str, list] = {}  # "adapter:handle" -> 最近若干条消息
        self._context_max: int = 16

    # ---- 注册表 ----
    def register(self, adapter: Adapter) -> None:
        """注册一个平台 Adapter（同名覆盖）。"""
        with self._lock:
            self.adapters[adapter.name] = adapter

    def unregister(self, name: str) -> None:
        """注销一个平台 Adapter。"""
        with self._lock:
            self.adapters.pop(name, None)

    def adapter(self, name: str) -> Adapter:
        """按平台名取 Adapter，缺失则抛 KeyError。"""
        with self._lock:
            if name not in self.adapters:
                raise KeyError(f"未注册的 Adapter: {name}")
            return self.adapters[name]

    def set_adapter_enabled(self, name: str, enabled: bool) -> None:
        """动态启停某 Adapter（如用户确认风险后启用非官方渠道）。"""
        with self._lock:
            adp = self.adapters.get(name)
            if adp is None:
                raise KeyError(f"未注册的 Adapter: {name}")
            adp.enabled = enabled

    def register_default_adapters(self) -> None:
        """注册约定的五个 Adapter（微信官方默认启用，
        微信非官方默认禁用，QQ 官方默认启用，QQ NapCat 默认启用但风险自担，
        微信 iLink 默认启用——是否已登录由其 has_token 决定，send_outbound
        在未登录时诚实报错，不伪造在线）。
        """
        from .adapters.qq_napcat import QQNapCatAdapter
        from .adapters.qq_official import QQOfficialAdapter
        from .adapters.wechat_ilink import WeChatILinkAdapter
        from .adapters.wechat_official import WeChatOfficialAdapter
        from .adapters.wechat_unofficial import WeChatUnofficialAdapter

        self.register(WeChatOfficialAdapter())
        self.register(WeChatUnofficialAdapter())  # 默认 enabled=False
        self.register(QQOfficialAdapter())
        self.register(QQNapCatAdapter())
        self.register(WeChatILinkAdapter())

    # ---- 生命周期 ----
    def start(self) -> None:
        """启动网关：标记 running、拉起运行时分发线程、触发各 Adapter 监听。"""
        self.running = True
        self.agent_runtime.start()
        for adp in self.adapters.values():
            try:
                adp.start()
            except Exception:  # 单个 Adapter 启动失败不影响整体
                continue

    def stop(self) -> None:
        """停止网关：标记 running、停分发线程、停各 Adapter 监听。"""
        self.running = False
        self.agent_runtime.stop()
        for adp in self.adapters.values():
            try:
                adp.stop()
            except Exception:
                continue

    # ---- 入站 ----
    def handle_inbound(self, raw: dict[str, Any], adapter_name: str) -> MultimodalMessage:
        """把平台原始事件归一化并路由给 Agent 运行时。

        Args:
            raw: 平台原始事件字典（如微信 webhook / OneBot 事件）。
            adapter_name: 对应平台 Adapter.name。
        Returns:
            归一化后的 MultimodalMessage。
        """
        adp = self.adapter(adapter_name)
        if not adp.enabled:
            raise RuntimeError(f"Adapter 已禁用: {adapter_name}")
        msg = adp.parse_inbound(raw)
        # 上下文隔离：多账号不共享上下文，按 adapter:user 分别记录
        self._record_context(msg)
        with self._lock:
            self._inbound_count += 1
        self.agent_runtime.deliver(msg)
        return msg

    def _record_context(self, msg: MultimodalMessage) -> None:
        if not self.accounts.context_isolation:
            key = "*"
        else:
            key = f"{msg.platform}:{msg.user_id}"
        buf = self._contexts.setdefault(key, [])
        buf.append({"ts": msg.ts, "modality": msg.modality, "payload": msg.payload})
        if len(buf) > self._context_max:
            buf[:] = buf[-self._context_max:]

    def get_context(self, platform: str, user_id: str) -> list:
        """取某用户（隔离）上下文，多账号隔离下互不串扰。"""
        key = f"{platform}:{user_id}" if self.accounts.context_isolation else "*"
        return list(self._contexts.get(key, []))

    # ---- 出站前置检查（供外部/测试直接调用）----
    def outbound_allowed(self, msg: MultimodalMessage) -> tuple[bool, str]:
        """综合判断：Adapter 启用 + 审批级别 + 用户白名单 + 风控放行。

        审批是用户设的门：deny 直接拒绝；ask 且无一次性批准时返回
        needs-approval（只查看不消耗，真正消耗发生在 send_outbound）；
        auto 或已有批准时继续走白名单 / 风控。
        """
        with self._lock:
            adp = self.adapters.get(msg.platform)
        if adp is None:
            return False, f"unknown-adapter:{msg.platform}"
        if not adp.enabled:
            return False, f"adapter-disabled:{msg.platform}"
        key = _platform_key(msg.platform)
        level = self.approval_policy.decide(
            CATEGORY_OUTBOUND, key=key
        )
        if level == LEVEL_DENY:
            return False, f"approval-deny:{msg.platform}"
        if level == LEVEL_ASK and not self.approval_policy.has_approval(
            CATEGORY_OUTBOUND, key=key, subject=msg.user_id
        ):
            return False, "needs-approval"
        if msg.user_id in self.risk.user_whitelist:
            return True, "whitelisted"
        return self.risk.pre_send(msg)

    # ---- 出站 ----
    def _audit_outbound(self, msg: MultimodalMessage, decision: str, reason: str) -> None:
        """记一条出站审计事件：只记谁/哪个适配器/什么动作/批准还是拒绝，
        绝不记消息正文。写盘失败只警告，绝不阻断出站。"""
        safe_append(
            self.audit_log,
            category="im.outbound",
            action="send_outbound",
            decision=decision,
            actor=msg.platform,
            detail=f"user={msg.user_id} modality={msg.modality} "
                   f"reason={str(reason)[:200]}",
        )

    def send_outbound(self, msg: MultimodalMessage, *,
                      from_reply: bool = False) -> tuple[bool, str]:
        """经风控守卫检查后下发标准消息到对应平台。

        每个出口（成功 / 风控拒绝 / Adapter 禁用 / 下发失败）都追加
        一条审计事件，decision 分别为 allowed / denied / failed。

        from_reply=True 表示这是入站触发的回复（用户刚发来消息，等回复）：
        不过分级审批这道门——审批只管主动外发（调研报告的范围；Dart 侧
        也只对 _sendProactive 设门）。主动外发一律走审批门。

        Returns:
            (allow, reason)：allow 为 True 表示已下发，否则为拦截原因。
        """
        try:
            adp = self.adapter(msg.platform)
        except KeyError:
            self._audit_outbound(msg, "failed", f"unknown-adapter:{msg.platform}")
            raise
        if not adp.enabled:
            with self._lock:
                self._blocked_count += 1
            self._audit_outbound(msg, "denied", f"adapter-disabled:{msg.platform}")
            return False, f"adapter-disabled:{msg.platform}"
        allow, reason = self.risk.pre_send(msg)
        if not allow:
            with self._lock:
                self._blocked_count += 1
            self._audit_outbound(msg, "denied", reason)
            return False, reason
        # 分级审批（默认 ask）只管主动外发：风控放行后、真正下发前再过
        # 一道用户设的门。deny 直接拒绝；ask 时没有一次性批准就记一条
        # 待审批并返回 needs-approval:<id>，不发送；auto 或已批准则放行。
        # 入站回复（from_reply=True）直接按 auto 处理，不进这道门。
        key = _platform_key(msg.platform)
        level = (LEVEL_AUTO if from_reply else self.approval_policy.decide(
            CATEGORY_OUTBOUND, key=key
        ))
        if level == LEVEL_DENY:
            with self._lock:
                self._blocked_count += 1
            self._audit_outbound(msg, "denied", f"approval-deny:{msg.platform}")
            return False, f"approval-deny:{msg.platform}"
        if level == LEVEL_ASK:
            if not self.approval_policy.consume_approval(
                CATEGORY_OUTBOUND, key=key, subject=msg.user_id
            ):
                entry = self.approval_policy.request_approval(
                    CATEGORY_OUTBOUND,
                    key=key,
                    subject=msg.user_id,
                    detail=f"outbound {msg.platform} -> user={msg.user_id} "
                           f"modality={msg.modality}",
                )
                with self._lock:
                    self._blocked_count += 1
                self._audit_outbound(
                    msg, "denied", f"needs-approval:{entry['id']}"
                )
                return False, f"needs-approval:{entry['id']}"
        try:
            adp.send_outbound(msg)
        except Exception as exc:  # 下发失败 -> 上报风控熔断器
            self.risk.on_failure(msg.platform)
            with self._lock:
                self._blocked_count += 1
            self._audit_outbound(msg, "failed", f"send-error:{type(exc).__name__}:{exc}")
            return False, f"send-error:{type(exc).__name__}:{exc}"
        with self._lock:
            self._outbound_count += 1
        self._audit_outbound(msg, "allowed", "sent")
        return True, "sent"

    # ---- 分级审批管理（委托给 ApprovalPolicy，见 im/approval.py）----
    def set_approval_level(self, category: str, key: str = "",
                           level: str = "ask", actor: str = "user",
                           confirmed: bool = False) -> dict[str, Any]:
        """设置某分类的审批级别。设为 auto 必须 confirmed=True。"""
        return self.approval_policy.set_level(
            category, key=key, level=level, actor=actor, confirmed=confirmed
        )

    def resolve_approval(self, approval_id: str, allow: bool,
                         actor: str = "user") -> dict[str, Any] | None:
        """处理一条待审批；批准时记一枚一次性批准（10 分钟内只放行一次）。"""
        return self.approval_policy.resolve_approval(
            approval_id, allow, actor=actor
        )

    def list_pending_approvals(self) -> list[dict[str, Any]]:
        """列出全部待审批（按创建时间升序）。"""
        return self.approval_policy.list_pending()

    def get_approval_policy(self) -> dict[str, Any]:
        """返回当前审批策略快照（只含级别与设置记录，不含任何密钥）。"""
        return self.approval_policy.get_policy()

    def reply(self, platform: str, user_id: str, text: str) -> tuple[bool, str]:
        """向指定平台用户回复一条文本消息（入站触发的回复，不过审批门；
        风控与审计照常）。"""
        msg = MultimodalMessage(user_id=user_id, platform=platform, modality="text", payload=text)
        return self.send_outbound(msg, from_reply=True)

    def stats(self) -> dict[str, Any]:
        """返回网关运行统计。"""
        with self._lock:
            return {
                "adapters": len(self.adapters),
                "inbound": self._inbound_count,
                "outbound": self._outbound_count,
                "blocked": self._blocked_count,
                "circuit_open": self.risk.circuit_open,
                "whitelist": sorted(self.risk.user_whitelist),
                "audit_log": str(self.audit_log.path),
                "runtime": self.agent_runtime.stats(),
            }
