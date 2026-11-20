"""快照备份与加密云同步（Cloudflare R2 / S3 兼容）。

设计参考 rclone 的加密对象思路与 cryptography 的 AES-256-GCM：

  * 配置只从环境变量读取（``TGA_R2_*`` / ``TGA_SYNC_KEY``），代码与日志中
    永不出现密钥明文；
  * 快照 = tar.gz 明文 → AES-256-GCM 加密 → ``b"TGA1" + nonce(12) + ct``；
  * 传输使用 AWS Signature V4（纯标准库实现，不依赖 boto3）；
  * 上传对象键形如 ``<prefix>/snapshot-<UTC 时间>.tga``；
  * 恢复时安全解包，拒绝绝对路径、``..`` 穿越、符号链接/硬链接/设备文件。

CLI::

    python -m app.runtime.cloud_sync status
    python -m app.runtime.cloud_sync upload <dir> [prefix]
    python -m app.runtime.cloud_sync download <key> <dir>
    python -m app.runtime.cloud_sync list [prefix]
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import io
import json
import os
import tarfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

# cryptography 是可选依赖（与 qq_openapi / wechat_ilink 的惰性依赖约定一致）：
# 主链路只用标准库；只有真正加解密快照时才需要它。未安装时模块仍可导入，
# 只有 encrypt_bytes / decrypt_bytes 会明确报 CloudCryptoError，绝不静默降级。
try:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # pragma: no cover - 可选依赖缺失路径
    InvalidTag = None  # type: ignore[assignment]
    AESGCM = None  # type: ignore[assignment]


def _require_crypto() -> None:
    if AESGCM is None:
        raise CloudCryptoError(
            "未安装 cryptography，无法加解密云端快照。"
            "请执行 pip install cryptography 后重试"
        )

__all__ = [
    "CloudConfig", "CloudConfigError", "CloudCryptoError", "CloudNetworkError",
    "CloudSnapshotError", "CloudSyncError", "CloudClient",
    "encrypt_bytes", "decrypt_bytes", "sign_request", "canonical_path",
    "status", "sync_snapshot", "restore_snapshot", "list_remote", "main",
]

MAGIC = b"TGA1"
NONCE_SIZE = 12
TAG_SIZE = 16
SYNC_KEY_BYTES = 32
MAX_FILES = 5000
MAX_TOTAL_BYTES = 256 * 1024 * 1024
LIST_PAGE_SIZE = 1000
MAX_LIST_PAGES = 100
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


class CloudSyncError(RuntimeError):
    """云端同步错误基类；错误信息可直接展示给用户，且不含密钥。"""


class CloudConfigError(CloudSyncError):
    """配置缺失或非法。"""


class CloudCryptoError(CloudSyncError):
    """密钥非法、密文被篡改或认证失败。"""


class CloudNetworkError(CloudSyncError):
    """网络 / 远端服务错误（如实抛错，不伪造成功）。"""


class CloudSnapshotError(CloudSyncError):
    """快照打包、限制或安全解包失败。"""


# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class CloudConfig:
    endpoint: str
    bucket: str
    access_key: str = field(repr=False)
    secret_key: str = field(repr=False)
    sync_key: bytes = field(repr=False)
    region: str = "auto"
    timeout: float = 30.0

    @classmethod
    def from_env(cls, environ: dict[str, str] | None = None) -> "CloudConfig":
        env = os.environ if environ is None else environ
        required = (
            "TGA_R2_ENDPOINT",
            "TGA_R2_BUCKET",
            "TGA_R2_ACCESS_KEY",
            "TGA_R2_SECRET_KEY",
            "TGA_SYNC_KEY",
        )
        missing = [name for name in required if not (env.get(name) or "").strip()]
        if missing:
            # 只列变量名，绝不回显任何值。
            raise CloudConfigError(
                "云端同步未配置，缺少环境变量：" + ", ".join(missing)
            )

        endpoint = env["TGA_R2_ENDPOINT"].strip().rstrip("/")
        parsed = urllib.parse.urlsplit(endpoint)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise CloudConfigError("TGA_R2_ENDPOINT 必须是合法的 http(s) URL")

        raw_key = env["TGA_SYNC_KEY"].strip()
        try:
            sync_key = base64.b64decode(raw_key, validate=True)
        except (binascii.Error, ValueError):
            raise CloudConfigError("TGA_SYNC_KEY 不是合法的 base64") from None
        if len(sync_key) != SYNC_KEY_BYTES:
            raise CloudConfigError(
                f"TGA_SYNC_KEY 必须是 base64 编码的 {SYNC_KEY_BYTES} 字节 AES 密钥"
            )

        region = (env.get("TGA_R2_REGION") or "auto").strip() or "auto"
        return cls(
            endpoint=endpoint,
            bucket=env["TGA_R2_BUCKET"].strip(),
            access_key=env["TGA_R2_ACCESS_KEY"].strip(),
            secret_key=env["TGA_R2_SECRET_KEY"].strip(),
            sync_key=sync_key,
            region=region,
        )


# ---------------------------------------------------------------------------
# AES-256-GCM
# ---------------------------------------------------------------------------
def _check_key(key: bytes) -> None:
    if not isinstance(key, (bytes, bytearray)) or len(key) != SYNC_KEY_BYTES:
        raise CloudCryptoError(f"AES-256-GCM 需要 {SYNC_KEY_BYTES} 字节密钥")


def encrypt_bytes(data: bytes, key: bytes) -> tuple[bytes, bytes]:
    """AES-256-GCM 加密，返回 ``(nonce, ciphertext)``（密文已含 16 字节 tag）。"""
    _check_key(key)
    _require_crypto()
    nonce = os.urandom(NONCE_SIZE)
    return nonce, AESGCM(bytes(key)).encrypt(nonce, bytes(data), None)


def decrypt_bytes(nonce: bytes, ciphertext: bytes, key: bytes) -> bytes:
    """AES-256-GCM 解密；被篡改 / 密钥错误时抛 ``CloudCryptoError``。"""
    _check_key(key)
    _require_crypto()
    if not isinstance(nonce, (bytes, bytearray)) or len(nonce) != NONCE_SIZE:
        raise CloudCryptoError("GCM nonce 长度必须为 12 字节")
    if not isinstance(ciphertext, (bytes, bytearray)) or len(ciphertext) < TAG_SIZE:
        raise CloudCryptoError("密文长度不足，缺少 GCM 认证标签")
    try:
        return AESGCM(bytes(key)).decrypt(bytes(nonce), bytes(ciphertext), None)
    except InvalidTag:
        raise CloudCryptoError("密文认证失败：数据被篡改或密钥错误") from None


def _pack_blob(data: bytes, key: bytes) -> bytes:
    nonce, ciphertext = encrypt_bytes(data, key)
    return MAGIC + nonce + ciphertext


def _unpack_blob(blob: bytes, key: bytes) -> bytes:
    if len(blob) < len(MAGIC) + NONCE_SIZE + TAG_SIZE:
        raise CloudCryptoError("快照文件过短，不是有效的 TGA1 加密对象")
    if not blob.startswith(MAGIC):
        raise CloudCryptoError("快照文件头错误（期望 TGA1）")
    nonce = blob[len(MAGIC):len(MAGIC) + NONCE_SIZE]
    ciphertext = blob[len(MAGIC) + NONCE_SIZE:]
    return decrypt_bytes(nonce, ciphertext, key)


# ---------------------------------------------------------------------------
# AWS Signature V4
# ---------------------------------------------------------------------------
def _uri_encode(value: str) -> str:
    return urllib.parse.quote(value, safe="-_.~")


def canonical_path(path: str) -> str:
    """RFC 3986 路径编码：逐段编码，保留 ``/``。"""
    if not path:
        return "/"
    if not path.startswith("/"):
        path = "/" + path
    return "/".join(
        _uri_encode(urllib.parse.unquote(segment)) for segment in path.split("/")
    )


def _canonical_query(items: Iterable[tuple[str, str]]) -> str:
    encoded = sorted((_uri_encode(str(k)), _uri_encode(str(v))) for k, v in items)
    return "&".join(f"{k}={v}" for k, v in encoded)


def _hmac_sha256(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret_key: str, date: str, region: str, service: str) -> bytes:
    k_date = _hmac_sha256(("AWS4" + secret_key).encode("utf-8"), date)
    k_region = _hmac_sha256(k_date, region)
    k_service = _hmac_sha256(k_region, service)
    return _hmac_sha256(k_service, "aws4_request")


def sign_request(
    method: str,
    url: str,
    payload_hash: str,
    access_key: str,
    secret_key: str,
    *,
    region: str = "auto",
    service: str = "s3",
    amz_date: str | None = None,
    extra_headers: dict[str, str] | None = None,
    query: dict[str, str] | None = None,
) -> dict[str, str]:
    """生成 SigV4 请求头（含 ``Authorization``），返回需随请求发送的头。

    ``query`` 为空时从 URL 的查询串解析；两者保持同一编码规则，避免
    签名与真实请求不一致。
    """
    parsed = urllib.parse.urlsplit(url)
    method = method.upper()
    if amz_date is None:
        amz_date = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]

    if query is not None:
        canonical_query = _canonical_query(query.items())
    else:
        canonical_query = _canonical_query(
            urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        )

    headers: dict[str, str] = {
        "host": parsed.netloc,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    for name, value in (extra_headers or {}).items():
        headers[name.strip().lower()] = " ".join(str(value).split())

    sorted_headers = sorted(headers.items())
    canonical_headers = "".join(f"{k}:{v}\n" for k, v in sorted_headers)
    signed_headers = ";".join(k for k, _ in sorted_headers)

    canonical_request = "\n".join((
        method,
        canonical_path(parsed.path),
        canonical_query,
        canonical_headers,
        signed_headers,
        payload_hash,
    ))
    scope = f"{date_stamp}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join((
        "AWS4-HMAC-SHA256",
        amz_date,
        scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ))
    signature = hmac.new(
        _signing_key(secret_key, date_stamp, region, service),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    out = {
        "Host": parsed.netloc,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        "Authorization": (
            f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        ),
    }
    return out


# ---------------------------------------------------------------------------
# S3 / R2 客户端
# ---------------------------------------------------------------------------
class CloudClient:
    """极简 S3 兼容客户端：PUT / GET / HEAD / ListObjectsV2。"""

    def __init__(self, config: CloudConfig) -> None:
        self.config = config

    # -- URL / 请求 -----------------------------------------------------
    def _object_url(self, key: str | None = None) -> str:
        base = f"{self.config.endpoint}/{_uri_encode(self.config.bucket)}"
        if key is None:
            return base
        encoded = "/".join(_uri_encode(seg) for seg in key.split("/"))
        return f"{base}/{encoded}"

    def _request(
        self,
        method: str,
        key: str | None = None,
        *,
        query: dict[str, str] | None = None,
        body: bytes | None = None,
        extra_headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        url = self._object_url(key)
        if query:
            url = f"{url}?{_canonical_query(query.items())}"
        payload = body if body is not None else b""
        payload_hash = hashlib.sha256(payload).hexdigest()
        signed = sign_request(
            method,
            url,
            payload_hash,
            self.config.access_key,
            self.config.secret_key,
            region=self.config.region,
            extra_headers=extra_headers,
            query=query,
        )
        headers = dict(signed)
        headers.update(extra_headers or {})
        headers["Content-Length"] = str(len(payload))

        request = urllib.request.Request(
            url,
            data=payload if method in ("PUT", "POST") else None,
            method=method,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=self.config.timeout) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read()[:300].decode("utf-8", "replace")
            raise CloudNetworkError(
                f"{method} {url} 返回 HTTP {exc.code}：{detail}"
            ) from None
        except (urllib.error.URLError, OSError) as exc:
            raise CloudNetworkError(f"{method} {url} 网络失败：{exc}") from None

    # -- 对象操作 -------------------------------------------------------
    def put_object(self, key: str, data: bytes) -> dict[str, Any]:
        digest = hashlib.sha256(data).hexdigest()
        _status, headers, _ = self._request(
            "PUT",
            key,
            body=data,
            extra_headers={"Content-Type": "application/octet-stream"},
        )
        return {"key": key, "bytes": len(data), "sha256": digest,
                "etag": headers.get("ETag", "").strip('"')}

    def get_object(self, key: str) -> bytes:
        _status, _headers, body = self._request("GET", key)
        return body

    def head_object(self, key: str) -> dict[str, Any]:
        _status, headers, _ = self._request("HEAD", key)
        try:
            size = int(headers.get("Content-Length", "0"))
        except ValueError:
            size = 0
        return {
            "key": key,
            "size": size,
            "etag": headers.get("ETag", "").strip('"'),
            "last_modified": headers.get("Last-Modified", ""),
        }

    def list_objects(self, prefix: str = "") -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        token: str | None = None
        for _ in range(MAX_LIST_PAGES):
            query = {"list-type": "2", "prefix": prefix,
                     "max-keys": str(LIST_PAGE_SIZE)}
            if token:
                query["continuation-token"] = token
            _status, _headers, body = self._request("GET", query=query)
            try:
                root = ET.fromstring(body)
            except ET.ParseError as exc:
                raise CloudNetworkError(
                    f"ListObjectsV2 XML 解析失败：{exc}"
                ) from None
            for node in root:
                if _local_name(node.tag) != "Contents":
                    continue
                item = {_local_name(child.tag): (child.text or "")
                        for child in node}
                try:
                    size = int(item.get("Size", "0"))
                except ValueError:
                    size = 0
                results.append({
                    "key": item.get("Key", ""),
                    "size": size,
                    "last_modified": item.get("LastModified", ""),
                })
            truncated = _find_text(root, "IsTruncated").lower() == "true"
            token = _find_text(root, "NextContinuationToken") or None
            if not truncated or not token:
                break
        return results


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _find_text(root: ET.Element, name: str) -> str:
    for node in root.iter():
        if _local_name(node.tag) == name:
            return (node.text or "").strip()
    return ""


# ---------------------------------------------------------------------------
# 快照打包 / 恢复
# ---------------------------------------------------------------------------
def _archive_dir(
    root: Path,
    max_files: int,
    max_bytes: int,
) -> tuple[bytes, int, int]:
    if root.is_symlink() or not root.is_dir():
        raise CloudSnapshotError(f"本地快照目录不存在或不是普通目录：{root}")

    resolved_root = root.resolve()
    files: list[Path] = []
    total = 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise CloudSnapshotError(f"拒绝打包符号链接：{path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise CloudSnapshotError(f"拒绝打包非普通文件：{path}")
        try:
            path.resolve().relative_to(resolved_root)
        except ValueError:
            raise CloudSnapshotError(f"文件逃逸出快照目录：{path}") from None
        size = path.stat().st_size
        total += size
        if len(files) + 1 > max_files:
            raise CloudSnapshotError(f"文件数超过上限 {max_files}")
        if total > max_bytes:
            raise CloudSnapshotError(f"快照总字节超过上限 {max_bytes}")
        files.append(path)

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.PAX_FORMAT) as tar:
        for path in files:
            arcname = path.relative_to(root).as_posix()
            info = tar.gettarinfo(str(path), arcname=arcname)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            with path.open("rb") as handle:
                tar.addfile(info, handle)
    return buf.getvalue(), len(files), total


def _safe_extract(
    archive: bytes,
    dest: Path,
    max_files: int,
    max_bytes: int,
) -> tuple[int, int]:
    dest_root = dest.resolve()
    dest_root.mkdir(parents=True, exist_ok=True)
    dest_root = dest.resolve()

    count = 0
    written = 0
    try:
        tar = tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz")
    except (tarfile.TarError, OSError) as exc:
        raise CloudSnapshotError(f"快照压缩包损坏：{exc}") from None

    with tar:
        for member in tar:
            name = member.name
            if not name or "\x00" in name:
                raise CloudSnapshotError("快照包含非法空文件名")
            if "\\" in name:
                raise CloudSnapshotError(f"快照包含非法路径分隔符：{name}")
            posix = PurePosixPath(name)
            if posix.is_absolute() or name.startswith("/"):
                raise CloudSnapshotError(f"拒绝绝对路径：{name}")
            if ".." in posix.parts:
                raise CloudSnapshotError(f"拒绝路径穿越：{name}")
            if member.issym() or member.islnk():
                raise CloudSnapshotError(f"拒绝链接文件：{name}")
            if member.ischr() or member.isblk() or member.isfifo() or member.isdev():
                raise CloudSnapshotError(f"拒绝设备/特殊文件：{name}")

            target = (dest_root / posix.as_posix()).resolve()
            if target != dest_root and dest_root not in target.parents:
                raise CloudSnapshotError(f"解包路径越界：{name}")

            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise CloudSnapshotError(f"拒绝未知归档成员类型：{name}")
            count += 1
            if count > max_files:
                raise CloudSnapshotError(f"解包文件数超过上限 {max_files}")
            if member.size < 0 or written + member.size > max_bytes:
                raise CloudSnapshotError(f"解包总字节超过上限 {max_bytes}")

            target.parent.mkdir(parents=True, exist_ok=True)
            source = tar.extractfile(member)
            if source is None:
                raise CloudSnapshotError(f"无法读取归档成员：{name}")
            try:
                with source, target.open("wb") as out:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)
                        written += len(chunk)
            except OSError as exc:
                raise CloudSnapshotError(f"写入失败 {name}：{exc}") from None
            if written > max_bytes:
                raise CloudSnapshotError(f"解包总字节超过上限 {max_bytes}")
    return count, written


# ---------------------------------------------------------------------------
# 公开操作
# ---------------------------------------------------------------------------
def sync_snapshot(
    local_dir: str | Path,
    prefix: str = "",
    *,
    config: CloudConfig | None = None,
    max_files: int = MAX_FILES,
    max_bytes: int = MAX_TOTAL_BYTES,
) -> dict[str, Any]:
    """打包 → 加密 → 上传，返回 ``key / bytes / sha256`` 等真实结果。"""
    cfg = config or CloudConfig.from_env()
    archive, file_count, source_bytes = _archive_dir(
        Path(local_dir), max_files, max_bytes
    )
    blob = _pack_blob(archive, cfg.sync_key)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    name = f"snapshot-{timestamp}.tga"
    cleaned = prefix.strip("/")
    key = f"{cleaned}/{name}" if cleaned else name

    uploaded = CloudClient(cfg).put_object(key, blob)
    return {
        "key": key,
        "bytes": uploaded["bytes"],
        "sha256": uploaded["sha256"],
        "files": file_count,
        "source_bytes": source_bytes,
        "uploaded_at": datetime.now(timezone.utc).isoformat(),
    }


def restore_snapshot(
    object_key: str,
    dest_dir: str | Path,
    *,
    config: CloudConfig | None = None,
    max_files: int = MAX_FILES,
    max_bytes: int = MAX_TOTAL_BYTES,
) -> dict[str, Any]:
    """下载 → 解密 → 安全解包，返回文件数与字节数。"""
    cfg = config or CloudConfig.from_env()
    blob = CloudClient(cfg).get_object(object_key)
    plain = _unpack_blob(blob, cfg.sync_key)
    files, written = _safe_extract(plain, Path(dest_dir), max_files, max_bytes)
    return {"key": object_key, "files": files, "bytes": written}


def list_remote(
    prefix: str = "",
    *,
    config: CloudConfig | None = None,
) -> list[dict[str, Any]]:
    """S3 ListObjectsV2，返回 ``key / size / last_modified``。"""
    cfg = config or CloudConfig.from_env()
    return CloudClient(cfg).list_objects(prefix)


def status(config: CloudConfig | None = None) -> dict[str, Any]:
    """配置自检：只报告是否存在与目标，不输出任何凭据。"""
    cfg = config or CloudConfig.from_env()
    return {
        "configured": True,
        "endpoint": cfg.endpoint,
        "bucket": cfg.bucket,
        "region": cfg.region,
        "sync_key_bytes": len(cfg.sync_key),
        "encryption": "AES-256-GCM",
        "signature": "AWS4-HMAC-SHA256",
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="python -m app.runtime.cloud_sync",
        description="TGA 快照备份与加密云同步（R2/S3）",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="检查配置")
    p_upload = sub.add_parser("upload", help="打包并上传目录")
    p_upload.add_argument("dir")
    p_upload.add_argument("prefix", nargs="?", default="")
    p_download = sub.add_parser("download", help="下载并恢复快照")
    p_download.add_argument("key")
    p_download.add_argument("dir")
    p_list = sub.add_parser("list", help="列出远端快照")
    p_list.add_argument("prefix", nargs="?", default="")

    args = parser.parse_args(argv)
    try:
        cfg = CloudConfig.from_env()
        if args.cmd == "status":
            payload: dict[str, Any] = {"ok": True, **status(cfg)}
        elif args.cmd == "upload":
            payload = {"ok": True, **sync_snapshot(args.dir, args.prefix,
                                                   config=cfg)}
        elif args.cmd == "download":
            payload = {"ok": True, **restore_snapshot(args.key, args.dir,
                                                      config=cfg)}
        else:
            payload = {"ok": True, "prefix": args.prefix,
                       "objects": list_remote(args.prefix, config=cfg)}
    except CloudSyncError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    except OSError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
