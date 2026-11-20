"""快照加密云同步：AES-GCM / SigV4 / 本地 S3 模拟端到端回归。

运行：``python3 -m pytest tests/test_cloud_sync.py -q``
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import tarfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from xml.sax.saxutils import escape

import pytest

# cryptography 是云端快照的可选依赖（见 backend/app/runtime/cloud_sync.py）：
# 未安装时本模块的加解密测试跳过，不阻塞整套测试收集。
pytest.importorskip("cryptography")

from backend.app.runtime.cloud_sync import (
    EMPTY_SHA256,
    CloudClient,
    CloudConfig,
    CloudConfigError,
    CloudCryptoError,
    CloudSnapshotError,
    canonical_path,
    decrypt_bytes,
    encrypt_bytes,
    list_remote,
    main,
    restore_snapshot,
    sign_request,
    sync_snapshot,
)

BUCKET = "tga-test"


# ---------------------------------------------------------------------------
# 本地 S3 模拟端
# ---------------------------------------------------------------------------
class _MockS3(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), _Handler)
        self.bucket = BUCKET
        self.objects: dict[str, bytes] = {}
        self.requests: list[dict] = []


class _Handler(BaseHTTPRequestHandler):
    server: _MockS3

    def log_message(self, *args) -> None:  # noqa: D401 - 静默测试日志
        pass

    def _record(self) -> None:
        self.server.requests.append({
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
        })

    def _split(self) -> tuple[str | None, bool]:
        parsed = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(parsed.path)
        base = f"/{self.server.bucket}"
        if path in (base, base + "/"):
            return None, True
        if not path.startswith(base + "/"):
            return None, False
        return path[len(base) + 1:], True

    def _send(self, status: int, body: bytes = b"",
              headers: dict[str, str] | None = None) -> None:
        headers = dict(headers or {})
        length = headers.pop("Content-Length", str(len(body)))
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        self.send_header("Content-Length", length)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def do_PUT(self) -> None:  # noqa: N802
        self._record()
        key, ok = self._split()
        if not ok or key is None:
            self._send(400, b"<Error><Code>InvalidPath</Code></Error>")
            return
        length = int(self.headers.get("Content-Length", "0"))
        self.server.objects[key] = self.rfile.read(length)
        digest = hashlib.sha256(self.server.objects[key]).hexdigest()
        self._send(200, headers={"ETag": f'"{digest}"'})

    def do_GET(self) -> None:  # noqa: N802
        self._record()
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        key, ok = self._split()
        if not ok:
            self._send(404, b"<Error><Code>NoSuchBucket</Code></Error>")
            return
        if key is None or query.get("list-type") == ["2"]:
            prefix = (query.get("prefix") or [""])[0]
            items = sorted(
                (k, v) for k, v in self.server.objects.items()
                if k.startswith(prefix)
            )
            contents = "".join(
                "<Contents>"
                f"<Key>{escape(name)}</Key>"
                "<LastModified>2026-11-17T00:00:00.000Z</LastModified>"
                f"<ETag>\"{hashlib.sha256(data).hexdigest()}\"</ETag>"
                f"<Size>{len(data)}</Size>"
                "<StorageClass>STANDARD</StorageClass>"
                "</Contents>"
                for name, data in items
            )
            xml = (
                '<?xml version="1.0" encoding="UTF-8"?>'
                '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                f"<Name>{self.server.bucket}</Name><Prefix>{escape(prefix)}</Prefix>"
                f"<KeyCount>{len(items)}</KeyCount><MaxKeys>1000</MaxKeys>"
                "<IsTruncated>false</IsTruncated>"
                f"{contents}</ListBucketResult>"
            ).encode("utf-8")
            self._send(200, xml, {"Content-Type": "application/xml"})
            return
        if key not in self.server.objects:
            self._send(404, b"<Error><Code>NoSuchKey</Code></Error>")
            return
        self._send(200, self.server.objects[key])

    def do_HEAD(self) -> None:  # noqa: N802
        self._record()
        key, ok = self._split()
        if not ok or key is None or key not in self.server.objects:
            self._send(404)
            return
        data = self.server.objects[key]
        self._send(200, headers={
            "Content-Length": str(len(data)),
            "ETag": f'"{hashlib.sha256(data).hexdigest()}"',
            "Last-Modified": "Mon, 17 Nov 2026 00:00:00 GMT",
        })


@pytest.fixture
def mock_s3():
    server = _MockS3()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


@pytest.fixture
def sync_key() -> bytes:
    return bytes(range(32))


@pytest.fixture
def cloud_env(monkeypatch, mock_s3, sync_key):
    port = mock_s3.server_address[1]
    values = {
        "TGA_R2_ENDPOINT": f"http://127.0.0.1:{port}",
        "TGA_R2_BUCKET": BUCKET,
        "TGA_R2_ACCESS_KEY": "AKIAIOSFODNN7EXAMPLE",
        "TGA_R2_SECRET_KEY": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "TGA_SYNC_KEY": base64.b64encode(sync_key).decode("ascii"),
    }
    for name, value in values.items():
        monkeypatch.setenv(name, value)
    return {"endpoint": values["TGA_R2_ENDPOINT"], "key": sync_key,
            "env": values, "server": mock_s3}


# ---------------------------------------------------------------------------
# AES-256-GCM
# ---------------------------------------------------------------------------
def test_aes_gcm_roundtrip(sync_key):
    plain = " Tangram 快照 ".encode("utf-8") * 100
    nonce, ciphertext = encrypt_bytes(plain, sync_key)
    assert len(nonce) == 12
    assert ciphertext != plain
    assert decrypt_bytes(nonce, ciphertext, sync_key) == plain

    nonce2, ct2 = encrypt_bytes(b"", sync_key)
    assert nonce2 != nonce
    assert decrypt_bytes(nonce2, ct2, sync_key) == b""


def test_aes_gcm_tampered_ciphertext_fails(sync_key):
    nonce, ciphertext = encrypt_bytes(b"secret snapshot", sync_key)
    tampered = bytearray(ciphertext)
    tampered[-1] ^= 0x01
    with pytest.raises(CloudCryptoError):
        decrypt_bytes(nonce, bytes(tampered), sync_key)


def test_aes_gcm_wrong_key_fails(sync_key):
    nonce, ciphertext = encrypt_bytes(b"secret snapshot", sync_key)
    with pytest.raises(CloudCryptoError):
        decrypt_bytes(nonce, ciphertext, b"\x00" * 32)


def test_aes_gcm_rejects_bad_key_size():
    with pytest.raises(CloudCryptoError):
        encrypt_bytes(b"x", b"short")


# ---------------------------------------------------------------------------
# AWS Signature V4：官方测试向量
# ---------------------------------------------------------------------------
def test_sigv4_matches_aws_get_object_vector():
    headers = sign_request(
        "GET",
        "https://examplebucket.s3.amazonaws.com/test.txt",
        EMPTY_SHA256,
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region="us-east-1",
        amz_date="20130524T000000Z",
        extra_headers={"Range": "bytes=0-9"},
    )
    auth = headers["Authorization"]
    assert auth.startswith("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/")
    assert "/20130524/us-east-1/s3/aws4_request" in auth
    assert "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date" in auth
    assert auth.endswith(
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    )
    assert headers["x-amz-content-sha256"] == EMPTY_SHA256
    assert headers["x-amz-date"] == "20130524T000000Z"
    assert headers["Host"] == "examplebucket.s3.amazonaws.com"


def test_sigv4_matches_aws_put_object_vector():
    body = b"Welcome to Amazon S3."
    headers = sign_request(
        "PUT",
        "https://examplebucket.s3.amazonaws.com/test$file.text",
        hashlib.sha256(body).hexdigest(),
        "AKIAIOSFODNN7EXAMPLE",
        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region="us-east-1",
        amz_date="20130524T000000Z",
        extra_headers={
            "Date": "Fri, 24 May 2013 00:00:00 GMT",
            "x-amz-storage-class": "REDUCED_REDUNDANCY",
        },
    )
    auth = headers["Authorization"]
    assert "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;" \
           "x-amz-storage-class" in auth
    assert auth.endswith(
        "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
    )
    assert headers["x-amz-content-sha256"] == hashlib.sha256(body).hexdigest()


def test_path_and_query_encoding():
    assert canonical_path("/bucket/a b/中文.txt") == \
        "/bucket/a%20b/%E4%B8%AD%E6%96%87.txt"
    headers = sign_request(
        "GET",
        "https://examplebucket.s3.amazonaws.com/test%20file.txt?prefix=a%20b&list-type=2",
        EMPTY_SHA256,
        "AK",
        "SK",
        region="us-east-1",
        amz_date="20130524T000000Z",
    )
    assert "SignedHeaders=host;x-amz-content-sha256;x-amz-date" in \
        headers["Authorization"]
    assert headers["Host"] == "examplebucket.s3.amazonaws.com"


# ---------------------------------------------------------------------------
# 配置：缺失时报错且不泄露密钥
# ---------------------------------------------------------------------------
def _clear_env(monkeypatch) -> None:
    for name in ("TGA_R2_ENDPOINT", "TGA_R2_BUCKET", "TGA_R2_ACCESS_KEY",
                 "TGA_R2_SECRET_KEY", "TGA_SYNC_KEY"):
        monkeypatch.delenv(name, raising=False)


def test_missing_config_raises_without_leaking(monkeypatch):
    _clear_env(monkeypatch)
    with pytest.raises(CloudConfigError) as exc:
        CloudConfig.from_env()
    message = str(exc.value)
    assert "TGA_R2_ENDPOINT" in message
    assert "TGA_SYNC_KEY" in message

    secret = "SUPER_SECRET_VALUE_DO_NOT_LEAK"
    monkeypatch.setenv("TGA_R2_BUCKET", "b")
    monkeypatch.setenv("TGA_R2_ACCESS_KEY", "ACCESS")
    monkeypatch.setenv("TGA_R2_SECRET_KEY", secret)
    monkeypatch.setenv("TGA_SYNC_KEY", secret)
    with pytest.raises(CloudConfigError) as exc:
        CloudConfig.from_env()
    message = str(exc.value)
    assert "TGA_R2_ENDPOINT" in message
    assert secret not in message


def test_invalid_sync_key_does_not_leak_value(monkeypatch):
    _clear_env(monkeypatch)
    monkeypatch.setenv("TGA_R2_ENDPOINT", "https://example.invalid")
    monkeypatch.setenv("TGA_R2_BUCKET", "bucket")
    monkeypatch.setenv("TGA_R2_ACCESS_KEY", "access")
    monkeypatch.setenv("TGA_R2_SECRET_KEY", "secret")
    monkeypatch.setenv("TGA_SYNC_KEY", "SECRET-not-base64")

    with pytest.raises(CloudConfigError) as exc:
        CloudConfig.from_env()
    assert "TGA_SYNC_KEY" in str(exc.value)
    assert "SECRET-not-base64" not in str(exc.value)

    monkeypatch.setenv("TGA_SYNC_KEY", base64.b64encode(b"too-short").decode())
    with pytest.raises(CloudConfigError):
        CloudConfig.from_env()


# ---------------------------------------------------------------------------
# 端到端：upload → list → download
# ---------------------------------------------------------------------------
def _write_tree(root: Path) -> dict[str, bytes]:
    files = {
        "a.txt": b"hello tangram",
        "nested/b.bin": bytes(range(256)) * 8,
        "空 格.txt": "中文内容".encode("utf-8"),
    }
    for name, data in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return files


def test_upload_list_download_roundtrip(tmp_path, cloud_env):
    source = tmp_path / "source"
    source.mkdir()
    files = _write_tree(source)

    result = sync_snapshot(source, "backups/test")
    key = result["key"]
    assert key.startswith("backups/test/snapshot-")
    assert key.endswith(".tga")
    assert result["files"] == len(files)
    assert result["source_bytes"] == sum(len(v) for v in files.values())

    stored = cloud_env["server"].objects[key]
    assert stored.startswith(b"TGA1")
    assert result["bytes"] == len(stored)
    assert result["sha256"] == hashlib.sha256(stored).hexdigest()
    assert b"hello tangram" not in stored  # 确实加密，不是明文
    assert len(stored) > 4 + 12 + 16

    # 请求确实使用 SigV4 与百分号编码路径
    put_requests = [r for r in cloud_env["server"].requests
                    if r["method"] == "PUT"]
    assert put_requests
    auth = put_requests[-1]["headers"]["authorization"]
    assert auth.startswith("AWS4-HMAC-SHA256 Credential=")
    assert "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date" \
        in auth

    remote = list_remote("backups/")
    assert len(remote) == 1
    assert remote[0]["key"] == key
    assert remote[0]["size"] == len(stored)
    assert remote[0]["last_modified"].startswith("2026-11-17T")
    assert list_remote("other/") == []

    config = CloudConfig.from_env()
    head = CloudClient(config).head_object(key)
    assert head["size"] == len(stored)
    assert head["etag"] == result["sha256"]

    dest = tmp_path / "restored"
    stats = restore_snapshot(key, dest)
    assert stats["files"] == len(files)
    assert stats["bytes"] == sum(len(v) for v in files.values())
    for name, data in files.items():
        assert (dest / name).read_bytes() == data


def test_client_percent_encodes_object_key(cloud_env):
    config = CloudConfig.from_env()
    key = "目录/a b.txt"
    result = CloudClient(config).put_object(key, b"encoded path")
    assert result["sha256"] == hashlib.sha256(b"encoded path").hexdigest()
    assert cloud_env["server"].objects[key] == b"encoded path"
    request = [r for r in cloud_env["server"].requests
               if r["method"] == "PUT"][-1]
    assert "/%E7%9B%AE%E5%BD%95/a%20b.txt" in request["path"]


def test_restore_detects_tampered_object(tmp_path, cloud_env):
    source = tmp_path / "source"
    source.mkdir()
    (source / "a.txt").write_bytes(b"original")
    result = sync_snapshot(source, "backups")

    blob = bytearray(cloud_env["server"].objects[result["key"]])
    blob[-1] ^= 0x01
    cloud_env["server"].objects[result["key"]] = bytes(blob)

    with pytest.raises(CloudCryptoError):
        restore_snapshot(result["key"], tmp_path / "restore")


# ---------------------------------------------------------------------------
# 解包安全：绝对路径 / .. 穿越 / 链接
# ---------------------------------------------------------------------------
def _encrypted_tar(members: list[tarfile.TarInfo],
                   payloads: list[bytes], key: bytes) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for info, payload in zip(members, payloads):
            tar.addfile(info, io.BytesIO(payload) if payload else None)
    nonce, ciphertext = encrypt_bytes(buf.getvalue(), key)
    return b"TGA1" + nonce + ciphertext


@pytest.mark.parametrize("name", [
    "../evil.txt",
    "nested/../../evil.txt",
    "/tmp/tga-absolute-evil.txt",
])
def test_restore_rejects_path_traversal(tmp_path, cloud_env, name):
    info = tarfile.TarInfo(name)
    data = b"pwned"
    info.size = len(data)
    key = "malicious.tga"
    cloud_env["server"].objects[key] = _encrypted_tar(
        [info], [data], cloud_env["key"]
    )

    dest = tmp_path / "restore"
    with pytest.raises(CloudSnapshotError):
        restore_snapshot(key, dest)
    assert not (tmp_path / "evil.txt").exists()
    assert not Path("/tmp/tga-absolute-evil.txt").exists()


def test_restore_rejects_symlink_member(tmp_path, cloud_env):
    info = tarfile.TarInfo("link")
    info.type = tarfile.SYMTYPE
    info.linkname = "/etc/passwd"
    key = "symlink.tga"
    cloud_env["server"].objects[key] = _encrypted_tar(
        [info], [b""], cloud_env["key"]
    )
    with pytest.raises(CloudSnapshotError):
        restore_snapshot(key, tmp_path / "restore")


def test_snapshot_rejects_symlink_escape(tmp_path, cloud_env):
    source = tmp_path / "source"
    source.mkdir()
    (source / "ok.txt").write_bytes(b"ok")
    outside = tmp_path / "outside.txt"
    outside.write_bytes(b"secret")
    os.symlink(outside, source / "leak.txt")

    with pytest.raises(CloudSnapshotError):
        sync_snapshot(source, "backups")
    assert not cloud_env["server"].objects


def test_snapshot_file_limit(tmp_path, cloud_env):
    source = tmp_path / "source"
    source.mkdir()
    (source / "a").write_bytes(b"1")
    (source / "b").write_bytes(b"2")
    with pytest.raises(CloudSnapshotError):
        sync_snapshot(source, "backups", max_files=1)
    assert not cloud_env["server"].objects


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def test_cli_fails_nonzero_and_outputs_json_without_config(monkeypatch, capsys):
    _clear_env(monkeypatch)
    assert main(["status"]) == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["ok"] is False
    assert "TGA_R2_ENDPOINT" in payload["error"]


def test_cli_status_hides_secrets(cloud_env, capsys):
    assert main(["status"]) == 0
    out = capsys.readouterr().out
    payload = json.loads(out)
    assert payload["ok"] is True
    assert payload["bucket"] == BUCKET
    assert payload["sync_key_bytes"] == 32
    assert cloud_env["env"]["TGA_R2_SECRET_KEY"] not in out
    assert cloud_env["env"]["TGA_SYNC_KEY"] not in out
