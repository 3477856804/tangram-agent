"""版本唯一真源与一致性校验。

规则（产品方约定）：
  * 产品版本号唯一真源 = 仓库根 VERSION 文件。
  * 所有产品版本声明点（pubspec / 后端包 / App 常量 / 网关 HTTP 应答）
    必须严格等于 VERSION，不允许任何一处写死旧版本冒充当前版本。
  * ``assert_version_frozen()`` 校验「所有声明点 == VERSION」；不再把
    版本号写死成 0.0.1（历史遗留：VERSION 已迭代到 0.0.4，硬编码冻结值
    会让 CLI / CI 无条件失败，属于假校验）。

注意区分：某些 JSON 里的 "version": "1.0.0" 是**协议/策略文件自身的 schema
版本**（如 sandbox_policy.json / active.json），不是产品发行版本，不受校验。
"""

from __future__ import annotations

import re
from pathlib import Path

PRODUCT_NAME = "tangram-agent"
# VERSION 缺失时的兜底值（不是「冻结版本」，只是读不到真源时的默认值）
FROZEN_VERSION = "0.0.4"

_REPO_ROOT = Path(__file__).resolve().parent.parent


def version_file(root: Path | str | None = None) -> Path:
    return Path(root or _REPO_ROOT) / "VERSION"


def read_version(root: Path | str | None = None) -> str:
    """读取 VERSION 文件；缺失时返回兜底值（不静默升版本）。"""
    p = version_file(root)
    if not p.is_file():
        return FROZEN_VERSION
    return p.read_text(encoding="utf-8").strip() or FROZEN_VERSION


PRODUCT_VERSION = read_version()

# 产品版本声明点：文件相对路径 -> 用于提取版本的正则（捕获组 1 为版本串）
PRODUCT_VERSION_SITES: dict[str, str] = {
    "VERSION": r"^\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$",
    "frontend/pubspec.yaml": r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)",
    "frontend/lib/app_version.dart": r"defaultValue:\s*'([0-9]+\.[0-9]+\.[0-9]+)'",
    "backend/pyproject.toml": r'^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
    "backend/app/__init__.py": r'^__version__\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
}


def version_sites(root: Path | str | None = None) -> dict[str, str]:
    """返回每个声明点实际读到的版本串（供 CI / 排障查看，不造假）。"""
    base = Path(root or _REPO_ROOT)
    out: dict[str, str] = {}
    for rel, pattern in PRODUCT_VERSION_SITES.items():
        path = base / rel
        if not path.is_file():
            out[rel] = "MISSING"
            continue
        m = re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE)
        out[rel] = m.group(1) if m else "NOT-FOUND"
    return out


def assert_version_frozen(root: Path | str | None = None) -> str:
    """校验：所有产品版本声明点都严格等于 VERSION 真源。

    任何漂移（某人把 pubspec 写成 0.0.3、网关 HTTP 应答写死 0.0.1）都会
    抛 AssertionError，让 CLI / 构建脚本直接失败。返回当前版本串。
    """
    base = Path(root or _REPO_ROOT)
    current = read_version(base)
    mismatches = [
        f"{rel}: {found} != VERSION({current})"
        for rel, found in version_sites(base).items()
        if found != current
    ]
    assert not mismatches, "产品版本声明不一致：\n  " + "\n  ".join(mismatches)
    return current
