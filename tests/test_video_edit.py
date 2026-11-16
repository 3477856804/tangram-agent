"""视频剪辑真实管线回归：生成合成素材，真实调用 ffmpeg。"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from backend.app.runtime.video_edit import (
    VideoEditError,
    auto_edit,
    concat,
    probe,
    scene_times,
    trim,
)

pytestmark = pytest.mark.skipif(
    not (shutil.which("ffmpeg") and shutil.which("ffprobe")),
    reason="需要系统 ffmpeg/ffprobe",
)


def _make_clip(path: Path, color: str, seconds: int = 1) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            f"color=c={color}:s=320x240:r=24:d={seconds}",
            "-pix_fmt",
            "yuv420p",
            str(path),
        ],
        check=True,
    )


def test_probe_trim_concat_auto(tmp_path: Path) -> None:
    a = tmp_path / "a.mp4"
    b = tmp_path / "b.mp4"
    _make_clip(a, "red", 2)
    _make_clip(b, "blue", 2)

    info = probe(a)
    assert info["width"] == 320
    assert info["height"] == 240
    assert info["duration"] > 1.5

    cut = trim(a, tmp_path / "cut.mp4", 0.5, 1.0)
    assert cut["ok"] is True
    assert Path(cut["output"]).is_file()
    assert 0.5 < cut["duration"] < 1.8

    joined = concat([a, b], tmp_path / "joined.mp4", width=320, height=240, fps=24)
    assert joined["clips"] == 2
    assert joined["duration"] > 3.0

    final = auto_edit([a, b], tmp_path / "final.mp4", width=320, height=240, fps=24)
    assert final["ok"] is True
    assert Path(final["output"]).is_file()
    assert final["info"]["duration"] > 3.0
    times = scene_times(joined["output"], threshold=0.1)
    assert isinstance(times, list)


def test_missing_input_reports_real_error(tmp_path: Path) -> None:
    with pytest.raises(VideoEditError):
        probe(tmp_path / "nope.mp4")
    with pytest.raises(VideoEditError):
        trim(tmp_path / "nope.mp4", tmp_path / "x.mp4", 0)
