"""测试路径：保证仓库根 / backend 在 sys.path，可 import 真实包。"""

from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for p in (str(_ROOT), str(_ROOT / "backend")):
    if p not in sys.path:
        sys.path.insert(0, p)
