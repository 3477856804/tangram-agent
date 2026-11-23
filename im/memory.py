"""记忆分三层（Python 侧，Rakazo 机制 #8 的 clean-room 实现，仅标准库）。

只借鉴设计思路，未复制任何第三方源码：

* 短期：会话摘要（session summary）——每会话只存要点（单条 ≤120 字，
  每会话最多 20 条），内存 + 可选落盘；绝不存整段对话全文。
* 长期：显式保存的事实库（fact store）——只有用户或 agent 显式调用
  ``save_fact`` 才写入；支持按 id / 文本查、按来源 / 标签过滤；落盘
  JSON 文件，权限 0600。
* 共享：跨 bot / 跨群聊的共享记忆——scope 分 private / shared；共享须
  显式 opt-in（``save_fact(shared=True)``），默认 private；共享事实带
  来源 bot 与共享时间。

开关：learn（是否从对话学习进摘要，默认开）、remember（是否允许写入
长期事实库，默认开但只接受显式保存）。forget 按 id 或文本删事实，
删后不可恢复，并记审计事件。

凭据/密钥类内容绝不进记忆：保存前用 ``im.audit.SecretRedactor`` 脱敏
比对，命中则拒绝保存并记原因；写盘失败只警告不阻断调用方。
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from .audit import AuditLog, SecretRedactor, safe_append

__all__ = [
    "Fact",
    "MemoryStore",
    "SCOPE_PRIVATE",
    "SCOPE_SHARED",
    "contains_secret",
    "default_memory_path",
]

SCOPE_PRIVATE = "private"
SCOPE_SHARED = "shared"

# 单条摘要要点上限（字符）；会话摘要只存要点，不存全文。
_MAX_POINT_CHARS = 120
_MAX_POINTS_PER_SESSION = 20
_MAX_FACT_CHARS = 2000
_MAX_FACTS = 5000

# 裸露的高熵令牌前缀（SecretRedactor 的 key=value / Bearer 规则覆盖不到
# 的形态，如直接粘贴的一串 sk-...）。命中即视为密钥内容，拒绝保存。
_BARE_TOKEN = re.compile(
    r"\b(?:sk-[A-Za-z0-9-]{8,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|"
    r"xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|"
    r"glpat-[A-Za-z0-9_-]{10,})\b"
)


def contains_secret(text: str) -> bool:
    """文本是否含凭据/密钥类内容：脱敏规则命中，或裸露令牌前缀命中。"""
    if not text:
        return False
    if SecretRedactor.redact(text) != text:
        return True
    return bool(_BARE_TOKEN.search(text))


def default_memory_path() -> Path:
    """默认记忆文件：与网关 inbox / 审计日志同目录（TANGRAM_DATA/）。"""
    data_dir = os.environ.get("TANGRAM_DATA") or str(Path.home() / ".tangram")
    return Path(data_dir) / "memory_layers.json"


@dataclass
class Fact:
    """一条长期事实：只由显式保存产生，可删改，可共享。"""

    id: str
    text: str
    source: str = ""
    scope: str = SCOPE_PRIVATE
    tags: list[str] = field(default_factory=list)
    created_at: float = 0.0
    shared_by: str = ""
    shared_at: float = 0.0

    def __post_init__(self) -> None:
        if not self.created_at:
            self.created_at = time.time()
        if self.scope not in (SCOPE_PRIVATE, SCOPE_SHARED):
            self.scope = SCOPE_PRIVATE

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "id": self.id,
            "text": self.text,
            "source": self.source,
            "scope": self.scope,
            "tags": list(self.tags),
            "created_at": self.created_at,
        }
        if self.shared_by:
            out["shared_by"] = self.shared_by
        if self.shared_at:
            out["shared_at"] = self.shared_at
        return out

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "Fact":
        try:
            created = float(raw.get("created_at") or 0)
        except (TypeError, ValueError):
            created = 0.0
        try:
            shared_at = float(raw.get("shared_at") or 0)
        except (TypeError, ValueError):
            shared_at = 0.0
        tags = raw.get("tags")
        return cls(
            id=str(raw.get("id") or ""),
            text=str(raw.get("text") or ""),
            source=str(raw.get("source") or ""),
            scope=str(raw.get("scope") or SCOPE_PRIVATE),
            tags=[str(t) for t in tags] if isinstance(tags, list) else [],
            created_at=created,
            shared_by=str(raw.get("shared_by") or ""),
            shared_at=shared_at,
        )


class MemoryStore:
    """三层记忆门面：会话摘要 + 显式事实库 + 共享记忆。

    ``persist=False`` 时只放内存（测试 / 临时实例用）；默认落盘。
    所有公开方法绝不抛异常到调用方：写盘失败只记 stderr 警告。
    """

    def __init__(self, path: str | Path | None = None, *,
                 persist: bool = True,
                 audit: Optional[AuditLog] = None,
                 bot_id: str = "tangram") -> None:
        self.path = Path(path) if path is not None else default_memory_path()
        self.persist = persist
        self.audit = audit
        self.bot_id = bot_id or "tangram"
        self._lock = threading.RLock()
        self._loaded = False
        self._seq = 0
        self._learn = True
        self._remember = True
        self._facts: list[Fact] = []
        self._sessions: dict[str, dict[str, Any]] = {}

    # ---- 开关 ----

    @property
    def learn(self) -> bool:
        with self._lock:
            self._ensure_loaded_locked()
            return self._learn

    @property
    def remember(self) -> bool:
        with self._lock:
            self._ensure_loaded_locked()
            return self._remember

    def set_learn(self, value: bool) -> None:
        with self._lock:
            self._ensure_loaded_locked()
            self._learn = bool(value)
            self._save_locked()

    def set_remember(self, value: bool) -> None:
        with self._lock:
            self._ensure_loaded_locked()
            self._remember = bool(value)
            self._save_locked()

    # ---- 持久化（惰性加载、原子写、0600、失败只警告） ----

    def _ensure_loaded_locked(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        if not self.persist or not self.path.is_file():
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, ValueError) as exc:
            # 损坏文件不冒充数据：从空态开始，并警告。
            print(f"[memory] 记忆文件损坏，已从空态开始：{exc}",
                  file=sys.stderr, flush=True)
            return
        if not isinstance(raw, dict):
            return
        if isinstance(raw.get("learn"), bool):
            self._learn = raw["learn"]
        if isinstance(raw.get("remember"), bool):
            self._remember = raw["remember"]
        facts = raw.get("facts")
        if isinstance(facts, list):
            for item in facts:
                if not isinstance(item, dict):
                    continue
                try:
                    fact = Fact.from_dict(item)
                except Exception:  # noqa: BLE001 - 坏行跳过
                    continue
                if fact.id and fact.text:
                    self._facts.append(fact)
        sessions = raw.get("sessions")
        if isinstance(sessions, dict):
            for key, value in sessions.items():
                if not isinstance(value, dict):
                    continue
                points = value.get("points")
                if not isinstance(points, list):
                    continue
                self._sessions[str(key)] = {
                    "points": [str(p) for p in points][: _MAX_POINTS_PER_SESSION],
                    "turns": int(value.get("turns") or 0),
                    "updated_at": float(value.get("updated_at") or 0),
                }

    def _save_locked(self) -> bool:
        """原子写盘（tmp + rename，0600）；失败只警告，返回 False。"""
        if not self.persist:
            return True
        doc = {
            "version": 1,
            "learn": self._learn,
            "remember": self._remember,
            "facts": [f.to_dict() for f in self._facts],
            "sessions": self._sessions,
            "updated_at": time.time(),
        }
        tmp = self.path.with_name(self.path.name + ".tmp")
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(json.dumps(doc, ensure_ascii=False))
                    fh.flush()
                    os.fsync(fh.fileno())
            except Exception:
                try:
                    tmp.unlink(missing_ok=True)
                except OSError:
                    pass
                raise
            os.replace(tmp, self.path)
            try:
                os.chmod(self.path, 0o600)
            except OSError:
                pass
            return True
        except Exception as exc:  # noqa: BLE001 - 写盘失败绝不阻断调用方
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
            print(f"[memory] 写盘失败（已忽略）：{exc}", file=sys.stderr, flush=True)
            return False

    # ---- 短期：会话摘要 ----

    def learn_turn(self, session_key: str, role: str, text: str) -> bool:
        """从一轮对话学习进会话摘要（只存要点，不存全文）。

        learn 开关关闭时直接返回 False；要点超过 120 字截断；每会话
        最多保留 20 条要点（最旧的先丢）；连续重复要点不重复记。
        """
        key = (session_key or "default").strip() or "default"
        point_src = (text or "").strip()
        if not point_src:
            return False
        with self._lock:
            self._ensure_loaded_locked()
            if not self._learn:
                return False
            point = point_src.replace("\n", " ").strip()
            if len(point) > _MAX_POINT_CHARS:
                point = point[:_MAX_POINT_CHARS] + "…"
            point = f"{role or 'user'}: {point}"
            session = self._sessions.setdefault(
                key, {"points": [], "turns": 0, "updated_at": 0.0})
            points = session["points"]
            if points and points[-1] == point:
                return False
            points.append(point)
            del points[: max(0, len(points) - _MAX_POINTS_PER_SESSION)]
            session["turns"] = int(session.get("turns") or 0) + 1
            session["updated_at"] = time.time()
            self._save_locked()
            return True

    def session_summary(self, session_key: str) -> list[str]:
        """取某会话的摘要要点（只读副本）。"""
        key = (session_key or "default").strip() or "default"
        with self._lock:
            self._ensure_loaded_locked()
            session = self._sessions.get(key)
            if not session:
                return []
            return list(session.get("points") or [])

    def clear_session(self, session_key: str) -> bool:
        """清空某会话的摘要（要点删除，不可恢复）。"""
        key = (session_key or "default").strip() or "default"
        with self._lock:
            self._ensure_loaded_locked()
            if key not in self._sessions:
                return False
            del self._sessions[key]
            self._save_locked()
            return True

    # ---- 长期：显式事实库 ----

    def _next_id_locked(self) -> str:
        self._seq += 1
        return f"fact-{time.time_ns()}-{self._seq}"

    def save_fact(self, text: str, *, source: str = "",
                  tags: Optional[list[str]] = None,
                  scope: str = SCOPE_PRIVATE, shared: bool = False,
                  bot_id: str = "") -> dict[str, Any]:
        """显式保存一条长期事实。

        只有显式调用才会写进长期记忆；对话内容绝不会自动进事实库。
        ``shared=True`` 或 ``scope="shared"`` 才是共享 opt-in，默认一律
        private。密钥类内容命中即拒绝保存。返回 ``{"ok", "fact", "reason"}``。
        """
        content = (text or "").strip()
        with self._lock:
            self._ensure_loaded_locked()
            if not self._remember:
                self._audit_locked("fact_save_rejected", "denied",
                                   "remember-off")
                return {"ok": False, "fact": None, "reason": "remember-off"}
            if not content:
                return {"ok": False, "fact": None, "reason": "empty"}
            if len(content) > _MAX_FACT_CHARS:
                return {"ok": False, "fact": None, "reason": "too-long"}
            if contains_secret(content):
                self._audit_locked("fact_save_rejected", "denied",
                                   "secret-rejected")
                return {"ok": False, "fact": None, "reason": "secret-rejected"}
            if len(self._facts) >= _MAX_FACTS:
                return {"ok": False, "fact": None, "reason": "fact-store-full"}
            final_scope = (SCOPE_SHARED
                         if (shared or scope == SCOPE_SHARED)
                         else SCOPE_PRIVATE)
            fact = Fact(
                id=self._next_id_locked(),
                text=content,
                source=(source or "").strip(),
                scope=final_scope,
                tags=[str(t).strip() for t in (tags or []) if str(t).strip()],
                shared_by=(bot_id or self.bot_id) if final_scope == SCOPE_SHARED else "",
                shared_at=time.time() if final_scope == SCOPE_SHARED else 0.0,
            )
            self._facts.append(fact)
            self._save_locked()
            self._audit_locked("fact_save", "info",
                               f"id={fact.id} scope={fact.scope} "
                               f"source={fact.source or '-'}")
            return {"ok": True, "fact": fact, "reason": "ok"}

    def get_fact(self, fact_id: str) -> Optional[Fact]:
        with self._lock:
            self._ensure_loaded_locked()
            for fact in self._facts:
                if fact.id == fact_id:
                    return fact
            return None

    def list_facts(self, *, source: Optional[str] = None,
                   tags: Optional[list[str]] = None,
                   scope: Optional[str] = None,
                   include_shared: bool = True) -> list[Fact]:
        """按来源 / 标签 / scope 过滤列出事实（按保存顺序）。"""
        with self._lock:
            self._ensure_loaded_locked()
            out: list[Fact] = []
            wanted_tags = {str(t) for t in (tags or []) if str(t)}
            for fact in self._facts:
                if not include_shared and fact.scope == SCOPE_SHARED:
                    continue
                if scope is not None and fact.scope != scope:
                    continue
                if source is not None and fact.source != source:
                    continue
                if wanted_tags and not wanted_tags.intersection(fact.tags):
                    continue
                out.append(fact)
            return out

    def search_facts(self, query: str) -> list[Fact]:
        """按 id 或文本子串查事实（大小写不敏感，CJK 原样比对）。"""
        q = (query or "").strip()
        if not q:
            return []
        lowered = q.lower()
        with self._lock:
            self._ensure_loaded_locked()
            return [f for f in self._facts
                    if lowered in f.text.lower() or q == f.id]

    def forget_fact(self, query: str) -> dict[str, Any]:
        """按 id 或文本删事实，删后不可恢复，并记审计事件。

        先按 id 精确匹配；否则按文本子串匹配（可能删多条）。
        返回 ``{"ok", "deleted", "ids"}``。
        """
        q = (query or "").strip()
        if not q:
            return {"ok": False, "deleted": 0, "ids": []}
        with self._lock:
            self._ensure_loaded_locked()
            doomed: list[Fact] = []
            exact = self.get_fact(q)
            if exact is not None:
                doomed = [exact]
            else:
                lowered = q.lower()
                doomed = [f for f in self._facts if lowered in f.text.lower()]
            if not doomed:
                return {"ok": False, "deleted": 0, "ids": []}
            ids = {f.id for f in doomed}
            self._facts = [f for f in self._facts if f.id not in ids]
            self._save_locked()
            self._audit_locked("fact_forget", "info",
                               f"deleted={len(doomed)} ids={','.join(sorted(ids))}")
            return {"ok": True, "deleted": len(doomed),
                    "ids": sorted(ids)}

    # ---- 审计（只记元数据，绝不记事实正文） ----

    def _audit_locked(self, action: str, decision: str, detail: str) -> None:
        if self.audit is None:
            return
        safe_append(self.audit, category="memory", action=action,
                    decision=decision, actor=self.bot_id, detail=detail)

    # ---- 统计 ----

    def stats(self) -> dict[str, Any]:
        with self._lock:
            self._ensure_loaded_locked()
            return {
                "facts": len(self._facts),
                "shared_facts": sum(1 for f in self._facts
                                    if f.scope == SCOPE_SHARED),
                "sessions": len(self._sessions),
                "points": sum(len(s.get("points") or [])
                              for s in self._sessions.values()),
                "learn": self._learn,
                "remember": self._remember,
                "path": str(self.path),
            }
