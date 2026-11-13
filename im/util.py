"""IM 网关公共工具：惰性网络客户端与降级辅助（仅标准库）。

约束：import 阶段禁止联网；所有网络/外部依赖均在使用时惰性导入，
且在不可用时降级为空操作并返回可读错误原因，避免阻塞主流程。
"""

from __future__ import annotations

import json
import time
from typing import Any, Optional


class NetClient:
    """惰性网络客户端：仅使用标准库 urllib，无网络时降级。

    沙箱策略默认禁止直接出站（需经 Flutter 代发白名单），因此本客户端
    在请求失败或库不可用时返回 (None, reason)，由调用方决定降级行为，
    绝不抛异常中断网关运行。
    """

    def __init__(self, base_url: str = "", timeout: float = 8.0) -> None:
        self.base_url = base_url
        self.timeout = timeout
        self.enabled = True
        self._lib: Optional[tuple[Any, Any]] = None

    def _ensure(self) -> Optional[tuple[Any, Any]]:
        """惰性导入 urllib；失败则标记禁用。"""
        if self._lib is not None:
            return self._lib
        try:
            import urllib.request as req  # noqa: PLC0415
            import urllib.error as err  # noqa: PLC0415
            self._lib = (req, err)
        except Exception:  # pragma: no cover - 标准库极难缺失
            self.enabled = False
            self._lib = None
        return self._lib

    def post_json(
        self, path: str, payload: dict[str, Any], headers: Optional[dict[str, str]] = None
    ) -> tuple[Optional[Any], str]:
        """发起 JSON POST；返回 (响应体对象 | None, 状态/错误原因)。"""
        lib = self._ensure()
        if lib is None or not self.enabled:
            return None, "network-degraded"
        req_mod, err_mod = lib
        try:
            url = path if path.startswith("http") else (self.base_url.rstrip("/") + "/" + path.lstrip("/"))
            data = json.dumps(payload).encode("utf-8")
            hdrs = {"Content-Type": "application/json", "Accept": "application/json"}
            if headers:
                hdrs.update(headers)
            request = req_mod.Request(url, data=data, headers=hdrs, method="POST")
            with req_mod.urlopen(request, timeout=self.timeout) as resp:  # noqa: S310
                body = resp.read().decode("utf-8", "replace")
            return json.loads(body), "ok"
        except err_mod.HTTPError as exc:  # 服务端明确拒绝
            return None, f"http-error:{exc.code}"
        except Exception as exc:  # 网络不可达 / 超时 / 沙箱拦截 / 非法 URL 均降级
            return None, f"network-error:{type(exc).__name__}"

    def get_json(
        self, path: str, params: Optional[dict[str, str]] = None,
        headers: Optional[dict[str, str]] = None,
    ) -> tuple[Optional[Any], str]:
        """发起 JSON GET（带可选查询参数与请求头）。"""
        import urllib.parse as up  # noqa: PLC0415

        lib = self._ensure()
        if lib is None or not self.enabled:
            return None, "network-degraded"
        req_mod, err_mod = lib
        try:
            url = path if path.startswith("http") else (self.base_url.rstrip("/") + "/" + path.lstrip("/"))
            if params:
                url = url + "?" + up.urlencode(params)
            hdrs = {"Accept": "application/json"}
            if headers:
                hdrs.update(headers)
            request = req_mod.Request(url, headers=hdrs, method="GET")
            with req_mod.urlopen(request, timeout=self.timeout) as resp:  # noqa: S310
                body = resp.read().decode("utf-8", "replace")
            return json.loads(body), "ok"
        except err_mod.HTTPError as exc:
            return None, f"http-error:{exc.code}"
        except Exception as exc:
            return None, f"network-error:{type(exc).__name__}"


def now_ts() -> float:
    """当前时间戳（秒）。"""
    return time.time()
