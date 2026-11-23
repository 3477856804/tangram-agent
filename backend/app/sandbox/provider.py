"""沙箱抽象（SandboxProvider）+ 人工接管（Take Control）—— Python 侧镜像。

与 Dart 侧 ``frontend/lib/harness/sandbox_provider.dart`` /
``sandbox_takeover.dart`` 同一套接口语义（clean-room，只参考设计思路，
自行实现，未复制任何第三方源码），仅标准库：

  * ``SandboxProvider``：生命周期（start/stop/status）、执行（exec，
    带超时与输出上限）、文件（read/write/list）、屏幕/会话状态查询。
  * ``SandboxProviderRegistry``：注册 / 切换（切换先自检，失败回落默认
    后端并记录原因）。
  * ``SandboxTakeover``：接管租约（request/grant/release，持有人、原因、
    过期时间，默认最长 10 分钟，到期自动释放）；接管期间自动 exec 拒绝。
  * ``LocalSandboxProvider``：本机宿主 shell 后端（subprocess 真实执行）；
    proot 后端只在 Dart 侧（Android 用户态），Python 侧默认 local。

审计：接管与释放只记元数据（持有人、原因标签、租约 id、剩余秒数），
绝不记命令全文与密钥。本模块不直接写审计文件，由调用方通过
``on_audit`` 回调注入（``im/serve.py`` 接 ``im/audit.py`` 的
``AuditLog``）；回调抛错只吞掉，绝不阻断接管流程。

微信 / 飞书扫码、2FA / 验证码场景的接线方式（只写明接线，不实际扫码、
不发真实消息、不读验证码）：终端出现二维码链接或验证码输入提示时，
agent 以 ``reason='qr-login:wechat'`` / ``'qr-login:feishu'`` /
``'qr-login:qq'`` / ``'2fa:totp'`` / ``'2fa:sms'`` 申请接管；人手工
完成扫码 / 输入后 ``release``，bot 恢复执行。验证码本身只进终端输入，
绝不进审计日志与租约记录。
"""

from __future__ import annotations

import subprocess
import threading
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Optional

__all__ = [
    "SandboxProviderKind",
    "SandboxExecResult",
    "SandboxFileEntry",
    "SandboxProvider",
    "LocalSandboxProvider",
    "SandboxProviderRegistry",
    "SandboxTakeoverLease",
    "SandboxTakeoverLeaseStatus",
    "SandboxTakeover",
    "get_takeover",
]

# 接管租约默认时长与上限：10 分钟（与 Dart 侧一致）。
DEFAULT_LEASE_SECONDS = 600
MAX_LEASE_SECONDS = 600


class SandboxProviderKind(str, Enum):
    """沙箱后端种类（与 Dart 侧 SandboxProviderKind 同名同值）。"""

    PROOT = "proot"  # Android 本地 Linux 用户态（Dart 侧才有此后端）
    LOCAL = "local"  # 本机宿主 shell


@dataclass
class SandboxExecResult:
    """一次沙箱执行的结果。

    ``status`` 取值：ok / error / timeout / takeover-active /
    not-installed。
    """

    ok: bool
    kind: SandboxProviderKind
    stdout: str = ""
    stderr: str = ""
    exit_code: int = -1
    timed_out: bool = False
    truncated: bool = False
    status: str = "ok"
    error: str = ""
    cwd: str = "."

    @classmethod
    def takeover_refused(
        cls, kind: SandboxProviderKind, detail: str
    ) -> "SandboxExecResult":
        """接管期间拒绝自动执行的结果（不执行命令）。"""
        return cls(
            ok=False,
            kind=kind,
            status="takeover-active",
            error=f"沙箱正被人工接管，自动执行已暂停：{detail}",
        )

    @classmethod
    def not_installed(
        cls, kind: SandboxProviderKind, detail: str
    ) -> "SandboxExecResult":
        """后端未安装 / 未就绪的结果（不执行命令）。"""
        return cls(ok=False, kind=kind, status="not-installed", error=detail)

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "ok": self.ok,
            "kind": self.kind.value,
            "status": self.status,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "exit_code": self.exit_code,
            "timed_out": self.timed_out,
            "truncated": self.truncated,
            "cwd": self.cwd,
        }
        if self.error:
            out["error"] = self.error
        return out


@dataclass
class SandboxFileEntry:
    """list_dir 返回的一条文件记录。"""

    name: str
    path: str
    is_directory: bool
    size: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "path": self.path,
            "is_directory": self.is_directory,
            "size": self.size,
        }


class SandboxProvider:
    """沙箱后端统一接口（抽象基类，具体后端见子类）。"""

    kind: SandboxProviderKind = SandboxProviderKind.LOCAL

    def __init__(self, takeover: Optional["SandboxTakeover"] = None) -> None:
        # 人工接管管理器（可为空 = 不设接管门禁；注册表会统一注入）。
        self.takeover = takeover

    @property
    def name(self) -> str:
        return f"沙箱后端（{self.kind.value}）"

    # ---- 生命周期 ----

    def start(self) -> dict[str, Any]:
        """确保后端就绪；未就绪返回 ok=False（不自动下载/安装）。"""
        raise NotImplementedError

    def stop(self) -> dict[str, Any]:
        """停止后端；无常驻进程的后端返回 ok=True + 说明即可。"""
        raise NotImplementedError

    def status(self) -> dict[str, Any]:
        """状态快照（给状态查询用）。"""
        raise NotImplementedError

    # ---- 执行 ----

    def exec(
        self,
        command: str,
        cwd: str = ".",
        timeout: float = 60.0,
        max_output_chars: int = 65536,
    ) -> SandboxExecResult:
        """执行命令：超时强杀、输出超上限截断；接管期间拒绝，不执行。"""
        raise NotImplementedError

    # ---- 文件 ----

    def read_file(self, guest_path: str,
                  max_bytes: int = 1024 * 1024) -> dict[str, Any]:
        """读沙箱内文件；成功 {ok, content, size}，失败 {ok, error}。"""
        raise NotImplementedError

    def write_file(self, guest_path: str, content: str) -> dict[str, Any]:
        """写沙箱内文件（父目录不存在时自动创建）。"""
        raise NotImplementedError

    def list_dir(self, guest_path: str) -> dict[str, Any]:
        """列沙箱内目录；成功 {ok, entries:[...]}。"""
        raise NotImplementedError

    # ---- 屏幕 / 会话状态 ----

    def session_state(self) -> dict[str, Any]:
        """屏幕/会话状态查询。本机后端无独立屏幕，返回终端执行状态。"""
        raise NotImplementedError

    def self_check(self) -> dict[str, Any]:
        """快速自检（注册表切换前调用）：只做轻量存在性检查，不启动。"""
        raise NotImplementedError

    # ---- 门禁与纯函数工具 ----

    def takeover_refusal(self) -> Optional[SandboxExecResult]:
        """接管门禁：接管生效时返回拒绝结果，否则返回 None（放行）。"""
        takeover = self.takeover
        if takeover is None:
            return None
        lease = takeover.active_lease()
        if lease is None:
            return None
        return SandboxExecResult.takeover_refused(
            self.kind,
            f"持有人 {lease.holder}，原因 {lease.reason}，"
            f"租约 {lease.id}，剩余 {lease.remaining_seconds()}s",
        )

    @staticmethod
    def cap_output(text: str, max_chars: int) -> str:
        """输出上限：超长输出截断并加尾注。纯函数，供子类与测试共用。"""
        if max_chars <= 0:
            return ""
        if len(text) <= max_chars:
            return text
        return (text[:max_chars]
                + f"\n…[输出已截断，共 {len(text)} 字符，上限 {max_chars}]")

    @staticmethod
    def resolve_guest_path(
        rootfs_path: str | Path, workspace_path: str | Path,
        guest_path: str,
    ) -> Optional[str]:
        """沙箱内 guest 路径 → 宿主真实路径（纯函数，供适配器共用）。

        * ``/workspace/...`` → 工作区目录；
        * 其他绝对路径 ``/a/b`` → rootfs 下的 ``/a/b``；
        * 相对路径 ``a/b`` → rootfs 下的 ``/root/a/b``。
        含 ``..`` 穿越的路径返回 None（调用方按越界拒绝）。
        """
        g = (guest_path or "").strip()
        if not g:
            return None
        segs: list[str] = []
        for part in g.split("/"):
            if not part or part == ".":
                continue
            if part == "..":
                return None
            segs.append(part)
        if not segs:
            return None
        root = str(rootfs_path).rstrip("/")
        ws = str(workspace_path).rstrip("/")
        if segs[0] == "workspace":
            if len(segs) == 1:
                return ws
            return ws + "/" + "/".join(segs[1:])
        if g.startswith("/"):
            return root + "/" + "/".join(segs)
        return root + "/root/" + "/".join(segs)

    @staticmethod
    def resolve_workspace_path(
        workspace_path: str | Path, path: str,
    ) -> Optional[str]:
        """工作区内宿主路径解析（本机后端用）：相对路径落在工作区内，
        绝对路径必须已在工作区内，``..`` 穿越返回 None。"""
        p = (path or "").strip()
        if not p:
            return None
        ws = str(workspace_path).rstrip("/")
        joined = p if p.startswith("/") else ws + "/" + p
        segs: list[str] = []
        for part in joined.split("/"):
            if not part or part == ".":
                continue
            if part == "..":
                if not segs:
                    return None
                segs.pop()
                continue
            segs.append(part)
        resolved = "/" + "/".join(segs)
        if resolved != ws and not resolved.startswith(ws + "/"):
            return None
        return resolved


class LocalSandboxProvider(SandboxProvider):
    """本机宿主 shell 后端：subprocess 真实执行，无用户态隔离。

    只在 proot 不可用时作执行回落；命令经 ``/bin/sh -c`` 真实执行，
    超时强杀、输出上限截断。Windows 上诚实拒绝（不伪装成可用）。
    """

    kind = SandboxProviderKind.LOCAL

    def __init__(
        self,
        workspace: str | Path,
        takeover: Optional["SandboxTakeover"] = None,
    ) -> None:
        super().__init__(takeover)
        # 宿主工作区目录（所有相对路径与文件操作都限定在此目录内）。
        self.workspace = Path(workspace)

    @property
    def name(self) -> str:
        return "本机沙箱（宿主 shell）"

    def start(self) -> dict[str, Any]:
        try:
            self.workspace.mkdir(parents=True, exist_ok=True)
            return {"ok": True, "kind": self.kind.value,
                    "workspace": str(self.workspace)}
        except OSError as exc:
            return {"ok": False, "kind": self.kind.value,
                    "error": f"工作区不可用：{exc}"}

    def stop(self) -> dict[str, Any]:
        return {"ok": True, "kind": self.kind.value,
                "note": "本机 shell 无常驻进程，无需停止。"}

    def status(self) -> dict[str, Any]:
        check = self.self_check()
        out: dict[str, Any] = {
            "ok": True,
            "kind": self.kind.value,
            "running": check["ok"] is True,
            "workspace": str(self.workspace),
            "shell": "/bin/sh",
        }
        if check["ok"] is not True:
            out["error"] = check.get("error", "")
        return out

    def exec(
        self,
        command: str,
        cwd: str = ".",
        timeout: float = 60.0,
        max_output_chars: int = 65536,
    ) -> SandboxExecResult:
        refused = self.takeover_refusal()
        if refused is not None:
            return refused
        import os

        if os.name == "nt":
            return SandboxExecResult(
                ok=False, kind=self.kind, status="error",
                error="本机沙箱 exec 仅支持 POSIX shell，Windows 请用远端沙箱。",
                cwd=cwd,
            )
        # exec 前确保工作区存在（start 的同款幂等创建；未 start 就 exec
        # 也不应报「目录不存在」，否则切换自检通过后首次执行仍会失败）。
        try:
            self.workspace.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            return SandboxExecResult(
                ok=False, kind=self.kind, status="error",
                error=f"工作区不可用：{exc}", cwd=cwd,
            )
        resolved = self.resolve_workspace_path(str(self.workspace), cwd)
        if resolved is None:
            return SandboxExecResult(
                ok=False, kind=self.kind, status="error",
                error=f"工作目录越出沙箱工作区：{cwd}", cwd=cwd,
            )
        try:
            proc = subprocess.Popen(
                ["/bin/sh", "-c", command],
                cwd=resolved,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
            )
        except OSError as exc:
            return SandboxExecResult(
                ok=False, kind=self.kind, status="error",
                error=f"宿主 shell 无法启动：{exc}", cwd=cwd,
            )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
            timed_out = False
            exit_code = proc.returncode
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            timed_out = True
            exit_code = 124
        truncated = (len(stdout) > max_output_chars
                     or len(stderr) > max_output_chars)
        return SandboxExecResult(
            ok=(not timed_out and exit_code == 0),
            kind=self.kind,
            stdout=self.cap_output(stdout, max_output_chars),
            stderr=self.cap_output(stderr, max_output_chars),
            exit_code=exit_code,
            timed_out=timed_out,
            truncated=truncated,
            status=("timeout" if timed_out
                    else ("ok" if exit_code == 0 else "error")),
            error=("命令超时 %ss 已强杀" % int(timeout) if timed_out
                   else ("" if exit_code == 0 else f"exit {exit_code}")),
            cwd=cwd,
        )

    def read_file(self, guest_path: str,
                  max_bytes: int = 1024 * 1024) -> dict[str, Any]:
        path = self.resolve_workspace_path(str(self.workspace), guest_path)
        if path is None:
            return {"ok": False, "error": f"路径越出沙箱工作区：{guest_path}"}
        f = Path(path)
        try:
            if not f.is_file():
                return {"ok": False, "error": f"文件不存在：{guest_path}"}
            size = f.stat().st_size
            if size > max_bytes:
                return {"ok": False,
                        "error": f"文件过大（{size} 字节，上限 {max_bytes}）：{guest_path}"}
            return {"ok": True, "path": guest_path, "size": size,
                    "content": f.read_text(encoding="utf-8")}
        except OSError as exc:
            return {"ok": False, "error": f"读取失败：{exc}"}

    def write_file(self, guest_path: str, content: str) -> dict[str, Any]:
        path = self.resolve_workspace_path(str(self.workspace), guest_path)
        if path is None:
            return {"ok": False, "error": f"路径越出沙箱工作区：{guest_path}"}
        try:
            f = Path(path)
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(content, encoding="utf-8")
            return {"ok": True, "path": guest_path, "size": len(content)}
        except OSError as exc:
            return {"ok": False, "error": f"写入失败：{exc}"}

    def list_dir(self, guest_path: str) -> dict[str, Any]:
        path = self.resolve_workspace_path(str(self.workspace), guest_path)
        if path is None:
            return {"ok": False, "error": f"路径越出沙箱工作区：{guest_path}"}
        d = Path(path)
        try:
            if not d.is_dir():
                return {"ok": False, "error": f"目录不存在：{guest_path}"}
            entries: list[SandboxFileEntry] = []
            for child in sorted(d.iterdir(), key=lambda c: c.name):
                size = 0
                if child.is_file():
                    try:
                        size = child.stat().st_size
                    except OSError:
                        size = 0
                entries.append(SandboxFileEntry(
                    name=child.name,
                    path=f"{guest_path.rstrip('/')}/{child.name}",
                    is_directory=child.is_dir(),
                    size=size,
                ))
            return {"ok": True, "path": guest_path,
                    "entries": [e.to_dict() for e in entries]}
        except OSError as exc:
            return {"ok": False, "error": f"列目录失败：{exc}"}

    def session_state(self) -> dict[str, Any]:
        return {
            "kind": self.kind.value,
            "running": True,
            "workspace": str(self.workspace),
            "note": "本机沙箱无独立屏幕会话；会话状态即宿主终端状态。",
        }

    def self_check(self) -> dict[str, Any]:
        import os

        if os.name == "nt":
            return {"ok": False, "kind": self.kind.value,
                    "error": "本机沙箱 exec 仅支持 POSIX shell。"}
        shell_ok = Path("/bin/sh").exists()
        # 工作区尚未创建也算通过：start()/exec() 会幂等创建；只有父目录
        # 也不存在（无法创建）时才算自检失败。
        ws_ok = self.workspace.is_dir() or self.workspace.parent.is_dir()
        out: dict[str, Any] = {
            "ok": shell_ok and ws_ok,
            "kind": self.kind.value,
            "shell": shell_ok,
            "workspace": ws_ok,
        }
        if not shell_ok:
            out["error"] = "宿主 /bin/sh 不存在"
        elif not ws_ok:
            out["error"] = f"工作区不存在且无法创建：{self.workspace}"
        return out


# ---------------------------------------------------------------------------
# 人工接管（Take Control）
# ---------------------------------------------------------------------------

class SandboxTakeoverLeaseStatus(str, Enum):
    """租约状态：requested → granted → released / expired。"""

    REQUESTED = "requested"
    GRANTED = "granted"
    RELEASED = "released"
    EXPIRED = "expired"


@dataclass
class SandboxTakeoverLease:
    """一份接管租约。只含元数据：持有人、原因标签、时间，不含命令与密钥。"""

    id: str
    holder: str  # 持有人标识（如 'user' / 'operator'），只作审计元数据
    reason: str  # 原因标签，如 'qr-login:wechat' / '2fa:totp'，不含命令全文
    requested_at: float  # Unix 秒
    duration: float  # 授权后生效时长（秒；grant 时起算）
    granted_at: Optional[float] = None
    status: SandboxTakeoverLeaseStatus = SandboxTakeoverLeaseStatus.REQUESTED
    released_reason: str = ""

    @property
    def expires_at(self) -> float:
        """授权后的过期时刻；未授权时按申请时刻 + 时长估算。"""
        return (self.granted_at if self.granted_at is not None
                else self.requested_at) + self.duration

    def is_expired_at(self, now: float) -> bool:
        """在 ``now`` 时刻是否已过期（仅对 granted 的租约有意义）。"""
        return (self.status == SandboxTakeoverLeaseStatus.GRANTED
                and now >= self.expires_at)

    def remaining_seconds(self, now: Optional[float] = None) -> int:
        """剩余秒数（未授权按申请时刻起算；已释放/已过期返回 0）。"""
        if self.status != SandboxTakeoverLeaseStatus.GRANTED:
            return 0
        now = time.time() if now is None else now
        return max(0, int(self.expires_at - now))

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "id": self.id,
            "holder": self.holder,
            "reason": self.reason,
            "status": self.status.value,
            "requested_at": self.requested_at,
            "expires_at": self.expires_at,
        }
        if self.granted_at is not None:
            out["granted_at"] = self.granted_at
        if self.released_reason:
            out["released_reason"] = self.released_reason
        return out


class SandboxTakeover:
    """人工接管管理器：租约申请 / 授权 / 释放 + 到期自动释放 + 审计回调。

    审计只记元数据：回调收到的 detail 只有 holder / reason / lease id /
    剩余秒数，调用方不得往里塞命令全文与密钥。``on_audit(action, detail)``
    抛错会被吞掉，绝不阻断接管流程。
    """

    def __init__(
        self,
        on_audit: Optional[Callable[[str, dict[str, Any]], None]] = None,
        time_fn: Optional[Callable[[], float]] = None,
    ) -> None:
        self.on_audit = on_audit
        self._time_fn = time_fn or time.time
        self._lock = threading.Lock()
        self._lease: Optional[SandboxTakeoverLease] = None
        self._seq = 0

    def _now(self) -> float:
        return self._time_fn()

    def active_lease(self) -> Optional[SandboxTakeoverLease]:
        """当前生效租约（读取时先清掉已过期的租约并记一条过期审计）。"""
        with self._lock:
            self._sweep_expired_locked()
            lease = self._lease
            if lease is not None and lease.status == SandboxTakeoverLeaseStatus.GRANTED:
                return lease
            return None

    def is_active(self) -> bool:
        """是否正被人工接管（自动 exec 应拒绝）。"""
        return self.active_lease() is not None

    def request(
        self,
        holder: str,
        reason: str,
        duration: Optional[float] = None,
    ) -> dict[str, Any]:
        """申请接管。已有生效或待授权租约时拒绝，不覆盖、不排队。
        duration 超过上限会被截断到 600s。"""
        with self._lock:
            self._sweep_expired_locked()
            existing = self._lease
            if existing is not None and existing.status in (
                SandboxTakeoverLeaseStatus.REQUESTED,
                SandboxTakeoverLeaseStatus.GRANTED,
            ):
                return {
                    "ok": False,
                    "status": "already-active",
                    "error": "已有接管租约生效或待授权，不能重复申请",
                    "lease": existing.to_dict(),
                }
            seconds = (DEFAULT_LEASE_SECONDS if duration is None
                       else float(duration))
            if seconds > MAX_LEASE_SECONDS:
                seconds = float(MAX_LEASE_SECONDS)
            if seconds <= 0:
                seconds = float(DEFAULT_LEASE_SECONDS)
            self._seq += 1
            lease = SandboxTakeoverLease(
                id=f"takeover-{time.time_ns()}-{self._seq}",
                holder=holder,
                reason=reason,
                requested_at=self._now(),
                duration=seconds,
            )
            self._lease = lease
            self._audit_locked("takeover.request", lease,
                               {"requested_seconds": int(seconds)})
            return {"ok": True, "status": "requested",
                    "lease": lease.to_dict()}

    def grant(self, lease_id: str, by: str = "human") -> dict[str, Any]:
        """授权一份待授权租约（人确认接管）。租约 id 不符或状态不对时拒绝。"""
        with self._lock:
            self._sweep_expired_locked()
            lease = self._lease
            if lease is None or lease.id != lease_id:
                return {"ok": False, "status": "not-found",
                        "error": f"接管租约不存在：{lease_id}"}
            if lease.status != SandboxTakeoverLeaseStatus.REQUESTED:
                return {"ok": False, "status": "wrong-state",
                        "error": f"租约当前状态为 {lease.status.value}，不能授权",
                        "lease": lease.to_dict()}
            lease.status = SandboxTakeoverLeaseStatus.GRANTED
            lease.granted_at = self._now()
            self._audit_locked("takeover.grant", lease, {"by": by})
            return {"ok": True, "status": "granted",
                    "lease": lease.to_dict()}

    def release(
        self,
        lease_id: str,
        by: str = "human",
        reason: str = "done",
    ) -> dict[str, Any]:
        """释放一份租约（人办完交还 bot，或取消待授权申请）。
        已释放/已过期的租约再次释放返回 ok=False，不重复记审计。"""
        with self._lock:
            self._sweep_expired_locked()
            lease = self._lease
            if lease is None or lease.id != lease_id:
                return {"ok": False, "status": "not-found",
                        "error": f"接管租约不存在：{lease_id}"}
            if lease.status not in (
                SandboxTakeoverLeaseStatus.REQUESTED,
                SandboxTakeoverLeaseStatus.GRANTED,
            ):
                return {"ok": False, "status": "wrong-state",
                        "error": f"租约当前状态为 {lease.status.value}，不能释放",
                        "lease": lease.to_dict()}
            lease.status = SandboxTakeoverLeaseStatus.RELEASED
            lease.released_reason = reason
            self._audit_locked("takeover.release", lease,
                               {"by": by, "released_reason": reason})
            return {"ok": True, "status": "released",
                    "lease": lease.to_dict()}

    def status(self) -> dict[str, Any]:
        """当前接管状态（给状态查询用，只含元数据）。"""
        lease = self.active_lease()
        out: dict[str, Any] = {
            "active": lease is not None,
            "max_lease_seconds": MAX_LEASE_SECONDS,
        }
        if lease is not None:
            out["lease"] = lease.to_dict()
            out["remaining_seconds"] = lease.remaining_seconds(self._now())
        return out

    def _sweep_expired_locked(self) -> None:
        """惰性过期：已授权且过了 expires_at 的租约自动转为 expired 并记审计。"""
        lease = self._lease
        if lease is None:
            return
        if (lease.status == SandboxTakeoverLeaseStatus.GRANTED
                and lease.is_expired_at(self._now())):
            lease.status = SandboxTakeoverLeaseStatus.EXPIRED
            lease.released_reason = "expired"
            self._audit_locked("takeover.expired", lease, {})

    def _audit_locked(
        self,
        action: str,
        lease: SandboxTakeoverLease,
        extra: dict[str, Any],
    ) -> None:
        cb = self.on_audit
        if cb is None:
            return
        detail: dict[str, Any] = {
            "lease": lease.id,
            "holder": lease.holder,
            "reason": lease.reason,
            "remaining_seconds": lease.remaining_seconds(self._now()),
        }
        detail.update(extra)
        try:
            cb(action, detail)
        except Exception:  # noqa: BLE001 - 审计回调失败绝不阻断接管流程
            pass


# ---------------------------------------------------------------------------
# 注册表与进程内单例
# ---------------------------------------------------------------------------

class SandboxProviderRegistry:
    """沙箱 provider 注册表：注册 / 切换（先自检，失败回落默认并记录原因）。

    注册表持有唯一的 :class:`SandboxTakeover`，注册时注入每个 provider，
    接管门禁因此在所有后端上一致生效。
    """

    def __init__(
        self,
        takeover: SandboxTakeover,
        default_kind: SandboxProviderKind = SandboxProviderKind.PROOT,
    ) -> None:
        self.takeover = takeover
        self.default_kind = default_kind
        self._factories: dict[SandboxProviderKind,
                              Callable[[], SandboxProvider]] = {}
        self._current: Optional[SandboxProvider] = None
        self._current_kind: Optional[SandboxProviderKind] = None
        # 最近一次切换失败的原因（成功切换后清掉）。
        self.last_switch_error: Optional[str] = None
        # 最近一次回落默认后端的原因（成功切换到非默认后端后清掉）。
        self.last_fallback_reason: Optional[str] = None

    def register(
        self,
        kind: SandboxProviderKind,
        factory: Callable[[], SandboxProvider],
    ) -> None:
        self._factories[kind] = factory

    @property
    def available_kinds(self) -> list[str]:
        return [k.value for k in self._factories]

    @property
    def current(self) -> SandboxProvider:
        if self._current is not None:
            return self._current
        return self._build(self.default_kind)

    @property
    def current_kind(self) -> SandboxProviderKind:
        return self._current_kind or self.default_kind

    def _build(self, kind: SandboxProviderKind) -> SandboxProvider:
        factory = self._factories.get(kind)
        if factory is None:
            raise ValueError(f"未注册的沙箱后端：{kind.value}")
        provider = factory()
        provider.takeover = self.takeover
        self._current = provider
        self._current_kind = kind
        return provider

    def switch_to(self, kind: SandboxProviderKind) -> dict[str, Any]:
        """切换后端：先对候选后端自检；自检失败则回落默认后端（同样先自检），
        回落也失败时返回 ok=False，当前后端保持不变。"""
        factory = self._factories.get(kind)
        if factory is None:
            self.last_switch_error = f"未注册的沙箱后端：{kind.value}"
            return {"ok": False, "error": self.last_switch_error}
        candidate = factory()
        candidate.takeover = self.takeover
        check = candidate.self_check()
        if check.get("ok") is True:
            self._current = candidate
            self._current_kind = kind
            self.last_switch_error = None
            self.last_fallback_reason = None
            return {"ok": True, "kind": kind.value}
        reason = str(check.get("error") or "自检失败")
        self.last_switch_error = f"{kind.value} 自检失败：{reason}"
        if kind == self.default_kind:
            return {"ok": False, "error": self.last_switch_error,
                    "kind": kind.value}
        fb_factory = self._factories.get(self.default_kind)
        if fb_factory is None:
            return {"ok": False, "error": self.last_switch_error,
                    "kind": kind.value}
        fallback = fb_factory()
        fallback.takeover = self.takeover
        fb_check = fallback.self_check()
        if fb_check.get("ok") is not True:
            return {"ok": False, "error": self.last_switch_error,
                    "fallback_error": str(fb_check.get("error") or "自检失败"),
                    "kind": kind.value}
        self._current = fallback
        self._current_kind = self.default_kind
        self.last_fallback_reason = self.last_switch_error
        return {"ok": True, "kind": self.default_kind.value,
                "fallback": True, "reason": self.last_fallback_reason}

    def exec(
        self,
        command: str,
        cwd: str = ".",
        timeout: float = 60.0,
        max_output_chars: int = 65536,
    ) -> SandboxExecResult:
        """执行入口：委托当前后端（接管门禁在后端 exec 内生效）。"""
        return self.current.exec(
            command, cwd=cwd, timeout=timeout,
            max_output_chars=max_output_chars,
        )

    def status(self) -> dict[str, Any]:
        """注册表 + 当前后端的状态快照。"""
        current_status = self.current.status()
        out: dict[str, Any] = {
            "ok": True,
            "current_kind": self.current_kind.value,
            "available_kinds": self.available_kinds,
            "takeover_active": self.takeover.is_active(),
            "current": current_status,
        }
        if self.last_switch_error is not None:
            out["last_switch_error"] = self.last_switch_error
        if self.last_fallback_reason is not None:
            out["last_fallback_reason"] = self.last_fallback_reason
        return out


_TAKEOVER: Optional[SandboxTakeover] = None
_TAKEOVER_LOCK = threading.Lock()


def get_takeover() -> SandboxTakeover:
    """进程内唯一的接管管理器（im/serve.py 的 _sandbox_exec 门禁共用它）。"""
    global _TAKEOVER
    if _TAKEOVER is None:
        with _TAKEOVER_LOCK:
            if _TAKEOVER is None:
                _TAKEOVER = SandboxTakeover()
    return _TAKEOVER
