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
import os
import secrets
import stat
import time
from dataclasses import dataclass, field
from typing import Optional

from ..util import now_ts


@dataclass
class AccountSession:
    """单个平台账号的连接会话（凭据以密文存储）。"""

    adapter: str
    handle: str
    encrypted_token: str = ""   # 加密后的凭据，明文不落盘
    scan_session: str = ""      # 扫码登录会话标识（占位）
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


class AccountPool:
    """多账号加密凭据池（不进沙箱）。"""

    def __init__(self, key_file: str = "im_account_key.bin") -> None:
        self._accounts: dict[str, AccountSession] = {}
        self.vault = CredentialVault(key_file)
        self.context_isolation: bool = True  # 多账号默认不共享上下文

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

    # ---- 连接状态 / 扫码会话（占位） ----
    def mark_connected(self, adapter: str, handle: str, connected: bool = True) -> None:
        acc = self.get(adapter, handle)
        if acc is None:
            return
        acc.connected = connected
        acc.last_seen = now_ts()

    def begin_scan(self, adapter: str, handle: str) -> str:
        """发起扫码登录会话（占位：真实实现由平台 SDK 提供二维码/轮询）。"""
        acc = self.get(adapter, handle) or AccountSession(adapter=adapter, handle=handle)
        acc.scan_session = secrets.token_hex(16)
        acc.last_seen = now_ts()
        self.put(acc)
        return acc.scan_session

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

