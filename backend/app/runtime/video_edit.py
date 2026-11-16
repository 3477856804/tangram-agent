"""TGA 沙箱视频剪辑真实管线。

只依赖系统 ffmpeg / ffprobe（Alpine 内 `apk add ffmpeg` 即可），不引入其它业务
语言。所有函数都通过真实子进程执行，失败时抛出 [VideoEditError] 并带回
stderr 摘要；没有 ffmpeg 就明确报错，绝不返回假的“已导出”。

能力：
  * probe          读取真实时长 / 分辨率 / 编码
  * trim           精确裁剪（重编码，避免关键帧错位）
  * concat         统一分辨率与帧率后拼接
  * burn_subtitles 烧录 SRT 字幕
  * add_music      叠加背景音乐并做音量混合
  * auto_edit      素材归集 → 统一规格 → 粗剪拼接 → 字幕/配乐 → 成片导出
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path
from typing import Any


class VideoEditError(RuntimeError):
    """真实执行失败（缺依赖 / 输入无效 / ffmpeg 非零退出）。"""


def _require(tool: str) -> str:
    path = shutil.which(tool)
    if not path:
        raise VideoEditError(
            f"未找到 {tool}。请在沙箱内安装 ffmpeg（例如 Alpine: apk add ffmpeg）"
        )
    return path


def _run(args: list[str], timeout: int = 600) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-8:]
        raise VideoEditError(
            f"命令失败（exit {proc.returncode}）：{' '.join(tail) or '无输出'}"
        )
    return proc


def probe(path: str | Path) -> dict[str, Any]:
    """返回真实媒体信息；文件不存在或无法解析时抛错。"""
    src = Path(path)
    if not src.is_file():
        raise VideoEditError(f"文件不存在：{src}")
    ffprobe = _require("ffprobe")
    proc = _run(
        [
            ffprobe,
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            str(src),
        ]
    )
    data = json.loads(proc.stdout or "{}")
    streams = data.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"), {})
    audio = next((s for s in streams if s.get("codec_type") == "audio"), {})
    fmt = data.get("format") or {}
    duration = fmt.get("duration") or video.get("duration") or "0"
    return {
        "path": str(src.resolve()),
        "duration": float(duration or 0),
        "size": int(fmt.get("size") or src.stat().st_size),
        "width": int(video.get("width") or 0),
        "height": int(video.get("height") or 0),
        "video_codec": video.get("codec_name") or "",
        "audio_codec": audio.get("codec_name") or "",
        "has_audio": bool(audio),
    }


def scene_times(path: str | Path, threshold: float = 0.32) -> list[float]:
    """按画面切换检测镜头边界（真实 ffmpeg scene 分数）。"""
    ffmpeg = _require("ffmpeg")
    proc = subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-i",
            str(path),
            "-filter:v",
            f"select='gt(scene,{threshold})',showinfo",
            "-f",
            "null",
            "-",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=600,
        check=False,
    )
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip().splitlines()[-6:]
        raise VideoEditError(f"镜头检测失败：{' '.join(tail) or 'ffmpeg 非零退出'}")
    times: list[float] = []
    for line in (proc.stderr or "").splitlines():
        marker = "pts_time:"
        if marker not in line:
            continue
        try:
            chunk = line.split(marker, 1)[1].split()[0]
            times.append(round(float(chunk), 3))
        except (IndexError, ValueError):
            continue
    return times


def trim(
    src: str | Path,
    dst: str | Path,
    start: float,
    duration: float | None = None,
) -> dict[str, Any]:
    """精确裁剪（重编码 H.264 + AAC），返回真实输出信息。"""
    if start < 0:
        raise VideoEditError("start 不能为负数")
    if duration is not None and duration <= 0:
        raise VideoEditError("duration 必须大于 0")
    ffmpeg = _require("ffmpeg")
    out = Path(dst)
    out.parent.mkdir(parents=True, exist_ok=True)
    args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{start}"]
    args += ["-i", str(src)]
    if duration is not None:
        args += ["-t", f"{duration}"]
    args += [
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "22",
        "-c:a",
        "aac",
        "-b:a",
        "160k",
        "-movflags",
        "+faststart",
        str(out),
    ]
    _run(args)
    return {"ok": True, "output": str(out.resolve()), **probe(out)}


def _video_filter(index: int, width: int, height: int, fps: int) -> str:
    return (
        f"[{index}:v]scale={width}:{height}:force_original_aspect_ratio=decrease,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps={fps}[v{index}]"
    )


def concat(
    clips: list[str | Path],
    dst: str | Path,
    width: int = 1280,
    height: int = 720,
    fps: int = 30,
    keep_audio: bool = False,
) -> dict[str, Any]:
    """统一分辨率/帧率后真实拼接；输出无声（配乐由 add_music 负责）。"""
    if not clips:
        raise VideoEditError("没有可拼接的素材")
    for c in clips:
        if not Path(c).is_file():
            raise VideoEditError(f"素材不存在：{c}")
    ffmpeg = _require("ffmpeg")
    out = Path(dst)
    out.parent.mkdir(parents=True, exist_ok=True)
    args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    for c in clips:
        args += ["-i", str(c)]
    filters: list[str] = []
    for i in range(len(clips)):
        filters.append(_video_filter(i, width, height, fps))
    joined = "".join(f"[v{i}]" for i in range(len(clips)))
    filters.append(f"{joined}concat=n={len(clips)}:v=1:a=0[outv]")
    args += ["-filter_complex", ";".join(filters), "-map", "[outv]"]
    args += ["-an"]
    args += [
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "22",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(out),
    ]
    _run(args)
    return {
        "ok": True,
        "output": str(out.resolve()),
        "clips": len(clips),
        **probe(out),
    }


def burn_subtitles(
    video: str | Path, srt: str | Path, dst: str | Path
) -> dict[str, Any]:
    """把 SRT 真实烧录进画面（需要 ffmpeg 带 libass）。"""
    if not Path(srt).is_file():
        raise VideoEditError(f"字幕文件不存在：{srt}")
    ffmpeg = _require("ffmpeg")
    out = Path(dst)
    out.parent.mkdir(parents=True, exist_ok=True)
    escaped = str(Path(srt).resolve()).replace("\\", "/").replace(":", r"\:")
    _run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video),
            "-vf",
            f"subtitles='{escaped}'",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "22",
            "-c:a",
            "copy",
            "-movflags",
            "+faststart",
            str(out),
        ]
    )
    return {"ok": True, "output": str(out.resolve()), **probe(out)}


def add_music(
    video: str | Path,
    music: str | Path,
    dst: str | Path,
    music_volume: float = 0.25,
) -> dict[str, Any]:
    """叠加背景音乐：视频流复制，音频混合后 AAC 输出。"""
    if not Path(music).is_file():
        raise VideoEditError(f"音乐文件不存在：{music}")
    if not 0 < music_volume <= 4:
        raise VideoEditError("music_volume 需在 (0, 4] 之间")
    ffmpeg = _require("ffmpeg")
    out = Path(dst)
    out.parent.mkdir(parents=True, exist_ok=True)
    _run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video),
            "-stream_loop",
            "-1",
            "-i",
            str(music),
            "-filter_complex",
            f"[1:a]volume={music_volume}[m];[0:a][m]amix=inputs=2:duration=first:"
            f"dropout_transition=2[a]",
            "-map",
            "0:v",
            "-map",
            "[a]",
            "-c:v",
            "copy",
            "-c:a",
            "aac",
            "-b:a",
            "160k",
            "-shortest",
            "-movflags",
            "+faststart",
            str(out),
        ]
    )
    return {"ok": True, "output": str(out.resolve()), **probe(out)}


def auto_edit(
    assets: list[str | Path],
    dst: str | Path,
    *,
    width: int = 1280,
    height: int = 720,
    fps: int = 30,
    subtitles: str | Path | None = None,
    music: str | Path | None = None,
    music_volume: float = 0.25,
) -> dict[str, Any]:
    """自动粗剪：素材归集 → 统一规格 → 拼接 → 字幕 → 配乐 → 成片。"""
    if not assets:
        raise VideoEditError("没有素材，无法成片")
    out = Path(dst)
    steps: list[dict[str, Any]] = []
    merged = out.with_name(f"{out.stem}.merged.mp4")
    steps.append(
        {
            "step": "concat",
            "result": concat(assets, merged, width=width, height=height, fps=fps),
        }
    )
    current = merged
    if subtitles is not None:
        with_subs = out.with_name(f"{out.stem}.subs.mp4")
        steps.append(
            {
                "step": "subtitles",
                "result": burn_subtitles(current, subtitles, with_subs),
            }
        )
        current = with_subs
    if music is not None:
        with_music = out.with_name(f"{out.stem}.music.mp4")
        steps.append(
            {
                "step": "music",
                "result": add_music(current, music, with_music, music_volume),
            }
        )
        current = with_music
    if current != out:
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(current, out)
    return {
        "ok": True,
        "output": str(out.resolve()),
        "steps": steps,
        "info": probe(out),
    }


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="TGA 视频剪辑真实管线")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_probe = sub.add_parser("probe")
    p_probe.add_argument("path")
    p_scene = sub.add_parser("scenes")
    p_scene.add_argument("path")
    p_scene.add_argument("--threshold", type=float, default=0.32)
    p_trim = sub.add_parser("trim")
    p_trim.add_argument("src")
    p_trim.add_argument("dst")
    p_trim.add_argument("--start", type=float, required=True)
    p_trim.add_argument("--duration", type=float)
    p_concat = sub.add_parser("concat")
    p_concat.add_argument("dst")
    p_concat.add_argument("clips", nargs="+")
    p_concat.add_argument("--width", type=int, default=1280)
    p_concat.add_argument("--height", type=int, default=720)
    p_auto = sub.add_parser("auto")
    p_auto.add_argument("dst")
    p_auto.add_argument("clips", nargs="+")
    p_auto.add_argument("--subtitles")
    p_auto.add_argument("--music")
    args = parser.parse_args()
    try:
        if args.cmd == "probe":
            result = probe(args.path)
        elif args.cmd == "scenes":
            result = {"ok": True, "times": scene_times(args.path, args.threshold)}
        elif args.cmd == "trim":
            result = trim(args.src, args.dst, args.start, args.duration)
        elif args.cmd == "concat":
            result = concat(
                args.clips, args.dst, width=args.width, height=args.height
            )
        else:
            result = auto_edit(
                args.clips,
                args.dst,
                subtitles=args.subtitles,
                music=args.music,
            )
    except VideoEditError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
