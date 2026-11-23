"""IM 网关审计日志 —— append-only JSONL + 哈希链防篡改（Python 侧）。

与 Dart 侧 ``frontend/lib/harness/audit_log.dart`` 同一套事件语义，
只写自己的代码（clean-room，未复制任何第三方源码）：
  * append-only JSONL：逐行追加，绝不重写历史；
  * 哈希链：每条事件的 hash 由自身内容与上一条事件的 hash 共同决定，
    任何一行被改写都会让 ``verify_chain()`` 在该行断掉；
  * 脱敏：写入前对 detail 做 ``SecretRedactor.redact``，token / 密码 /
    密钥类值绝不落盘；
  * 容错读取：损坏行直接跳过，不冒充数据；
  * 线程安全：一次追加全程持锁，prevHash 与写盘不交错。

只记「谁 / 哪个适配器 / 什么动作 / 批准还是拒绝 / 凭据何时被用」：
调用方只传元数据（平台、用户标识、动作、决策原因），绝不传消息正文、
工具参数原文与密钥值；事件的 ``ts`` 就是凭据被实际使用的时刻。
审计写盘失败时只记 stderr 警告，绝不抛异常、绝不阻断调用方。

约束：仅标准库；import 阶段不联网、不写文件。
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

# decision 取值（与 Dart 侧 'info' 默认一致，IM 出站再分三态）：
#   allowed —— 风控放行且已下发；denied —— 被风控 / 禁用拦截；
#   failed —— 下发抛错；info —— 一般记录。
DECISION_ALLOWED = "allowed"
DECISION_DENIED = "denied"
DECISION_FAILED = "failed"
DECISION_INFO = "info"

# 出站被拒的原因前缀（risk guard / 网关门控返回的 reason）。
_DENIED_REASONS = (
    "adapter-disabled:",
    "circuit-open",
    "do-not-disturb",
    "rate-limited",
    "global-rate-limited",
    "empty-message",
    "unknown-adapter:",
)


def outbound_decision(ok: bool, reason: str) -> str:
    """按 send_outbound 的 (ok, reason) 映射审计 decision。

    ok 为真 -> allowed；reason 属于门控拒绝 -> denied；其余失败 -> failed。
    """
    if ok:
        return DECISION_ALLOWED
    if str(reason or "").startswith(_DENIED_REASONS):
        return DECISION_DENIED
    return DECISION_FAILED


@dataclass
class AuditEvent:
    """一条审计事件。``ts`` 为 Unix 秒（带小数，保留微秒精度）。"""

    id: str
    category: str
    action: str
    decision: str = DECISION_INFO
    actor: str = "system"
    detail: str = ""
    ts: float = field(default_factory=time.time)
    prev_hash: str = ""
    hash: str = ""

    def compute_hash(self) -> str:
        """按内容与 prev_hash 重算哈希；写入与校验共用同一算法。"""
        material = "|".join((
            self.prev_hash,
            self.category,
            self.action,
            self.decision,
            self.actor,
            self.detail,
            repr(self.ts),
        ))
        return hashlib.sha256(material.encode("utf-8")).hexdigest()

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "id": self.id,
            "category": self.category,
            "action": self.action,
            "decision": self.decision,
            "actor": self.actor,
            "detail": self.detail,
            "ts": self.ts,
        }
        if self.prev_hash:
            out["prevHash"] = self.prev_hash
        if self.hash:
            out["hash"] = self.hash
        return out

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "AuditEvent":
        """容错解析：字段缺失或类型不符时用默认值，坏行由调用方跳过。"""
        raw_ts = raw.get("ts", 0)
        try:
            ts = float(raw_ts)
        except (TypeError, ValueError):
            ts = 0.0
        return cls(
            id=str(raw.get("id") or ""),
            category=str(raw.get("category") or ""),
            action=str(raw.get("action") or ""),
            decision=str(raw.get("decision") or DECISION_INFO),
            actor=str(raw.get("actor") or "system"),
            detail=str(raw.get("detail") or ""),
            ts=ts,
            prev_hash=str(raw.get("prevHash") or raw.get("prev_hash") or ""),
            hash=str(raw.get("hash") or ""),
        )


class SecretRedactor:
    """密钥脱敏：只替换敏感**值**，其余文本原样保留。

    与 Dart 侧 SecretRedactor 同规则：先脱 ``Bearer xxx`` / ``Basic xxx``
    这类认证头，再脱 ``key=value`` / ``"key": "value"`` 形式的敏感键值。
    """

    _auth_scheme = re.compile(
        r"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=\-]+", re.IGNORECASE
    )
    _secret_key_value = re.compile(
        r"""(?<![A-Za-z0-9_])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|pwd|secret|client[_-]?secret|authorization)(["']?\s*[:=]\s*["']?)(?!Bearer\b|Basic\b)([^"'\s,;&}\]]+)""",
        re.IGNORECASE,
    )

    @classmethod
    def redact(cls, text: str) -> str:
        if not text:
            return text
        without_schemes = cls._auth_scheme.sub(
            lambda m: f"{m.group(1)} ***", text
        )
        return cls._secret_key_value.sub(
            lambda m: f"{m.group(1)}{m.group(2)}***", without_schemes
        )


def default_audit_path() -> Path:
    """默认审计文件：与网关 inbox 同目录（TANGRAM_DATA/im_audit.jsonl）。"""
    data_dir = os.environ.get("TANGRAM_DATA") or str(Path.home() / ".tangram")
    return Path(data_dir) / "im_audit.jsonl"


class AuditLog:
    """审计日志门面：追加、查询、统计、校验、导入导出。

    ``append`` 绝不抛异常：落盘失败只写 stderr 警告并返回 None，
    调用方（网关 / 沙箱工具入口）因此永远不会被审计拖垮。
    """

    def __init__(self, path: str | Path | None = None) -> None:
        self.path = Path(path) if path is not None else default_audit_path()
        self._lock = threading.Lock()
        self._seq = 0

    # ---- 追加 ----

    def _next_id(self) -> str:
        self._seq += 1
        return f"audit-{time.time_ns()}-{self._seq}"

    def _last_hash_locked(self) -> str:
        """读当前链尾 hash（损坏行跳过）；文件不存在返回空串。"""
        try:
            events = self._read_events_locked()
        except OSError:
            return ""
        return events[-1].hash if events else ""

    def append(
        self,
        category: str,
        action: str,
        decision: str = DECISION_INFO,
        actor: str = "system",
        detail: str = "",
    ) -> Optional[AuditEvent]:
        """追加一条事件；detail 先脱敏再落盘，自动接入哈希链。

        写盘失败返回 None（并记 stderr 警告），绝不抛异常。
        """
        safe_detail = SecretRedactor.redact(str(detail or ""))
        draft = AuditEvent(
            id=self._next_id(),
            category=str(category),
            action=str(action),
            decision=str(decision or DECISION_INFO),
            actor=str(actor or "system"),
            detail=safe_detail,
            ts=time.time(),
        )
        try:
            with self._lock:
                prev = self._last_hash_locked()
                event = AuditEvent(
                    id=draft.id,
                    category=draft.category,
                    action=draft.action,
                    decision=draft.decision,
                    actor=draft.actor,
                    detail=draft.detail,
                    ts=draft.ts,
                    prev_hash=prev,
                )
                event.hash = event.compute_hash()
                existed = self.path.is_file()
                self.path.parent.mkdir(parents=True, exist_ok=True)
                with self.path.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps(event.to_dict(), ensure_ascii=False) + "\n")
                    fh.flush()
                if not existed:
                    try:
                        os.chmod(self.path, 0o600)
                    except OSError:
                        pass
            return event
        except Exception as exc:  # noqa: BLE001 - 审计失败绝不能阻断调用方
            print(f"[audit] 写入失败（已忽略）：{exc}", file=sys.stderr, flush=True)
            return None

    # ---- 读取（损坏行跳过） ----

    def _read_events_locked(self) -> list[AuditEvent]:
        if not self.path.is_file():
            return []
        try:
            raw = self.path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return []
        out: list[AuditEvent] = []
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                decoded = json.loads(line)
            except ValueError:
                continue  # 半行 / 损坏行不冒充数据
            if not isinstance(decoded, dict):
                continue
            try:
                out.append(AuditEvent.from_dict(decoded))
            except Exception:  # noqa: BLE001 - 单行解析失败即跳过该行
                continue
        return out

    def all(self) -> list[AuditEvent]:
        """读取全部事件（按写入顺序）。损坏行跳过。"""
        with self._lock:
            return self._read_events_locked()

    def query(
        self,
        category: Optional[str] = None,
        since: Optional[float] = None,
        limit: int = 200,
    ) -> list[AuditEvent]:
        """按分类与起始时间过滤，返回**最近** ``limit`` 条（保持时间升序）。"""
        events = self.all()
        filtered = [
            e for e in events
            if (not category or e.category == category)
            and (since is None or e.ts >= since)
        ]
        if limit <= 0:
            return []
        return filtered[-limit:] if len(filtered) > limit else filtered

    def stats(self) -> dict[str, Any]:
        """总数 + 按 category / decision 的计数（只统计真实读回的事件）。"""
        events = self.all()
        by_category: dict[str, int] = {}
        by_decision: dict[str, int] = {}
        for e in events:
            by_category[e.category] = by_category.get(e.category, 0) + 1
            by_decision[e.decision] = by_decision.get(e.decision, 0) + 1
        return {"total": len(events), "by_category": by_category,
                "by_decision": by_decision, "path": str(self.path)}

    # ---- 校验 ----

    def verify_chain(self) -> dict[str, Any]:
        """校验防篡改哈希链。

        逐条按同一算法重算（使用事件自身的 prev_hash）并与落盘 hash 比对，
        同时要求 prev_hash 等于上一条事件的 hash（首条必须为空串）。
        无 hash 的旧事件跳过校验，但计入 ``legacy``。发现不一致立即返回
        ``broken_at``（从 0 开始）。
        """
        events = self.all()
        legacy = 0
        expected_prev = ""
        for i, e in enumerate(events):
            if not e.hash:
                legacy += 1
                expected_prev = e.hash
                continue
            if e.prev_hash != expected_prev:
                return {
                    "ok": False,
                    "total": len(events),
                    "broken_at": i,
                    "legacy": legacy,
                    "reason": (f"第 {i + 1} 条事件的 prevHash 与上一条事件的 hash 不一致"
                               f"（期望 {expected_prev!r}，实际 {e.prev_hash!r}）"),
                }
            if e.compute_hash() != e.hash:
                return {
                    "ok": False,
                    "total": len(events),
                    "broken_at": i,
                    "legacy": legacy,
                    "reason": f"第 {i + 1} 条事件内容与存储 hash 不匹配，疑似被篡改",
                }
            expected_prev = e.hash
        return {
            "ok": True,
            "total": len(events),
            "broken_at": None,
            "legacy": legacy,
            "reason": ("哈希链完整（共 %d 条）" % len(events)
                       if legacy == 0
                       else "哈希链完整（共 %d 条，其中 %d 条旧格式事件无 hash）"
                       % (len(events), legacy)),
        }

    # ---- 导入导出 ----

    def export_jsonl(self) -> str:
        """原样导出 JSONL 文本；文件不存在时返回空串。"""
        with self._lock:
            if not self.path.is_file():
                return ""
            try:
                return self.path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                return ""

    def import_jsonl(self, content: str) -> int:
        """逐行导入：坏行 / 缺关键字段的行跳过，返回成功追加的条数。

        导入前同样脱敏，避免把外部日志里的明文密钥带回磁盘。
        导入的事件重新接入本链（新 id、新 hash），不保留原 hash。
        """
        imported = 0
        for line in str(content or "").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                decoded = json.loads(line)
            except ValueError:
                continue
            if not isinstance(decoded, dict):
                continue
            try:
                event = AuditEvent.from_dict(decoded)
            except Exception:  # noqa: BLE001 - 坏行跳过
                continue
            if not event.id or not event.category or not event.action:
                continue
            if self.append(event.category, event.action, event.decision,
                           event.actor, event.detail) is not None:
                imported += 1
        return imported


def safe_append(log: Optional[AuditLog], **kwargs: Any) -> Optional[AuditEvent]:
    """容错追加：log 为 None 或追加抛错时只记 stderr 警告，绝不抛异常。

    供网关 / 沙箱工具入口调用，保证审计永远不阻断消息发送与沙箱执行。
    """
    if log is None:
        return None
    try:
        return log.append(**kwargs)
    except Exception as exc:  # noqa: BLE001 - 审计对象本身损坏也不阻断调用方
        print(f"[audit] 写入失败（已忽略）：{exc}", file=sys.stderr, flush=True)
        return None
