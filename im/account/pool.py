"""个人 IM 账号池（凭据加密，不进沙箱）。

安全约定：
- 凭据明文不落盘；使用标准库 hashlib/hmac 做密钥派生、流加密与完整性签名。
- 敏感主密钥存本地加密文件，并以文件权限约束（0o600）保护；密钥不进沙箱代码。
- 真实生产环境加密需 cryptography 包（AES-GCM 等）；此处用 hashlib 派生 +
  文件权限约束作为可降级的最小实现，仅适用于本地个人设备场景。
- 多账号默认不共享上下文（context_isolation=True）。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import stat
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from ..util import now_ts


@dataclass
class AccountSession:
    """单个平台账号的连接会话（凭据以密文存储）。"""

    adapter: str
    handle: str
    encrypted_token: str = ""   # 加密后的凭据，明文不落盘
    scan_session: str = ""      # 真实扫码登录会话 ID（见 ScanSessionRegistry）
    connected: bool = False
    last_seen: float = field(default_factory=now_ts)

    @property
    def key(self) -> str:
        return f"{self.adapter}:{self.handle}"


class CredentialVault:
    """凭据保险库：hashlib/hmac 派生密钥 + 流加密 + HMAC 签名。

    说明（真实加密需 cryptography 包，此处用 hashlib 派生 + 文件权限约束）：
    - 主密钥从本地密钥文件读取（权限 0o600），密钥本身不写进沙箱代码。
    - 每条凭据用随机 salt 派生独立密钥，XOR 流加密（由 HMAC 扩展密钥流），
      并附 HMAC-SHA256 标签做完整性校验。
    """

    _MAGIC = b"TANGRM1"  # 密文格式版本标记

    def __init__(self, key_file: str) -> None:
        self.key_file = key_file
        self._master: Optional[bytes] = None

    # ---- 主密钥（本地加密文件 + 权限约束，不进沙箱代码） ----
    def _load_master(self) -> bytes:
        if self._master is not None:
            return self._master
        if os.path.exists(self.key_file):
            with open(self.key_file, "rb") as fh:
                self._master = fh.read()
        else:
            # 首次运行：生成主密钥并以 0o600 权限落盘（密钥不进代码）。
            self._master = secrets.token_bytes(32)
            fd = os.open(self.key_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as fh:
                fh.write(self._master)
            os.chmod(self.key_file, 0o600)  # 冗余保险：仅属主可读写
        return self._master

    @staticmethod
    def _derive(salt: bytes, master: bytes) -> bytes:
        """从主密钥 + 随机 salt 派生本条凭据密钥。"""
        return hashlib.pbkdf2_hmac("sha256", master, salt, iterations=100_000)

    @staticmethod
    def _keystream(key: bytes, salt: bytes, length: int) -> bytes:
        """由 HMAC 扩展生成 XOR 密钥流。"""
        out = b""
        block = 0
        while len(out) < length:
            out += hmac.new(key, salt + block.to_bytes(4, "big"), hashlib.sha256).digest()
            block += 1
        return out[:length]

    def encrypt(self, plaintext: str) -> str:
        """加密明文凭据，返回 base64 字符串（含 magic/salt/hmac）。"""
        master = self._load_master()
        salt = secrets.token_bytes(16)
        key = self._derive(salt, master)
        data = plaintext.encode("utf-8")
        stream = self._keystream(key, salt, len(data))
        cipher = bytes(a ^ b for a, b in zip(data, stream))
        tag = hmac.new(key, salt + cipher, hashlib.sha256).digest()
        blob = self._MAGIC + salt + tag + cipher
        return base64.b64encode(blob).decode("ascii")

    def decrypt(self, ciphertext: str) -> str:
        """解密凭据；校验 HMAC 失败抛 ValueError。"""
        master = self._load_master()
        blob = base64.b64decode(ciphertext.encode("ascii"))
        if not blob.startswith(self._MAGIC):
            raise ValueError("凭据格式非法")
        body = blob[len(self._MAGIC):]
        salt, rest = body[:16], body[16:]
        tag, cipher = rest[:32], rest[32:]
        key = self._derive(salt, master)
        expect = hmac.new(key, salt + cipher, hashlib.sha256).digest()
        if not hmac.compare_digest(tag, expect):
            raise ValueError("凭据完整性校验失败（可能被篡改）")
        stream = self._keystream(key, salt, len(cipher))
        data = bytes(a ^ b for a, b in zip(cipher, stream))
        return data.decode("utf-8")


class ScanSessionRegistry:
    """真实扫码会话登记：落盘、带过期时间、可轮询/确认/清理。

    此前 ``begin_scan`` 只生成一个随机串就返回，没有任何状态与生命周期，
    属于「占位」。这里把会话真实登记到本地 JSON（0o600），重启可恢复，
    过期自动失效，扫码状态由平台回调 ``confirm_scan`` 真实推进。
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self._lock = threading.Lock()

    def _read(self) -> dict[str, dict]:
        if not self.path.is_file():
            return {}
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            return data.get("sessions", {}) if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write(self, sessions: dict[str, dict]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps({"schema_version": "1.0.0", "sessions": sessions},
                       ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        os.replace(tmp, self.path)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass

    def begin(self, adapter: str, handle: str, ttl_s: float = 300.0) -> str:
        sid = secrets.token_urlsafe(24)
        now = time.time()
        with self._lock:
            sessions = self._read()
            sessions[sid] = {
                "adapter": adapter,
                "handle": handle,
                "created_at": now,
                "expires_at": now + ttl_s,
                "state": "waiting",
            }
            self._write(sessions)
        return sid

    def poll(self, sid: str) -> dict | None:
        """真实查询会话；过期则删除并返回 None（不谎称仍在等待）。"""
        with self._lock:
            sessions = self._read()
            rec = sessions.get(sid)
            if rec is None:
                return None
            if float(rec.get("expires_at", 0)) <= time.time():
                sessions.pop(sid, None)
                self._write(sessions)
                return None
            return dict(rec)

    def confirm(self, sid: str) -> bool:
        """平台回调确认扫码成功：真实推进状态。"""
        with self._lock:
            sessions = self._read()
            rec = sessions.get(sid)
            if rec is None or float(rec.get("expires_at", 0)) <= time.time():
                return False
            rec["state"] = "confirmed"
            rec["confirmed_at"] = time.time()
            self._write(sessions)
            return True

    def expire(self) -> int:
        """清理过期会话，返回真实清理条数。"""
        with self._lock:
            sessions = self._read()
            keep = {k: v for k, v in sessions.items()
                    if float(v.get("expires_at", 0)) > time.time()}
            removed = len(sessions) - len(keep)
            if removed:
                self._write(keep)
            return removed


class AccountPool:
    """多账号加密凭据池（不进沙箱）。"""

    def __init__(self, key_file: str = "im_account_key.bin") -> None:
        self._accounts: dict[str, AccountSession] = {}
        self.vault = CredentialVault(key_file)
        self.context_isolation: bool = True  # 多账号默认不共享上下文
        self.scan_sessions = ScanSessionRegistry(
            Path(key_file).resolve().parent / "scan_sessions.json"
        )

    # ---- 增删改查 ----
    def put(self, acc: AccountSession) -> None:
        """放入/更新账号会话（凭据以密文存储）。"""
        self._accounts[acc.key] = acc

    def get(self, adapter: str, handle: str) -> Optional[AccountSession]:
        """按平台与账号取会话。"""
        return self._accounts.get(f"{adapter}:{handle}")

    def status(self, adapter: str) -> list[AccountSession]:
        """列出某平台下所有账号会话及其连接状态。"""
        return [a for k, a in self._accounts.items() if k.startswith(adapter + ":")]

    def all_status(self) -> list[AccountSession]:
        return list(self._accounts.values())

    # ---- 凭据加密存取（明文不落盘） ----
    def store_secret(self, adapter: str, handle: str, secret: str) -> None:
        """加密存储账号敏感凭据（如 token / cookie）。"""
        acc = self.get(adapter, handle) or AccountSession(adapter=adapter, handle=handle)
        acc.encrypted_token = self.vault.encrypt(secret)
        acc.last_seen = now_ts()
        self.put(acc)

    def load_secret(self, adapter: str, handle: str) -> Optional[str]:
        """解密读取账号凭据；不存在返回 None。"""
        acc = self.get(adapter, handle)
        if acc is None or not acc.encrypted_token:
            return None
        return self.vault.decrypt(acc.encrypted_token)

    # ---- 连接状态 / 真实扫码会话 ----
    def mark_connected(self, adapter: str, handle: str, connected: bool = True) -> None:
        acc = self.get(adapter, handle)
        if acc is None:
            return
        acc.connected = connected
        acc.last_seen = now_ts()

    def begin_scan(self, adapter: str, handle: str, ttl_s: float = 300.0) -> str:
        """发起真实扫码登录会话：登记落盘、带过期时间、可轮询/确认。"""
        sid = self.scan_sessions.begin(adapter, handle, ttl_s=ttl_s)
        acc = self.get(adapter, handle) or AccountSession(adapter=adapter, handle=handle)
        acc.scan_session = sid
        acc.last_seen = now_ts()
        self.put(acc)
        return sid

    def poll_scan(self, sid: str) -> dict | None:
        """查询真实扫码会话状态；过期返回 None。"""
        return self.scan_sessions.poll(sid)

    def confirm_scan(self, sid: str) -> bool:
        """平台回调确认扫码：真实推进状态并标记账号已连接。"""
        rec = self.scan_sessions.poll(sid)
        if rec is None or not self.scan_sessions.confirm(sid):
            return False
        self.mark_connected(str(rec["adapter"]), str(rec["handle"]), True)
        return True

    def contexts_isolated(self) -> bool:
        """多账号默认不共享上下文。"""
        return self.context_isolation

    def is_context_isolated(self, adapter: str, handle: str) -> bool:
        """查询某账号是否处于上下文隔离态（默认全部隔离）。"""
        if not self.context_isolation:
            return False
        acc = self.get(adapter, handle)
        return acc is not None

    def assert_secure_permissions(self) -> bool:
        """校验主密钥文件权限是否收敛为 0o600（仅属主可读写）。

        返回 True 表示权限安全；否则为 False（如被误设为组/其他可读）。
        真实部署应配合 OS 级权限与密钥管理，这里只做最小一致性校验。
        """
        try:
            mode = stat.S_IMODE(os.stat(self.vault.key_file).st_mode)
        except OSError:
            return False
        return mode == 0o600

    def rotate_master_key(self) -> None:
        """轮换主密钥：重新生成密钥文件（0o600）并用新密钥重加密既有凭据。"""
        # 先解密所有已存凭据
        recovered: list[tuple[str, str, str]] = []  # (adapter, handle, secret)
        for acc in list(self._accounts.values()):
            if acc.encrypted_token:
                secret = self.vault.decrypt(acc.encrypted_token)
                recovered.append((acc.adapter, acc.handle, secret))
        # 生成新主密钥
        self.vault._master = secrets.token_bytes(32)
        fd = os.open(self.vault.key_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(self.vault._master)
        os.chmod(self.vault.key_file, 0o600)
        # 用新密钥重加密
        for adapter, handle, secret in recovered:
            self.store_secret(adapter, handle, secret)
        self.vault._master = None  # 用完即清，避免常驻内存

