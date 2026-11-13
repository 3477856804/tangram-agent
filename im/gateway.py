"""个人 IM 网关核心装配（沙箱外独立进程）。

职责：
- 统一多模态消息规范 ``MultimodalMessage``（user_id / platform / modality / payload / ts）。
- Adapter 注册表：register / unregister。
- inbound 规范化：handle_inbound(raw) 把各平台原始事件解析为标准消息并路由给 Agent 运行时。
- outbound 规范化：send_outbound(msg) 经风控守卫 pre_send 检查后下发到对应平台 Adapter。
- 把消息路由给 Agent 运行时：通过回调 / 队列占位，不实际 import 后端运行时。
- 生命周期：start() / stop()。

约束：仅标准库；import 阶段不联网、不写文件；网络与加密惰性导入 + 降级。
"""

from __future__ import annotations

import queue
import threading
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from .account.pool import AccountPool
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


class Adapter(ABC):
    """IM Adapter 统一接口。

    所有平台接入实现本接口；子类需声明 ``name`` 与 ``enabled``，
    并实现 connect / parse_inbound / send_outbound。
    """

    name: str = "base"
    enabled: bool = True  # 默认启用；非官方/高风险 Adapter 可覆写为 False

    @abstractmethod
    def connect(self, account: Any) -> None:
        """使用账号凭据建立连接（占位：真实实现走平台 SDK）。"""
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
    """Agent 运行时路由占位（不实际 import 后端）。

    真实部署时由 Dart/PythonBridge 后端注入具体实现，例如把入站消息
    投入推理队列；此处默认实现为一个线程安全 FIFO 队列，便于测试与解耦。
    """

    def __init__(self) -> None:
        self.queue: "queue.Queue[MultimodalMessage]" = queue.Queue()
        self.on_reply: Optional[Callable[[MultimodalMessage], None]] = None

    def deliver(self, msg: MultimodalMessage) -> None:
        """入站消息送达 Agent 运行时（占位：入队并触发回调）。"""
        self.queue.put(msg)
        if self.on_reply is not None:
            self.on_reply(msg)

    def pop(self, block: bool = True, timeout: Optional[float] = None) -> Optional[MultimodalMessage]:
        """取出一条待处理入站消息（占位）。"""
        try:
            return self.queue.get(block=block, timeout=timeout)
        except queue.Empty:
            return None


class Gateway:
    """个人 IM 网关装配中心。

    装配关系：Adapter 注册表 + 风控守卫 + 加密账号池 + Agent 运行时路由。
    """

    def __init__(self, agent_runtime: Optional[AgentRuntimeHook] = None) -> None:
        self.adapters: dict[str, Adapter] = {}
        self.risk: RiskGuard = RiskGuard()
        self.accounts: AccountPool = AccountPool()
        self.agent_runtime: AgentRuntimeHook = agent_runtime or AgentRuntimeHook()
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
        """注册约定的四个 Adapter（微信官方默认启用，
        微信非官方默认禁用，QQ 官方默认启用，QQ NapCat 默认启用但风险自担）。
        """
        from .adapters.qq_napcat import QQNapCatAdapter
        from .adapters.qq_official import QQOfficialAdapter
        from .adapters.wechat_official import WeChatOfficialAdapter
        from .adapters.wechat_unofficial import WeChatUnofficialAdapter

        self.register(WeChatOfficialAdapter())
        self.register(WeChatUnofficialAdapter())  # 默认 enabled=False
        self.register(QQOfficialAdapter())
        self.register(QQNapCatAdapter())

    # ---- 生命周期 ----
    def start(self) -> None:
        """启动网关：标记 running 并触发各 Adapter 监听（若存在）。"""
        self.running = True
        for adp in self.adapters.values():
            try:
                adp.start()
            except Exception:  # 单个 Adapter 启动失败不影响整体
                continue

    def stop(self) -> None:
        """停止网关：标记 running 并停止各 Adapter 监听。"""
        self.running = False
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
        """综合判断：Adapter 启用 + 风控放行 + 用户白名单。"""
        with self._lock:
            adp = self.adapters.get(msg.platform)
        if adp is None:
            return False, f"unknown-adapter:{msg.platform}"
        if not adp.enabled:
            return False, f"adapter-disabled:{msg.platform}"
        if msg.user_id in self.risk.user_whitelist:
            return True, "whitelisted"
        return self.risk.pre_send(msg)

    # ---- 出站 ----
    def send_outbound(self, msg: MultimodalMessage) -> tuple[bool, str]:
        """经风控守卫检查后下发标准消息到对应平台。

        Returns:
            (allow, reason)：allow 为 True 表示已下发，否则为拦截原因。
        """
        adp = self.adapter(msg.platform)
        if not adp.enabled:
            with self._lock:
                self._blocked_count += 1
            return False, f"adapter-disabled:{msg.platform}"
        allow, reason = self.risk.pre_send(msg)
        if not allow:
            with self._lock:
                self._blocked_count += 1
            return False, reason
        try:
            adp.send_outbound(msg)
        except Exception as exc:  # 下发失败 -> 上报风控熔断器
            self.risk.on_failure(msg.platform)
            with self._lock:
                self._blocked_count += 1
            return False, f"send-error:{type(exc).__name__}:{exc}"
        with self._lock:
            self._outbound_count += 1
        return True, "sent"

    def reply(self, platform: str, user_id: str, text: str) -> tuple[bool, str]:
        """向指定平台用户回复一条文本消息（走完整出站门控）。"""
        msg = MultimodalMessage(user_id=user_id, platform=platform, modality="text", payload=text)
        return self.send_outbound(msg)

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
            }
