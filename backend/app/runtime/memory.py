"""真实持久化记忆：对话轮次 + 长期核心记忆 + 词项检索。

所有数据真实落在 ``data_dir`` 下的 JSONL / JSON 文件，重启可恢复。
``nearest_neighbors`` 用字符 bigram TF 余弦做真实相似度计算，不返回
预置示例；``list_core`` / ``core_commit`` 供 Agent 工具 remember_note /
recall_memory 使用（接口与 ``im/serve.py::_exec_agent_tool`` 对齐）。
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

__all__ = ["MemoryEntry", "MemoryStore"]


@dataclass
class MemoryEntry:
    id: str
    role: str                    # user | assistant | system
    text: str
    session_id: str = "default"
    ts: float = 0.0

    def __post_init__(self) -> None:
        if not self.ts:
            self.ts = time.time()


def _grams(text: str) -> list[str]:
    s = "".join(ch for ch in text if not ch.isspace())
    out: list[str] = []
    for i, ch in enumerate(s):
        out.append(ch)
        if i + 1 < len(s):
            out.append(s[i:i + 2])
    return out


def _vector(text: str) -> dict[str, float]:
    tf: dict[str, float] = {}
    for g in _grams(text):
        tf[g] = tf.get(g, 0.0) + 1.0
    norm = math.sqrt(sum(v * v for v in tf.values()))
    if norm:
        for k in tf:
            tf[k] /= norm
    return tf


def _cosine(a: dict[str, float], b: dict[str, float]) -> float:
    if not a or not b:
        return 0.0
    if len(a) > len(b):
        a, b = b, a
    return sum(v * b.get(k, 0.0) for k, v in a.items())


class MemoryStore:
    def __init__(self, data_dir: str | Path) -> None:
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.turns_path = self.data_dir / "memory_turns.jsonl"
        self.core_path = self.data_dir / "core_memory.json"
        self._lock = threading.Lock()

    # ---- 对话轮次 ----
    def add_turn(self, role: str, text: str, session_id: str = "default") -> MemoryEntry:
        """追加一条真实对话轮次（立即落盘，进程退出不丢）。"""
        if not text:
            raise ValueError("记忆文本不能为空")
        digest = hashlib.sha256(
            f"{time.time_ns()}{role}{text}{session_id}".encode("utf-8")
        ).hexdigest()[:16]
        entry = MemoryEntry(id=digest, role=role, text=text,
                            session_id=session_id, ts=time.time())
        with self._lock, self.turns_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(asdict(entry), ensure_ascii=False) + "\n")
            fh.flush()
        return entry

    def load_turns(self, session_id: str | None = None, limit: int = 200) -> list[MemoryEntry]:
        """从磁盘真实读取；损坏行跳过（不编造）。"""
        out: list[MemoryEntry] = []
        if not self.turns_path.is_file():
            return out
        with self._lock:
            lines = self.turns_path.read_text(encoding="utf-8").splitlines()
        for line in lines[-max(limit * 4, limit):]:
            try:
                d = json.loads(line)
                e = MemoryEntry(
                    id=str(d["id"]), role=str(d["role"]), text=str(d["text"]),
                    session_id=str(d.get("session_id", "default")),
                    ts=float(d.get("ts", 0)),
                )
                if session_id is None or e.session_id == session_id:
                    out.append(e)
            except (ValueError, KeyError, TypeError):
                continue
        return out[-limit:]

    def recent(self, session_id: str = "default", k: int = 8) -> list[MemoryEntry]:
        return self.load_turns(session_id=session_id, limit=max(k * 4, 16))[-k:]

    def nearest_neighbors(self, query: str, k: int = 4) -> list[tuple[MemoryEntry, float]]:
        """真实字符 bigram 余弦检索，返回 (entry, score) 且 score > 0。"""
        qv = _vector(query)
        scored: list[tuple[MemoryEntry, float]] = []
        for e in self.load_turns(limit=1000):
            s = _cosine(qv, _vector(e.text))
            if s > 0:
                # 轻微的时间衰减，仍是真实计算
                age_h = max(0.0, (time.time() - e.ts) / 3600.0)
                scored.append((e, s / (1.0 + age_h / 720.0)))
        scored.sort(key=lambda p: (-p[1], p[0].ts))
        return scored[:max(1, k)]

    def recall_text(self, query: str, k: int = 4) -> str:
        lines = [f"- {e.role}: {e.text}" for e, _ in self.nearest_neighbors(query, k)]
        return "\n".join(lines)

    # ---- 长期核心记忆 ----
    def list_core(self) -> list[tuple[str, str]]:
        """返回 [(id, text)]，与 ``_exec_agent_tool`` 的解包一致。"""
        data = self._read_core()
        return [(str(r.get("id", "")), str(r.get("text", ""))) for r in data]

    def core_commit(self, text: str) -> str:
        """写入一条真实长期记忆，返回 id。"""
        if not text.strip():
            raise ValueError("核心记忆文本不能为空")
        with self._lock:
            rows = self._read_core()
            cid = hashlib.sha256(
                f"{time.time_ns()}{text}".encode("utf-8")
            ).hexdigest()[:16]
            rows.append({"id": cid, "text": text.strip(), "ts": time.time()})
            self._write_core(rows)
        return cid

    def core_remove(self, cid: str) -> bool:
        with self._lock:
            rows = self._read_core()
            kept = [r for r in rows if r.get("id") != cid]
            if len(kept) == len(rows):
                return False
            self._write_core(kept)
            return True

    def clear(self) -> None:
        """只清本 data_dir 的真实文件，不动用户其他数据。"""
        with self._lock:
            self.turns_path.unlink(missing_ok=True)
            self.core_path.unlink(missing_ok=True)

    def stats(self) -> dict:
        return {
            "data_dir": str(self.data_dir.resolve()),
            "turns": len(self.load_turns(limit=100000)),
            "core": len(self.list_core()),
            "turns_bytes": self.turns_path.stat().st_size if self.turns_path.is_file() else 0,
        }

    def _read_core(self) -> list[dict]:
        if not self.core_path.is_file():
            return []
        try:
            data = json.loads(self.core_path.read_text(encoding="utf-8"))
            return data.get("notes", []) if isinstance(data, dict) else []
        except (ValueError, OSError):
            return []

    def _write_core(self, rows: Iterable[dict]) -> None:
        tmp = self.core_path.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps({"schema_version": "1.0.0", "notes": list(rows)},
                       ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        os.replace(tmp, self.core_path)
