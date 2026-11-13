"""版本唯一真源与「定版前冻结」保护。

规则（产品方约定）：
  * 产品版本号唯一真源 = 仓库根 VERSION 文件。
  * 定版前恒为 0.0.1，任何代码不得自行升版本、不得出现 1.0.0 之类产品版本。
  * 各处（Flutter pubspec / 后端包 / 桥能力 / 模型卡 / UI）必须与之严格一致。

注意区分：某些 JSON 里的 "version": "1.0.0" 是**协议/策略文件自身的 schema 版本**
（如 sandbox_policy.json、bridge_contract.json、active.json、channels.json），
不是产品发行版本，不受本冻结约束；assert_version_frozen() 校验产品版本声明点。
"""

from __future__ import annotations

import re
from pathlib import Path

PRODUCT_NAME = "tangram-agent"
FROZEN_VERSION = "0.0.1"

_REPO_ROOT = Path(__file__).resolve().parent.parent


def version_file(root: Path | str | None = None) -> Path:
    return Path(root or _REPO_ROOT) / "VERSION"


def read_version(root: Path | str | None = None) -> str:
    """读取 VERSION 文件；缺失时返回冻结版本（不静默升版本）。"""
    p = version_file(root)
    if not p.is_file():
        return FROZEN_VERSION
    return p.read_text(encoding="utf-8").strip() or FROZEN_VERSION


PRODUCT_VERSION = read_version()

# 产品版本声明点：文件相对路径 -> 用于提取版本的正则（捕获组 1 为版本串）
PRODUCT_VERSION_SITES: dict[str, str] = {
    "VERSION": r"^\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$",
    "frontend/pubspec.yaml": r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)",
    "backend/pyproject.toml": r'^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
    "backend/app/__init__.py": r'^__version__\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
    "frontend/lib/flai/tangram_config.dart": r"appVersion:\s*'([0-9]+\.[0-9]+\.[0-9]+)'",
}


def assert_version_frozen(root: Path | str | None = None) -> str:
    """校验：VERSION == 0.0.1，且所有产品版本声明点都等于它。

    任何漂移（有人手滑改成 0.0.2 / 1.0.0）都会抛 AssertionError，
    让 CI / 构建脚本在定版前直接失败。返回当前版本串。
    """
    base = Path(root or _REPO_ROOT)
    current = read_version(base)
    assert current == FROZEN_VERSION, (
        f"产品版本在定版前必须恒为 {FROZEN_VERSION}，当前 VERSION={current!r}；"
        "如需升版本请先与产品方确认定版"
    )
    mismatches: list[str] = []
    for rel, pattern in PRODUCT_VERSION_SITES.items():
        path = base / rel
        if not path.is_file():
            mismatches.append(f"{rel}: 文件缺失")
            continue
        text = path.read_text(encoding="utf-8")
        m = re.search(pattern, text, re.MULTILINE)
        if not m:
            mismatches.append(f"{rel}: 未找到版本声明")
        elif m.group(1) != current:
            mismatches.append(f"{rel}: {m.group(1)} != {current}")
    assert not mismatches, "产品版本声明不一致：\n  " + "\n  ".join(mismatches)
    return current
