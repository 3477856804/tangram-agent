"""分级审批 —— Ask / Auto / Deny（Python 侧，IM 网关 + 沙箱工具入口）。

对照 Rakazo 审批三档的产品语义，端侧的真实落地（clean-room，未复制任何
第三方源码）：
  * ask（默认）：动作不执行，先记一条待审批，调用方收到 needs-approval；
  * auto：放行并记审计；只有用户显式确认（confirmed=True）才能设为 auto，
    设置时记录 actor 与时间；
  * deny：直接拒绝并记审计。
  * 强制拒绝：破坏性 shell（rm -rf / mkfs / dd 等）无视策略一律 deny，
    与 Dart 侧 PermissionPolicy 的 default-deny-destructive-shell 同规则。

批准是一次性的：用户对某条待审批点「批准」后，只放行下一次同一
（分类、键、对象）的动作（10 分钟内有效，过期作废；重启后失效），
而不是把该分类永久放开；想长期放行必须显式把策略设为 auto。

策略落盘 TANGRAM_DATA/approval_policy.json（0600），待审批落盘
TANGRAM_DATA/approval_pending.json（0600）。写盘失败只警告，绝不阻断
调用方；读盘损坏时按空策略处理，不冒充数据。

约束：仅标准库；import 阶段不联网、不写文件。
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional

LEVEL_ASK = "ask"
LEVEL_AUTO = "auto"
LEVEL_DENY = "deny"
LEVELS = (LEVEL_ASK, LEVEL_AUTO, LEVEL_DENY)
DEFAULT_LEVEL = LEVEL_ASK

CATEGORY_OUTBOUND = "outbound_send"
CATEGORY_SANDBOX = "sandbox_exec"
CATEGORIES = (CATEGORY_OUTBOUND, CATEGORY_SANDBOX)

# 一次性批准的有效期（秒）。
APPROVAL_TTL_S = 600

# 强制拒绝的破坏性命令模式（与 Dart 侧 security_policy.dart 的
# default-deny-destructive-shell 同规则，策略改不掉这条）。
_FORCED_DENY_COMMAND = re.compile(
    r"\brm\s+-(?:[a-zA-Z]*[rR][a-zA-Z]*[fF]|[a-zA-Z]*[fF][a-zA-Z]*[rR])"
    r"|\bmkfs\b"
    r"|\bdd\s+if=",
)


def _data_dir() -> Path:
    return Path(os.environ.get("TANGRAM_DATA") or str(Path.home() / ".tangram"))


def default_policy_path() -> Path:
    return _data_dir() / "approval_policy.json"


def default_pending_path() -> Path:
    return _data_dir() / "approval_pending.json"


def _read_json(path: Path) -> dict[str, Any]:
    """容错读 JSON：不存在 / 损坏 / 非对象一律返回空 dict。"""
    try:
        if not path.is_file():
            return {}
        decoded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError):
        return {}
    return decoded if isinstance(decoded, dict) else {}


def _write_json(path: Path, data: dict[str, Any]) -> bool:
    """原子写 JSON（临时文件 + 改名，0600）；失败只警告，返回是否成功。"""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        tmp.rename(path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return True
    except Exception as exc:  # noqa: BLE001 - 写盘失败绝不阻断调用方
        print(f"[approval] 写入失败（已忽略）：{exc}", file=sys.stderr, flush=True)
        return False


class ApprovalPolicy:
    """分级审批策略 + 待审批记录（线程安全，内存态为准、落盘为辅）。

    ``decide`` 永远不抛异常；策略文件缺失 / 损坏时默认 ask。
    一次性批准只存在内存里（重启后失效），待审批列表会落盘。
    """

    def __init__(
        self,
        policy_path: str | Path | None = None,
        pending_path: str | Path | None = None,
    ) -> None:
        self.policy_path = Path(policy_path) if policy_path is not None else default_policy_path()
        self.pending_path = Path(pending_path) if pending_path is not None else default_pending_path()
        self._lock = threading.Lock()
        self._seq = 0
        self._levels: dict[str, dict[str, dict[str, Any]]] = {}
        self._pending: list[dict[str, Any]] = []
        self._approved: list[dict[str, Any]] = []
        self._load_locked()

    # ---- 持久化 ----

    def _load_locked(self) -> None:
        raw = _read_json(self.policy_path)
        levels: dict[str, dict[str, dict[str, Any]]] = {}
        for category, entries in (raw.get("levels") or {}).items():
            if not isinstance(entries, dict):
                continue
            for key, item in entries.items():
                if not isinstance(item, dict):
                    continue
                level = str(item.get("level") or "")
                if level not in LEVELS:
                    continue
                levels.setdefault(str(category), {})[str(key)] = {
                    "level": level,
                    "set_by": str(item.get("set_by") or ""),
                    "set_at": float(item.get("set_at") or 0),
                }
        self._levels = levels
        pending = _read_json(self.pending_path).get("pending") or []
        self._pending = [p for p in pending if isinstance(p, dict) and p.get("id")]

    def _save_locked(self) -> None:
        _write_json(self.policy_path, {"levels": self._levels})
        _write_json(self.pending_path, {"pending": self._pending})

    # ---- 策略 ----

    def decide(self, category: str, key: str = "") -> str:
        """返回某分类的审批级别；未知分类 / 未设置一律 ask。"""
        with self._lock:
            item = self._levels.get(str(category), {}).get(str(key))
            if item is None:
                item = self._levels.get(str(category), {}).get("")
            if item is None:
                return DEFAULT_LEVEL
            level = str(item.get("level") or "")
            return level if level in LEVELS else DEFAULT_LEVEL

    def decide_sandbox(self, command: str) -> str:
        """沙箱命令的判定：破坏性命令强制 deny，其余走 sandbox_exec 策略。"""
        if _FORCED_DENY_COMMAND.search(str(command or "")):
            return LEVEL_DENY
        return self.decide(CATEGORY_SANDBOX, "")

    def set_level(
        self,
        category: str,
        key: str = "",
        level: str = LEVEL_ASK,
        actor: str = "user",
        confirmed: bool = False,
    ) -> dict[str, Any]:
        """设置某分类的级别。设为 auto 必须 confirmed=True（用户显式确认），
        否则返回错误且不改策略；ask / deny 不要求确认。"""
        category = str(category)
        key = str(key)
        level = str(level or "")
        if category not in CATEGORIES:
            return {"ok": False, "error": f"未知审批分类：{category}"}
        if level not in LEVELS:
            return {"ok": False, "error": f"未知审批级别：{level}"}
        if level == LEVEL_AUTO and not confirmed:
            return {
                "ok": False,
                "error": "设为 auto（不再询问）需要用户显式确认：confirmed=true",
            }
        with self._lock:
            self._levels.setdefault(category, {})[key] = {
                "level": level,
                "set_by": str(actor or "user"),
                "set_at": time.time(),
            }
            self._save_locked()
            return {"ok": True, "category": category, "key": key, "level": level}

    def get_policy(self) -> dict[str, Any]:
        """返回当前策略快照（只含级别与设置记录，不含任何密钥）。"""
        with self._lock:
            return {"ok": True, "levels": json.loads(json.dumps(self._levels))}

    # ---- 待审批 ----

    def request_approval(
        self,
        category: str,
        key: str = "",
        subject: str = "",
        detail: str = "",
        actor: str = "system",
    ) -> dict[str, Any]:
        """记一条待审批并返回它（detail 只放元数据，绝不放消息正文与密钥）。"""
        from .audit import SecretRedactor

        with self._lock:
            self._seq += 1
            entry: dict[str, Any] = {
                "id": f"appr-{time.time_ns()}-{self._seq}",
                "category": str(category),
                "key": str(key),
                "subject": str(subject),
                "detail": SecretRedactor.redact(str(detail or ""))[:500],
                "actor": str(actor or "system"),
                "created_at": time.time(),
                "status": "pending",
            }
            self._pending.append(entry)
            if len(self._pending) > 200:
                self._pending = self._pending[-200:]
            self._save_locked()
            return dict(entry)

    def list_pending(self) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(p) for p in self._pending]

    def resolve_approval(
        self, approval_id: str, allow: bool, actor: str = "user"
    ) -> Optional[dict[str, Any]]:
        """处理一条待审批：allow 为真时记一枚一次性批准（10 分钟内、同一
        分类/键/对象只放行一次），否则直接拒绝。处理后该记录从待审批列表
        移除，返回原记录；不存在返回 None。"""
        with self._lock:
            for i, entry in enumerate(self._pending):
                if entry.get("id") == approval_id:
                    resolved = dict(entry)
                    resolved["status"] = "approved" if allow else "rejected"
                    resolved["resolved_by"] = str(actor or "user")
                    resolved["resolved_at"] = time.time()
                    del self._pending[i]
                    if allow:
                        self._approved.append({
                            "category": resolved["category"],
                            "key": resolved["key"],
                            "subject": resolved["subject"],
                            "approved_at": resolved["resolved_at"],
                            "expires_at": resolved["resolved_at"] + APPROVAL_TTL_S,
                        })
                    self._save_locked()
                    return resolved
        return None

    def has_approval(self, category: str, key: str = "", subject: str = "") -> bool:
        """查看是否有一枚未过期的一次性批准（只看不消耗，供出站预检用）。"""
        now = time.time()
        with self._lock:
            return any(
                t.get("category") == str(category)
                and t.get("key") == str(key)
                and t.get("subject") == str(subject)
                and float(t.get("expires_at") or 0) > now
                for t in self._approved
            )

    def consume_approval(self, category: str, key: str = "", subject: str = "") -> bool:
        """消耗一枚一次性批准：同一分类/键/对象、未过期的才算数，命中即删除。
        返回是否放行。"""
        now = time.time()
        with self._lock:
            self._approved = [
                t for t in self._approved if float(t.get("expires_at") or 0) > now
            ]
            for i, token in enumerate(self._approved):
                if (
                    token.get("category") == str(category)
                    and token.get("key") == str(key)
                    and token.get("subject") == str(subject)
                ):
                    del self._approved[i]
                    return True
        return False
