"""沙箱策略：从随包 JSON 真实读取，并**强制执行**命令白名单 / 路径 / 环境隔离。

安全背景
--------
``RuntimeService.exec_tool("sandbox", ...)`` 早期实现直接把来自聊消息 / JSON
桥接的命令交给 ``bash -lc``，并继承 ``os.environ``（含 TANGRAM_API_KEY、
TANGRAM_QQ_SECRET、NAPCAT_TOKEN 等凭据）。任何能连上后端桥接的人都能以
后端进程权限执行任意命令、读取宿主机任意文件、外带全部密钥——是完整的
远程代码执行（CWE-78 / CWE-94）。仓库里这份 ``sandbox_policy.json`` 与
``load_policy()`` 当时是死代码，策略从未生效。

现在的强制约束（fail-closed，任何一步失败都拒绝执行，绝不降级为裸 shell）：

1. 命令用 ``shlex.split`` 解析后经 ``shell=False`` 执行，shell 元字符不再
   具备执行语义（``echo a; rm -rf /`` 只会把 ``a;`` ``rm`` ``-rf`` ``/``
   当成 echo 的参数）。
2. 程序名必须命中策略 ``allow`` 白名单；程序路径在**受控 PATH** 中解析，
   工作区不在 PATH 内，杜绝同名程序劫持。
3. 所有路径型参数经 ``realpath`` 归一化（跟随符号链接）后必须落在工作区
   内，且不得命中 ``denied_paths``（``~/.ssh`` / ``/etc/shadow`` / ``/root``
   / ``/proc/sys`` …），杜绝 ``..`` 穿越与软链接逃逸。
4. URL 型参数禁止回环 / 私网 / 链路本地 / 云元数据地址，缓解 SSRF。
5. 命中 ``deny`` 拒绝列表的命令直接拒绝。
6. 子进程只继承一份**最小化环境**（PATH / LANG / TERM / HOME=工作区），
   不继承任何 API Key / Token / 凭据类环境变量。
7. 超时与输出上限均取自真实策略文件，而非硬编码。

局限：白名单里的 ``python3`` / ``git`` / ``awk`` 等程序本身具备执行能力，
这是策略显式授权的工作区能力；真正的 OS 级隔离由 ``im/serve.py`` 的
unshare + chroot 沙箱提供。本模块保证「不经 shell、不越工作区、不泄密钥」。
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shlex
import shutil
import sys
from pathlib import Path
from urllib.parse import urlsplit

POLICY_PATH = Path(__file__).with_name("sandbox_policy.json")

__all__ = [
    "POLICY_PATH",
    "SandboxPolicyError",
    "load_policy",
    "validate_command",
    "safe_env",
]


class SandboxPolicyError(ValueError):
    """命令未通过沙箱策略；调用方必须拒绝执行（fail-closed）。"""


def load_policy() -> dict:
    """读取真实策略文件；缺失 / 损坏一律抛错（绝不静默给宽松默认值）。"""
    data = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or "allow" not in data:
        raise ValueError("sandbox_policy.json 结构非法")
    return data


# 控制字符（含换行 / NUL / ESC）：拒绝，避免把多行输入藏成第二条命令。
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")

# 受控 PATH：只含系统标准目录 + 当前解释器所在目录（保证 python3/pip 可用），
# **绝不包含工作区**，因此工作区里同名恶意程序不会被解析到。
def _safe_path() -> str:
    parts = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin",
             "/usr/bin", "/sbin", "/bin"]
    interpreter_dir = os.path.dirname(os.path.abspath(sys.executable))
    if interpreter_dir and interpreter_dir not in parts:
        parts.insert(0, interpreter_dir)
    return os.pathsep.join(parts)


# 环境变量白名单：只保留与运行相关的非敏感项，绝不继承 os.environ。
_SAFE_ENV_KEYS = ("LANG", "LC_ALL", "LC_CTYPE", "TZ")


def safe_env(workspace: str | Path) -> dict[str, str]:
    """构造子进程最小环境：不含任何 API Key / Token / 凭据。"""
    ws = str(Path(workspace).resolve())
    env = {k: os.environ[k] for k in _SAFE_ENV_KEYS if k in os.environ}
    env.update({
        "PATH": _safe_path(),
        "HOME": ws,
        "TMPDIR": ws,
        "TERM": "dumb",
        "SHELL": "/bin/sh",
    })
    return env


def _denied_roots(policy: dict) -> list[str]:
    roots: list[str] = []
    for raw in policy.get("denied_paths", []) or []:
        try:
            p = os.path.realpath(os.path.expanduser(str(raw)))
        except (OSError, ValueError):
            continue
        roots.append(p.rstrip(os.sep))
    return roots


def _check_url(token: str) -> None:
    """拒绝指向内网 / 回环 / 云元数据的 URL 参数（最小 SSRF 缓解层）。"""
    try:
        parts = urlsplit(token)
        host = (parts.hostname or "").strip("[]").lower()
    except ValueError as exc:
        raise SandboxPolicyError(f"非法 URL 参数：{token[:80]}") from exc
    if not host:
        raise SandboxPolicyError("URL 参数缺少主机名")
    if (host in ("localhost", "metadata", "metadata.google.internal",
                 "169.254.169.254", "100.100.100.200")
            or host.endswith((".localhost", ".internal", ".local"))):
        raise SandboxPolicyError(f"URL 参数指向内部地址，已拒绝：{host}")
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return  # 普通域名：由出站代理 / 网络层兜底（DNS rebinding 局限）
    if (addr.is_private or addr.is_loopback or addr.is_link_local
            or addr.is_reserved or addr.is_multicast or addr.is_unspecified):
        raise SandboxPolicyError(f"URL 参数指向非公网地址，已拒绝：{host}")


def _check_path_value(value: str, workspace: Path,
                      denied_roots: list[str], original: str) -> None:
    """realpath 归一化后必须留在工作区内，且不得命中敏感路径。"""
    expanded = os.path.expanduser(value)
    if os.path.isabs(expanded):
        resolved = os.path.realpath(expanded)
    else:
        resolved = os.path.realpath(os.path.join(str(workspace), expanded))
    ws = str(workspace)
    for root in denied_roots:
        if resolved == root or resolved.startswith(root + os.sep):
            raise SandboxPolicyError(
                f"命令引用了被禁止的敏感路径：{original[:80]}")
    if not (resolved == ws or resolved.startswith(ws + os.sep)):
        raise SandboxPolicyError(
            f"命令路径越出沙箱工作区（只允许工作区内的相对/绝对路径）：{original[:80]}")


def _check_arg(arg: str, workspace: Path, denied_roots: list[str]) -> None:
    if not arg or arg == "-":
        return
    if arg.startswith(("http://", "https://", "ftp://", "file://")):
        if arg.startswith("file://"):
            raise SandboxPolicyError("禁止 file:// 协议参数")
        _check_url(arg)
        return
    if arg.startswith("--") and "=" in arg:
        _check_path_value(arg.split("=", 1)[1], workspace, denied_roots, arg)
        return
    if arg.startswith("-"):
        return  # 普通选项，值可能跟在下一个参数里（下面逐参数检查已覆盖）
    looks_like_path = (arg.startswith(("/", "~", "./", "../"))
                       or "/" in arg or arg in (".", ".."))
    if not looks_like_path:
        return
    _check_path_value(arg, workspace, denied_roots, arg)


def validate_command(command: str, workspace: str | Path,
                     policy: dict | None = None) -> tuple[list[str], dict]:
    """校验并返回 ``(安全 argv, 策略)``；不通过抛 :class:`SandboxPolicyError`。

    返回的 argv[0] 是受控 PATH 下解析出的绝对路径，交由调用方以
    ``subprocess.run(argv, shell=False, cwd=workspace, env=safe_env(...))`` 执行。
    """
    if not isinstance(command, str) or not command.strip():
        raise SandboxPolicyError("command 为空")
    if _CONTROL_RE.search(command):
        raise SandboxPolicyError("命令包含控制字符/换行，拒绝执行")
    pol = policy if policy is not None else load_policy()
    allow = {str(x) for x in (pol.get("allow") or [])}
    if not allow:
        raise SandboxPolicyError("沙箱策略未定义 allow 白名单，拒绝执行（fail-closed）")
    try:
        argv = shlex.split(command, posix=True)
    except ValueError as exc:
        raise SandboxPolicyError(f"命令无法安全解析（引号不闭合等）：{exc}") from exc
    if not argv:
        raise SandboxPolicyError("命令解析后为空")

    prog = argv[0]
    # 不允许带路径（/tmp/evil/echo），也不允许不在白名单里的程序。
    if os.path.basename(prog) != prog or prog not in allow:
        raise SandboxPolicyError(f"命令 {prog[:60]!r} 不在沙箱白名单内")

    normalized = " ".join(argv)
    for raw in pol.get("deny", []) or []:
        phrase = str(raw)
        if re.search(r"(?<!\w)" + re.escape(phrase) + r"(?!\w)", normalized):
            raise SandboxPolicyError(f"命令命中沙箱拒绝列表：{phrase}")

    resolved_prog = shutil.which(prog, path=_safe_path())
    if not resolved_prog:
        raise SandboxPolicyError(f"白名单程序 {prog!r} 在受控 PATH 中不存在")

    ws = Path(workspace).resolve()
    roots = _denied_roots(pol)
    for arg in argv[1:]:
        _check_arg(arg, ws, roots)
    return [resolved_prog] + argv[1:], pol
