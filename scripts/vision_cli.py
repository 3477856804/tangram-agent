"""Tangram 视觉子进程：Qwen2-VL-2B-Instruct（本地 4.2GB 权重）真实识图/视频帧理解。

独立进程设计：serve 网关不常驻加载大模型（8G 内存下用完即释放）。
用法：
    python3 scripts/vision_cli.py --image a.jpg [--image b.jpg] --question "..."
    python3 scripts/vision_cli.py --video v.mp4 --question "视频里发生了什么"
模型路径：env TANGRAM_VL_MODEL，默认 workspace/tangram-models/Qwen2-VL-2B-Instruct。
失败（缺依赖/缺权重/OOM/超时）输出以 ERROR: 开头的可读信息并退出码非 0，绝不伪造描述。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_MODEL = os.environ.get(
    "TANGRAM_VL_MODEL",
    "/root/userdata/workspace/tangram-models/Qwen2-VL-2B-Instruct")

_LOAD = None  # (processor, model) 进程内缓存


def _load():
    global _LOAD
    if _LOAD is None:
        import torch
        from transformers import Qwen2VLForConditionalGeneration, AutoProcessor

        if not Path(DEFAULT_MODEL, "config.json").is_file():
            raise FileNotFoundError(f"未找到 VL 权重目录 {DEFAULT_MODEL}")
        processor = AutoProcessor.from_pretrained(DEFAULT_MODEL)
        model = Qwen2VLForConditionalGeneration.from_pretrained(
            DEFAULT_MODEL, torch_dtype=torch.bfloat16, device_map="cpu",
            low_cpu_mem_usage=True)
        model.eval()
        _LOAD = (processor, model)
    return _LOAD


def describe_images_api(images: list[str], question: str) -> "str | None":
    """魔搭 ModelScope API-Inference（Qwen2.5-VL-72B，每日 2000 次免费）。
    需要 MODELSCOPE_API_TOKEN；未配置/网络失败返回 None（由调用方回落本地）。"""
    import base64
    import json as _json
    import urllib.request

    token = os.environ.get("MODELSCOPE_API_TOKEN", "").strip()
    if not token:
        return None
    content = [{"type": "text", "text": question}]
    for p in images:
        try:
            raw = Path(p).read_bytes()
        except OSError:
            continue
        mime = "image/jpeg" if p.lower().endswith((".jpg", ".jpeg")) else "image/png"
        content.append({"type": "image_url",
                        "image_url": {"url": f"data:{mime};base64,{base64.b64encode(raw).decode()}"}})
    body = _json.dumps({
        "model": os.environ.get("TANGRAM_VL_API_MODEL", "Qwen/Qwen2.5-VL-72B-Instruct"),
        "messages": [{"role": "user", "content": content}],
        "max_tokens": 400,
    }).encode()
    try:
        req = urllib.request.Request("https://api-inference.modelscope.cn/v1/chat/completions",
                                     data=body, headers={
                                         "Authorization": f"Bearer {token}",
                                         "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=90) as r:  # noqa: S310
            d = _json.loads(r.read().decode())
        return d["choices"][0]["message"]["content"].strip() or None
    except Exception:
        return None


_LLAMA_VL = None


def _load_llama_vl():
    """llama.cpp Llava 封装：Q4_K_M 主模型 + vision-encoder，~4G 峰值内存。"""
    global _LLAMA_VL
    if _LLAMA_VL is None:
        from llama_cpp import Llama, Llava  # type: ignore

        model = Llama(model_path="/root/vl-gguf/q4km.gguf", n_ctx=4096, n_threads=4, verbose=False)
        clip = Llama(model_path="/root/vl-gguf/vision.gguf", clip_model_path="/root/vl-gguf/vision.gguf",
                     verbose=False)
        _LLAMA_VL = Llava(llm=model, clip=clip)
    return _LLAMA_VL


def describe_images_gguf(images: list[str], question: str, max_new_tokens: int = 160):
    try:
        vl = _load_llama_vl()
        img = images[0]
        prompt = (f"<cfg>{'system:You describe images in Simplified Chinese.'}</cfg>\n"
                  f"USER: <img>{img}</img>\n{question}\nASSISTANT:")
        out = vl(prompt, max_tokens=max_new_tokens, temperature=0.0, stop=["</s>", "USER:"])
        return (out.get("choices", [{}])[0].get("text", "") or "").strip() or None
    except Exception as exc:
        print(f"GGUF 视觉路径失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        return None


def describe_images(images: list[str], question: str = "请用简体中文详细描述这张图片的内容。",
                    max_new_tokens: int = 160) -> str:
    api = describe_images_api(images, question)
    if api:
        return api
    gg = describe_images_gguf(images, question, max_new_tokens)
    if gg:
        return gg
    processor, model = _load()
    from PIL import Image

    pil_images = [Image.open(p).convert("RGB") for p in images]
    content = [{"type": "image", "image": f"file://{p}"} for p in images]
    content.append({"type": "text", "text": question})
    messages = [{"role": "user", "content": content}]
    text = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = processor(
        text=[text], images=pil_images, videos=None,
        padding=True, return_tensors="pt")
    import torch
    with torch.inference_mode():
        out = model.generate(**inputs, max_new_tokens=max_new_tokens, do_sample=False)
    gen = out[:, inputs.input_ids.shape[1]:]
    return processor.batch_decode(gen, skip_special_tokens=True)[0].strip()


def extract_video_frames(video: str, out_dir: str, max_frames: int = 3) -> list[str]:
    """ffmpeg 真实抽帧（均匀取样），返回 png 路径列表。"""
    out_dir_p = Path(out_dir)
    out_dir_p.mkdir(parents=True, exist_ok=True)
    # 时长探测
    dur = ""
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", video],
            capture_output=True, text=True, timeout=30)
        dur = r.stdout.strip()
    except Exception:
        pass
    try:
        seconds = float(dur) if dur else 0.0
    except ValueError:
        seconds = 0.0
    n = max_frames if max_frames > 0 else 3
    fps = f"{max(0.05, n / max(seconds, 0.5)):.4f}"
    pat = str(out_dir_p / "f%03d.png")
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", video,
         "-vf", f"fps={fps},scale=640:-2", "-frames:v", str(n), pat],
        check=True, timeout=120)
    frames = sorted(str(p) for p in out_dir_p.glob("f*.png"))
    return frames[:n]


def main() -> int:
    ap = argparse.ArgumentParser(description="Tangram 视觉识别子进程")
    ap.add_argument("--image", action="append", default=[])
    ap.add_argument("--video", default="")
    ap.add_argument("--question", default="请用简体中文详细描述这张图片的内容。")
    ap.add_argument("--frames-only", action="store_true", help="仅抽帧输出路径（视频）")
    args = ap.parse_args()
    images = list(args.image)
    if args.video and args.frames_only:
        print("\n".join(extract_video_frames(args.video, tempfile.mkdtemp(), 3)))
        return 0
    if args.video:
        with tempfile.TemporaryDirectory() as td:
            frames = extract_video_frames(args.video, td)
            if not frames:
                print("ERROR: 视频抽帧失败（文件损坏或 ffmpeg 不支持该编码）")
                return 2
            images = frames
            if not images:
                print("ERROR: 没有可用图片输入")
                return 2
    if not images:
        print("ERROR: 没有可用图片输入")
        return 2
    try:
        if args.video:
            q = "这是同一视频里按时间顺序抽取的关键帧。" + args.question
        else:
            q = args.question
        print(describe_images(images, q))
        return 0
    except ImportError as exc:
        print(f"ERROR: 缺少依赖 {exc}（pip install transformers qwen-vl-utils）")
        return 3
    except Exception as exc:
        print(f"ERROR: 视觉推理失败 {type(exc).__name__}: {exc}")
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
