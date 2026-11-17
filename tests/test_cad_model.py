"""build123d 参数化建模：依赖存在时真实建模导出，缺失时明确报错。"""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

from backend.app.runtime.cad_model import CadError, available, model


def _has_build123d() -> bool:
    return importlib.util.find_spec("build123d") is not None


def test_dependency_probe_is_honest() -> None:
    info = available()
    if _has_build123d():
        assert info["ok"] is True
        assert info["available"] is True
        assert info["version"]
    else:
        assert info["ok"] is False
        assert info["available"] is False
        assert "build123d" in info["error"]


def test_missing_dependency_raises_not_fake_model(tmp_path: Path) -> None:
    if _has_build123d():
        pytest.skip("本环境已安装 build123d，改由真实建模用例覆盖")
    with pytest.raises(CadError, match="build123d"):
        model({"type": "box", "length": 10, "width": 10, "height": 10},
              tmp_path / "box.stl")


@pytest.mark.skipif(not _has_build123d(), reason="需要 build123d/OCCT")
def test_box_and_boolean_real_export(tmp_path: Path) -> None:
    spec = {
        "type": "box",
        "length": 20,
        "width": 20,
        "height": 10,
        "children": [
            {"type": "cylinder", "radius": 4, "height": 10,
             "boolean": "subtract"},
        ],
    }
    out = tmp_path / "part.stl"
    result = model(spec, out, "stl")
    assert result["ok"] is True
    assert out.is_file() and out.stat().st_size > 0
    info = result["info"]
    assert info["volume"] > 0
    assert info["faces"] > 0
    assert info["bbox"]["size"][0] == pytest.approx(20, abs=1e-3)

    step = tmp_path / "part.step"
    result2 = model({"type": "sphere", "radius": 5}, step, "step")
    assert result2["format"] == "step"
    assert step.is_file() and step.stat().st_size > 0


@pytest.mark.skipif(not _has_build123d(), reason="需要 build123d/OCCT")
def test_unknown_primitive_rejected(tmp_path: Path) -> None:
    with pytest.raises(CadError, match="未知图元"):
        model({"type": "torus", "radius": 5}, tmp_path / "x.stl")
