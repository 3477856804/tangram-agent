"""Tangram 本地后端发行包。

运行入口：``python backend/main.py --chat`` / ``--bridge tcp``。
兼容两种导入形态：仓库根 ``import backend`` 与 ``cd backend`` 后 ``import app``。
"""

try:  # 作为包导入（仓库根在 sys.path）
    from .app import __version__  # type: ignore
except ImportError:  # 以 backend/ 为运行目录
    from app import __version__  # type: ignore  # noqa: F401

__all__ = ["__version__"]
