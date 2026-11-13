"""Tangram IM 网关局域网发现（仅标准库）。

解决「手机 APP 点连接就要出二维码、但不必先填网关地址」的问题：

- 网关进程在 ``DISCOVERY_PORT`` 上监听广播/单播 ``DISCOVER`` 报文；
  收到后回一个 ``TANGRAM_GW|<version>|<http_port>`` 单播响应。
- APP 侧 ``discover(timeout)`` 向局域网广播域发 ``DISCOVER``，收集第一个
  合法响应，拼出 ``http://<网关IP>:<http_port>`` 作为真实网关地址。

设计约束：
- 只用 ``socket`` 标准库，不引入第三方依赖；
- 只做「发现」，不下发任何凭据、不伪造二维码；拿到地址后仍走原有
  ``/api/login/*/qr`` 真扫码链路；
- 失败返回 ``None``，由调用方降级到高级设置手填，绝不编造地址。
- 可用 ``TANGRAM_DISCOVERY=0`` 关闭服务端监听（如公网部署不需要局域网发现）。
"""

from __future__ import annotations

import json
import os
import socket
import threading
import time

DISCOVERY_PORT = int(os.environ.get("TANGRAM_DISCOVERY_PORT", "50433"))
_MAGIC = "TANGRAM_DISCOVER"
_RESP_PREFIX = "TANGRAM_GW|"
_BROADCAST = "255.255.255.255"


def _interfaces() -> list[str]:
    """返回本机局域网 IPv4（排除回环），用于定向单播响应。"""
    hosts: set[str] = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                hosts.add(ip)
    except OSError:
        pass
    # UDP 连接法取出口网卡地址（不真正发包）
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        hosts.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(hosts)


class DiscoveryServer:
    """网关侧：在后台线程应答局域网发现请求。"""

    def __init__(self, http_port: int, version: str = "0.0.1") -> None:
        self.http_port = http_port
        self.version = version
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> bool:
        """启动监听；端口被占用或环境禁用时返回 False（不影响网关主功能）。"""
        if os.environ.get("TANGRAM_DISCOVERY", "1") == "0":
            return False
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.bind(("0.0.0.0", DISCOVERY_PORT))
            sock.settimeout(1.0)
        except OSError:
            return False
        self._sock = sock
        self._thread = threading.Thread(
            target=self._loop, daemon=True, name="gw-discovery")
        self._thread.start()
        return True

    def _loop(self) -> None:
        assert self._sock is not None
        while True:
            try:
                data, addr = self._sock.recvfrom(256)
            except socket.timeout:
                continue
            except OSError:
                return
            if data.decode("utf-8", "replace").strip() != _MAGIC:
                continue
            payload = f"{_RESP_PREFIX}{self.version}|{self.http_port}"
            try:
                # 单播回请求方，避免广播风暴；addr[0] 是 APP 在局域网的 IP。
                self._sock.sendto(payload.encode("utf-8"), addr)
            except OSError:
                continue

    def stop(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None


def discover(timeout: float = 2.5) -> dict | None:
    """APP 侧：在局域网内探测网关。

    返回 ``{"url": "http://<ip>:<port>", "version": "0.0.1"}``；
    无网关在线或平台禁止广播时返回 ``None``（调用方负责降级）。
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(0.4)
    except OSError:
        return None
    try:
        sock.sendto(_MAGIC.encode("utf-8"), (_BROADCAST, DISCOVERY_PORT))
    except OSError:
        # 部分网络禁广播：退回本机回环单播（同机调试 / 网关与 APP 同设备时可用）
        try:
            sock.sendto(_MAGIC.encode("utf-8"), ("127.0.0.1", DISCOVERY_PORT))
        except OSError:
            return None
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            try:
                data, addr = sock.recvfrom(256)
            except socket.timeout:
                continue
            except OSError:
                break
            text = data.decode("utf-8", "replace").strip()
            if not text.startswith(_RESP_PREFIX):
                continue
            parts = text[len(_RESP_PREFIX):].split("|")
            if len(parts) < 2:
                continue
            version, port_s = parts[0], parts[1]
            try:
                port = int(port_s)
            except ValueError:
                continue
            return {"url": f"http://{addr[0]}:{port}", "version": version}
    finally:
        sock.close()
    return None


def self_check() -> dict:
    """本机自测：起一个服务端再发现一次，验证全链路（不联网、不扫码）。"""
    srv = DiscoveryServer(http_port=50432, version="0.0.1")
    if not srv.start():
        return {"ok": False, "reason": "端口占用或 TANGRAM_DISCOVERY=0"}
    try:
        found = discover(timeout=2.0)
    finally:
        srv.stop()
    return {"ok": found is not None, "found": found, "local_ips": _interfaces()}


if __name__ == "__main__":
    print(json.dumps(self_check(), ensure_ascii=False))
