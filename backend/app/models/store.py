"""真实模型商店：魔搭 ModelScope 在线检索 + 仓库文件清单。

``im/serve.py`` 的 ``GET /api/models/store`` 此前 import 不存在的
``app.models.store``，接口直接 500。现在改为真实调用魔搭公开 API：

* ``search_models(query)`` → ``PUT https://www.modelscope.cn/api/v1/dolphin/models``
  （实测真实搜索参数是 ``Name``，只传 ``Query`` 会返回热门榜）。
* ``model_files(model_path)`` → ``GET /api/v1/models/{path}/repo/files``，
  返回真实文件名、大小与 Sha256。

网络失败 / 结构异常抛 :class:`ModelStoreError`，由 HTTP 层如实回 502，
不返回任何内置假榜单。测试可注入 ``opener`` 做离线验证。
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from typing import Callable, Optional

__all__ = ["ModelStoreError", "search_models", "model_files"]

_SEARCH_URL = "https://www.modelscope.cn/api/v1/dolphin/models"
_FILES_URL = "https://www.modelscope.cn/api/v1/models/{path}/repo/files"
_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0"


class ModelStoreError(RuntimeError):
    """模型商店请求失败（网络 / 结构 / 参数），不放假数据。"""


def _request(url: str, *, method: str = "GET", body: Optional[dict] = None,
             timeout: float = 12.0,
             opener: Optional[Callable] = None) -> dict:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": _UA},
        method=method,
    )
    try:
        fn = opener or (lambda r, t: urllib.request.urlopen(r, timeout=t))
        with fn(req, timeout) as resp:
            raw = resp.read()
        return json.loads(raw.decode("utf-8", "replace"))
    except Exception as exc:  # noqa: BLE001 - 网络失败如实上报
        raise ModelStoreError(f"魔搭接口请求失败：{type(exc).__name__}: {exc}") from exc


def search_models(query: str, *, timeout: float = 12.0,
                  opener: Optional[Callable] = None) -> list[dict]:
    """按关键词搜索真实模型仓库；返回真实仓库列表（可能为空）。"""
    q = (query or "").strip()
    payload = {
        "Name": q,
        "Query": q,
        "PageSize": 20,
        "PageNumber": 1,
        "Sort": "Default",
    }
    data = _request(_SEARCH_URL, method="PUT", body=payload,
                    timeout=timeout, opener=opener)
    if not isinstance(data, dict):
        raise ModelStoreError("魔搭搜索返回结构异常（顶层不是对象）")
    model = (data.get("Data") or {}).get("Model") if isinstance(data.get("Data"), dict) else None
    rows = model.get("Models") if isinstance(model, dict) else None
    if not isinstance(rows, list):
        raise ModelStoreError("魔搭搜索返回结构异常（缺少 Data.Model.Models）")
    out: list[dict] = []
    for e in rows:
        if not isinstance(e, dict):
            continue
        owner = str(e.get("Path") or e.get("Namespace") or "")
        name = str(e.get("Name") or "")
        if not owner or not name:
            continue
        tasks = []
        raw_tasks = e.get("Tasks")
        if isinstance(raw_tasks, list):
            for t in raw_tasks:
                if isinstance(t, dict):
                    label = str(t.get("ChineseName") or t.get("Name") or "").strip()
                    if label:
                        tasks.append(label)
        out.append({
            "path": f"{owner}/{name}",
            "name": name,
            "chinese_name": str(e.get("ChineseName") or ""),
            "owner": owner,
            "downloads": e.get("Downloads") if isinstance(e.get("Downloads"), int) else 0,
            "likes": e.get("Likes") if isinstance(e.get("Likes"), int) else 0,
            "tasks": tasks,
            "tags": [str(t) for t in e.get("Tags")] if isinstance(e.get("Tags"), list) else [],
            "url": f"https://www.modelscope.cn/models/{owner}/{name}",
        })
    return out


def model_files(model_path: str, *, timeout: float = 12.0,
                opener: Optional[Callable] = None) -> list[dict]:
    """列出真实仓库文件（递归），返回文件名 / 大小 / Sha256。"""
    mp = (model_path or "").strip().strip("/")
    if not mp or ".." in mp:
        raise ModelStoreError("model_path 非法")
    query = urllib.parse.urlencode({"Revision": "master", "Recursive": "True"})
    url = _FILES_URL.format(path=urllib.parse.quote(mp, safe="/")) + "?" + query
    data = _request(url, timeout=timeout, opener=opener)
    if not isinstance(data, dict):
        raise ModelStoreError("文件清单返回结构异常")
    rows = ((data.get("Data") or {}).get("Files")
            if isinstance(data.get("Data"), dict) else None)
    if not isinstance(rows, list):
        raise ModelStoreError("文件清单返回结构异常（缺少 Data.Files）")
    out: list[dict] = []
    for f in rows:
        if not isinstance(f, dict):
            continue
        name = str(f.get("Path") or f.get("Name") or "")
        if not name:
            continue
        out.append({
            "name": name,
            "size": f.get("Size") if isinstance(f.get("Size"), (int, float)) else 0,
            "sha256": str(f.get("Sha256") or ""),
            "type": str(f.get("Type") or ""),
        })
    return out
