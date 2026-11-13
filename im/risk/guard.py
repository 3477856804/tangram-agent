"""风控守卫：限频 / 白名单 / 免打扰 / 熔断。

设计：仅标准库；pre_send(msg) 返回 (allow, reason)，供 Gateway 在出站前调用。
- 限频：per-user 令牌桶（capacity +  refill 速率）。
- 白名单：白名单内用户跳过限频（仍受免打扰/熔断约束）。
- 免打扰：支持相对时段（set_dnd 秒数）与每日固定时段（如 23:00-07:00）。
- 熔断：某平台连续失败超过阈值即断开（circuit_open），需手动或自动 reset。
"""

from __future__ import annotations

import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional, Tuple

from ..util import now_ts

# (allow, reason) 统一返回类型
Decision = Tuple[bool, str]


@dataclass
class _TokenBucket:
    """per-user 令牌桶。"""

    tokens: float
    last: float = field(default_factory=now_ts)


class RiskGuard:
    """IM 出站风控守卫。"""

    def __init__(
        self,
        rate_per_user: float = 1.0,   # 每用户每秒补充令牌数
        burst: float = 20.0,          # 令牌桶容量（突发上限）
        failure_threshold: int = 5,   # 连续失败触发熔断的阈值
        global_rate: float = 50.0,    # 全网关每秒补充令牌数
        global_burst: float = 200.0,  # 全网关突发上限
    ) -> None:
        self.rate_per_user = rate_per_user
        self.burst = burst
        self.failure_threshold = failure_threshold
        self.global_rate = global_rate
        self.global_burst = global_burst

        self._buckets: dict[str, _TokenBucket] = defaultdict(
            lambda: _TokenBucket(tokens=self.burst)
        )
        # 全局令牌桶：约束整个网关的出站吞吐
        self._global_bucket: _TokenBucket = _TokenBucket(tokens=self.global_burst)
        self.user_whitelist: set[str] = set()

        # 免打扰：相对时段
        self.dnd_until: float = 0.0
        # 免打扰：每日固定时段（24h 制，跨零点自动处理），None 表示不启用
        self.dnd_window: Optional[Tuple[int, int]] = None
        # 免打扰：按星期几的固定时段（weekday -> (start_hour, end_hour)）
        self.dnd_weekly: dict[int, Tuple[int, int]] = {}

        # 熔断：per-platform 连续失败计数
        self.circuit_open: bool = False
        self._failures: dict[str, int] = defaultdict(int)
        # 熔断自动恢复：打开后经过 auto_reset_after 秒自动半开复位（默认 0=不自动）
        self.auto_reset_after: float = 0.0
        self._circuit_open_at: float = 0.0
        # 决策审计（最多保留最近 256 条）
        self.decisions: list[dict] = []

    # ---- 白名单 ----
    def add_whitelist(self, user_id: str) -> None:
        self.user_whitelist.add(user_id)

    def remove_whitelist(self, user_id: str) -> None:
        self.user_whitelist.discard(user_id)

    # ---- 免打扰 ----
    def set_dnd(self, seconds: float) -> None:
        """设置相对免打扰时段（秒）。"""
        self.dnd_until = now_ts() + seconds

    def set_dnd_window(self, start_hour: int, end_hour: int) -> None:
        """设置每日固定免打扰时段（如 23, 7 表示 23:00-07:00）。"""
        self.dnd_window = (start_hour, end_hour)

    def set_dnd_weekly(self, weekday: int, start_hour: int, end_hour: int) -> None:
        """设置按星期几的固定免打扰时段（weekday: 0=周一 ... 6=周日）。"""
        self.dnd_weekly[weekday] = (start_hour, end_hour)

    def _in_dnd(self) -> bool:
        if now_ts() < self.dnd_until:
            return True
        if self.dnd_window is not None:
            sh, eh = self.dnd_window
            cur = time.localtime().tm_hour
            if sh <= eh:
                if sh <= cur < eh:
                    return True
            else:  # 跨零点，如 23->7
                if cur >= sh or cur < eh:
                    return True
        # 每周固定免打扰
        if self.dnd_weekly:
            wd = time.localtime().tm_wday
            if wd in self.dnd_weekly:
                sh, eh = self.dnd_weekly[wd]
                cur = time.localtime().tm_hour
                if sh <= eh:
                    if sh <= cur < eh:
                        return True
                else:
                    if cur >= sh or cur < eh:
                        return True
        return False

    def set_global_rate(self, rate: float, burst: float | None = None) -> None:
        """调整全局限频参数。"""
        self.global_rate = max(0.0, float(rate))
        if burst is not None:
            self.global_burst = max(1.0, float(burst))
            self._global_bucket.tokens = min(self._global_bucket.tokens, self.global_burst)

    def _consume_global(self) -> bool:
        bucket = self._global_bucket
        now = now_ts()
        bucket.tokens = min(
            self.global_burst, bucket.tokens + (now - bucket.last) * self.global_rate
        )
        bucket.last = now
        if bucket.tokens >= 1.0:
            bucket.tokens -= 1.0
            return True
        return False

    def _maybe_auto_reset_circuit(self) -> None:
        """熔断自动恢复：超过 auto_reset_after 秒则复位（半开试探）。"""
        if (
            self.circuit_open
            and self.auto_reset_after > 0
            and (now_ts() - self._circuit_open_at) >= self.auto_reset_after
        ):
            self.reset_circuit()

    def _audit(self, user_id: str, allow: bool, reason: str) -> None:
        self.decisions.append(
            {"user_id": user_id, "allow": allow, "reason": reason, "ts": now_ts()}
        )
        if len(self.decisions) > 256:
            self.decisions = self.decisions[-256:]

    # ---- 限频（令牌桶） ----
    def _consume(self, user_id: str) -> bool:
        if user_id in self.user_whitelist:
            return True
        bucket = self._buckets[user_id]
        now = now_ts()
        bucket.tokens = min(
            self.burst, bucket.tokens + (now - bucket.last) * self.rate_per_user
        )
        bucket.last = now
        if bucket.tokens >= 1.0:
            bucket.tokens -= 1.0
            return True
        return False

    # ---- 熔断 ----
    def on_failure(self, adapter: str) -> None:
        """记录一次平台失败，连续超阈值则熔断。"""
        self._failures[adapter] += 1
        if self._failures[adapter] >= self.failure_threshold:
            self.circuit_open = True
            self._circuit_open_at = now_ts()

    def reset_circuit(self, adapter: Optional[str] = None) -> None:
        """手动/自动复位熔断与失败计数。"""
        self.circuit_open = False
        self._circuit_open_at = 0.0
        if adapter is None:
            self._failures.clear()
        else:
            self._failures.pop(adapter, None)

    # ---- 出站前置检查 ----
    def pre_send(self, msg) -> Decision:
        """出站前置检查。msg 应为 MultimodalMessage；兼容 None/裸字典。

        检查顺序：熔断自动恢复 -> 熔断打开 -> 免打扰 -> 全局限频 ->
        空消息 -> 用户令牌桶 -> 通过。
        Returns:
            (allow, reason)
        """
        self._maybe_auto_reset_circuit()
        if self.circuit_open:
            self._audit(self._uid(msg), False, "circuit-open")
            return False, "circuit-open"
        if self._in_dnd():
            self._audit(self._uid(msg), False, "do-not-disturb")
            return False, "do-not-disturb"

        user_id = self._uid(msg)
        if msg is None or user_id is None:
            # 无用户信息视为空消息，不允许下发（不消耗令牌）。
            self._audit("", False, "empty-message")
            return False, "empty-message"

        if not self._consume_global():
            self._audit(user_id, False, "global-rate-limited")
            return False, "global-rate-limited"
        if not self._consume(user_id):
            self._audit(user_id, False, "rate-limited")
            return False, "rate-limited"
        self._audit(user_id, True, "ok")
        return True, "ok"

    @staticmethod
    def _uid(msg) -> str:
        return str(getattr(msg, "user_id", None) or "")

    # 向后兼容别名
    def allow(self, adapter: str, msg) -> bool:
        return self.pre_send(msg)[0]
