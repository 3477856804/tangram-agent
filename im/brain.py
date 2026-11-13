"""Tangram 大脑层：确定性能力优先（身份/算术/时间/提醒/天气），其余回落本地 LLM。

设计原则：
- 能算准的绝不猜（算术用 ast 白名单真实计算）；
- 能定时的绝不假（提醒进内存队列，到点经渠道 deliver 回调真实推送）；
- 查得到的绝不编（天气走 Open-Meteo 免费接口，失败如实说明）；
- 兜底交给本地模型（带 Tangram 人设，绝不冒充"七巧板游戏"）。
仅标准库。
"""

from __future__ import annotations

import ast
import operator
import sys
import tempfile
import re
import os
import threading
import time
from pathlib import Path
from typing import Callable, Optional

PERSONA = (
    "你是檀阁瑞木 Tangram——住在用户设备里的个人专属 AI Agent（不是七巧板玩具游戏）。"
    "你运行在用户本地，接入了微信/QQ 等聊天渠道，能记住对话、精确计算、报时、设定时提醒。"
    "回答用简洁白话中文，不编造，不确定就直说。"
)

CAPABILITIES_TEXT = (
    "我是檀阁瑞木 Tangram，你的本地专属 AI Agent。现在就能替你办事：\n"
    "1) 精确计算：直接发算式（支持中文数字与加减乘除）\n"
    "2) 定时提醒：说「三分钟后提醒我喝水」，到点我主动发消息给你\n"
    "3) 时间日期：随时问我现在几点、今天几号\n"
    "4) 天气查询：「北京天气怎么样」（Open-Meteo 实时接口）\n"
    "5) 本地问答：其他问题由我设备里的本地模型直接回答，全程离线不上传\n"
    "6) 记忆：我会记住聊天内容，下次还能问我要"
)

_CN_NUM = {"零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7,
           "八": 8, "九": 9, "十": 10, "两": 2, "半": 0.5}


def _cn_to_num(s: str) -> Optional[float]:
    """一/二/…/十/两/百 组合的中文数字 → 数值（支持 99 内与几百几十）。"""
    if not s:
        return None
    if s in _CN_NUM:
        v = _CN_NUM[s]
        return float(v)
    if s == "百" or s.startswith("百"):
        return None
    total, cur = 0.0, 0.0
    if "百" in s:
        head, s = s.split("百", 1)
        total += (_CN_NUM.get(head, 1) if head else 1) * 100
    if "十" in s:
        head, tail = s.split("十", 1)
        cur += (_CN_NUM.get(head, 1) if head else 1) * 10
        if tail:
            cur += _CN_NUM.get(tail, 0)
        total += cur
    elif s:
        total += _CN_NUM.get(s, 0)
    return total if total > 0 else None


def _normalize_math(text: str) -> str:
    reps = {"除以": "/", "乘以": "*", "加": "+", "减": "-", "乘": "*", "除": "/",
            "乘方": "**", "的平方": "**2", "减号": "-"}
    for k, v in reps.items():
        text = text.replace(k, v)
    # 中文数字 → 阿拉伯数字
    def sub_cn(m):
        val = _cn_to_num(m.group(0))
        return str(int(val)) if val is not None and float(val).is_integer() else (str(val) if val else m.group(0))
    text = re.sub(r"[零一二三四五六七八九十两百]{1,6}", sub_cn, text)
    return text


_ALLOWED_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
                ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv,
                ast.Mod: operator.mod, ast.Pow: operator.pow, ast.USub: operator.neg,
                ast.UAdd: operator.pos}

# 幂运算上限：math_eval 在主进程内同步求值，"2**999999999" 这类输入会
# 触发超大整数分配，直接耗尽 CPU/内存（进程内 DoS）。
_MAX_POW_EXPONENT = 10000
_MAX_POW_BASE = 10 ** 12


def math_eval(expr: str):
    """白名单 AST 求值：仅数字与四则/幂/取模，绝不执行任意代码。"""
    node = ast.parse(expr, mode="eval").body
    def _ev(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)):
            return n.value
        if isinstance(n, ast.BinOp) and type(n.op) in _ALLOWED_OPS:
            left, right = _ev(n.left), _ev(n.right)
            # 先挡住无界幂再做运算，避免超大整数被真正构造出来。
            if isinstance(n.op, ast.Pow):
                if isinstance(right, (int, float)) and abs(right) > _MAX_POW_EXPONENT:
                    raise ValueError("exponent out of safe range")
                if isinstance(left, (int, float)) and abs(left) > _MAX_POW_BASE:
                    raise ValueError("base out of safe range")
            return _ALLOWED_OPS[type(n.op)](left, right)
        if isinstance(n, ast.UnaryOp) and type(n.op) in _ALLOWED_OPS:
            return _ALLOWED_OPS[type(n.op)](_ev(n.operand))
        raise ValueError("forbidden node")
    return _ev(node)


def try_math(text: str) -> Optional[str]:
    m = re.search(r"计算[:：]?\s*(.+)", text)
    expr_src = m.group(1) if m else text
    expr = _normalize_math(expr_src)
    expr = re.sub(r"[^\d+\-*/%.()]+", " ", expr).strip()
    if not expr or not re.search(r"\d\s*[-+*/%].*\d", expr):
        return None
    try:
        val = math_eval(expr)
    except Exception:
        return None
    if isinstance(val, float) and val.is_integer():
        val = int(val)
    shown = _normalize_math(expr_src)
    shown = re.sub(r"\s+", " ", shown)
    return f"算过了：{shown} = {val}（真实计算，不是模型猜的）"


def try_identity(text: str) -> Optional[str]:
    if re.search(r"你是谁|你叫(什么)?|自我介绍|你是什么", text):
        return ("我是檀阁瑞木 Tangram——住在你设备里的个人专属 AI Agent，"
                "本地推理、接入微信/QQ、能记事和设提醒。不是七巧板，是干活的那个。")
    if re.search(r"什么模型|用的啥模型|模型是", text):
        return ("我现在由设备里的本地模型驱动（GGUF 量化权重、离线推理），"
                "具体版本由主人随时可换；我的身份是 Tangram，模型只是我的一部分。")
    if re.search(r"(你|您)(可以|能|会不会|会|能)\s*(干|做|搞|帮忙做)[a-zA-Z吗啥什么]*|有(哪些)?功能|能帮我|你会什么|都能干什么", text) or re.search(r"你可以干什么|你能做什么|你会干什么|你能干啥", text):
        return CAPABILITIES_TEXT
    return None


def try_time(text: str) -> Optional[str]:
    if re.search(r"几点|现在.{0,3}时间|报时", text):
        return "现在是 " + time.strftime("%H:%M:%S") + "（北京时间，设备本地时钟）。"
    if re.search(r"今天几号|今天(是)?(星期|周)几|几月几号|日期", text):
        return "今天是 " + time.strftime("%Y-%m-%d %A") + "（设备本地日历）。"
    return None


_RE_RECUR = re.compile(
    r"每天\s*(?:早上|上午|中午|下午|晚上)?\s*(\d{1,2})\s*(?:点|时)(?:\s*(半|(\d{1,2})\s*分))?\s*"
    r"(?:给我发|给我报|发|播报|提醒我|告诉我|推送|发我)\s*(.+)"
)


def _next_daily_seconds(hour: int, minute: int) -> tuple[float, float]:
    """返回 (距下次到点的秒数, 周期秒=86400)。"""
    now = time.localtime()
    today_target = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, hour, minute, 0, 0, 0, -1))
    due = today_target
    if due <= time.time():
        due += 86400
    return due - time.time(), 86400.0


def parse_recurring(text: str) -> Optional[tuple[float, float, str, str]]:
    """解析「每天早上8点给我发西安天气」→ (首次延迟, 周期, 展示, 任务指令)。"""
    m = _RE_RECUR.search(text or "")
    if not m:
        return None
    hour = int(m.group(1)) % 24
    minute = 30 if m.group(2) else int(m.group(3) or 0)
    task = (m.group(4) or "").strip().rstrip("。！!.")
    if not task:
        return None
    delay, recur = _next_daily_seconds(hour, minute)
    return delay, recur, f"每天 {hour:02d}:{minute:02d}「{task}」", task


_LAST_CODE: dict[str, str] = {}


def remember_code(text: str) -> None:
    """记录最近一次回复/消息里的 python 代码块，供「帮我运行」调用。"""
    import re as _re
    m = list(_re.finditer(r"```(?:python|py)\n(.*?)```", text or "", _re.S))
    if m:
        _LAST_CODE["py"] = m[-1].group(1)


def try_exec(text: str) -> Optional[str]:
    """可选的代码实测能力（默认关闭）。

    安全说明：IM 入站消息来自不可信的聊天用户。早期实现把消息里的 python
    代码块直接喂给 subprocess.run([sys.executable, "-c", code])，等价于对
    任意能发消息的人开放远程代码执行。现改为：
      1) 默认彻底关闭，只有设备所有者显式设置 TANGRAM_ALLOW_CODE_EXEC=1
         才启用；
      2) 启用时也只走 computer_use 的 CodeExecSandbox（独立子进程 + 超时 +
         内存/输出上限 + 模块白名单），不再裸跑解释器；
      3) 沙箱模块不可用即拒绝执行，绝不降级为裸执行（fail-closed）。
    """
    import re as _re

    m = _re.search(r"```(?:python|py)\n(.*?)```", text or "", _re.S)
    code = m.group(1) if m else (_LAST_CODE.get("py") or "")
    trigger = bool(_re.search(r"运行|执行|跑一下|跑起来|实测|试试|帮我跑|做成可运行|验证一下", text or ""))
    if not trigger or not code.strip():
        return None
    if os.environ.get("TANGRAM_ALLOW_CODE_EXEC", "") != "1":
        return ("代码实测能力默认关闭：聊天消息里的代码不可信。"
                "如需启用，请由设备所有者显式设置 TANGRAM_ALLOW_CODE_EXEC=1，"
                "且执行仍受隔离沙箱限制。")
    try:
        # 按文件路径加载，避免 computer_use 包的 __init__ 连带引入其它依赖。
        import importlib.util

        sandbox_path = (Path(__file__).resolve().parent.parent
                        / "computer_use" / "code_exec_sandbox.py")
        spec = importlib.util.spec_from_file_location(
            "tangram_code_exec_sandbox", sandbox_path)
        if spec is None or spec.loader is None:
            raise ImportError("无法加载沙箱模块")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        result = module.CodeExecSandbox(timeout=10).run(code, timeout=10)
    except Exception as exc:
        return f"隔离沙箱不可用或执行异常，已拒绝执行代码：{type(exc).__name__}: {exc}"
    head = "沙箱实测结果（隔离子进程，真实执行）："
    if result.blocked:
        return head + "\n安全门已拦截：" + (result.stderr or result.stdout).strip()[:800]
    if result.timed_out:
        return head + "\n执行超时已强杀（10s）。要我改代码吗？"
    out = (result.stdout or "")[:1500]
    err = (result.stderr or "")[:800]
    if result.returncode == 0:
        return head + f"\n退出码 0\n标准输出：\n{out or '(无输出)'}"
    return head + f"\n退出码 {result.returncode}\nstdout：\n{out}\nstderr：\n{err}"


def try_recurring(text: str, key: str, register: Callable) -> Optional[str]:
    parsed = parse_recurring(text)
    if not parsed:
        return None
    delay, recur, show, task = parsed
    register(delay, show, key, recur, task)
    hh = int(delay // 3600)
    when = time.strftime("%m-%d %H:%M", time.localtime(time.time() + delay))
    return f"周期任务已设好：{show}。首次将在 {when}（{hh} 小时后）执行，之后每天同一时间自动推给你。"


_RE_REMIND = re.compile(
    r"(?:(\d+|半|[零一二三四五六七八九十两]+)\s*(个)?(分钟|小时|秒|天)(?:之?后|以后|后)"
    r"|(\d+)\s*(?:min|分钟))(?:，|,|\s)*(?:提醒我|叫我|提醒|notify me)[:：]?\s*(.+)"
)


def parse_reminder(text: str) -> Optional[tuple[float, str]]:
    """解析「N分钟/小时/秒/天后提醒我做X」→ (delay_seconds, 事项)。"""
    m = _RE_REMIND.search(text)
    if not m:
        return None
    num, ge, unit, alt_min, item = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
    item = (item or "").strip().rstrip("。！!.") or "该做的事"
    if alt_min:
        return int(alt_min) * 60, item
    val = _cn_to_num(num) if num else None
    if val is None:
        return None
    factor = {"秒": 1, "分钟": 60, "小时": 3600, "天": 86400}.get(unit, 60)
    return val * factor, item


def try_remind(text: str, key: str, register: Callable[[float, str, str], None]) -> Optional[str]:
    parsed = parse_reminder(text)
    if not parsed:
        return None
    delay, item = parsed
    register(delay, item, key)
    if delay >= 3600:
        human = f"{int(delay // 3600)} 小时"
    elif delay >= 60:
        human = f"{int(delay // 60)} 分钟"
    else:
        human = f"{int(delay)} 秒"
    when = time.strftime("%H:%M", time.localtime(time.time() + delay))
    return f"好，{human}后（{when}）我会主动发消息提醒你：「{item}」。到时候见。"


def synth_speech(text: str, out_path: str) -> bool:
    """espeak-ng/espeak 合成中文语音到 wav；二进制缺失/失败返回 False（不伪造）。"""
    import shutil
    import subprocess

    binary = shutil.which("espeak-ng") or shutil.which("espeak")
    if not binary:
        return False
    try:
        proc = subprocess.run(
            [binary, "-v", "cmn", "-s", "150", "-w", out_path, text[:300]],
            capture_output=True, timeout=20,
        )
        return proc.returncode == 0 and out_path and Path(out_path).stat().st_size > 44
    except Exception:
        return False


def is_safe_url(url: str) -> bool:
    """校验「由聊天消息带入」的下载 URL，挡住 SSRF 与本地文件读取。

    只允许 http/https；拒绝 file:/ftp: 等协议、字面私网/回环/保留 IP、
    localhost 等内部域名。局限：域名解析到私网（DNS rebinding）与 HTTP 302
    跳转到内网，仍需由出站代理/网络层兜底，此处为最小缓解层。
    """
    import ipaddress
    from urllib.parse import urlsplit

    try:
        parts = urlsplit(str(url or "").strip())
        if parts.scheme not in ("http", "https") or not parts.hostname:
            return False
        host = parts.hostname.strip("[]").lower()
        if host in ("localhost", "localhost.localdomain") or host.endswith(
            (".localhost", ".internal", ".local")
        ) or "%" in host:
            return False
        try:
            addr = ipaddress.ip_address(host)
        except ValueError:
            return True  # 普通域名，交给 DNS / 出站代理
        return not (addr.is_private or addr.is_loopback or addr.is_link_local
                    or addr.is_reserved or addr.is_multicast or addr.is_unspecified)
    except Exception:
        return False


def _default_media_download(url: str, dest: str) -> bool:
    if not is_safe_url(url):
        return False
    try:
        import urllib.request
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310
            Path(dest).write_bytes(r.read())
        return Path(dest).stat().st_size > 100
    except Exception:
        return False


def _default_media_describe(images: list, question: str):
    """子进程调用 scripts/vision_cli.py（Qwen2-VL 真实推理，用完释放内存）。"""
    import subprocess
    args = [sys.executable, str(_ROOT_DIR / "scripts" / "vision_cli.py")]
    for im in images:
        args += ["--image", im]
    args += ["--question", question]
    try:
        proc = subprocess.run(args, capture_output=True, text=True, timeout=300)
        out = (proc.stdout or "").strip()
        if proc.returncode == 0 and out and not out.startswith("ERROR:"):
            return out
        return None
    except Exception:
        return None


_ROOT_DIR = Path(__file__).resolve().parent.parent


def describe_media(items: list, question: str = "请用简体中文描述这张图片的内容与关键信息。",
                   download=None, describe=None, cache_dir: str = "") -> str:
    """媒体条目 [{url|file, kind}] → 下载 → 视觉模型描述。失败诚实说明。"""
    import hashlib

    download = download or _default_media_download
    describe = describe or _default_media_describe
    cache = Path(cache_dir) if cache_dir else Path(
        os.environ.get("TANGRAM_DATA", str(Path.home() / ".tangram"))) / "media"
    cache.mkdir(parents=True, exist_ok=True)
    local: list[str] = []
    for i, it in enumerate(items or []):
        if not isinstance(it, dict):
            continue
        url = str(it.get("url") or it.get("file_url") or it.get("file") or "")
        if not url:
            continue
        if url.startswith("/") and Path(url).is_file():
            local.append(url)
            continue
        ext = ".jpg" if str(it.get("kind", "image")) == "image" else ".mp4"
        dest = str(cache / (hashlib.md5(url.encode()).hexdigest()[:16] + ext))
        if not Path(dest).is_file():
            if not download(url, dest):
                return "你发的这个媒体文件我拿不到（下载失败或需要额外鉴权），这次没法识图——不是我不想看，是真下载不下来。"
        local.append(dest)
    if not local:
        return "没有收到可识别的图片/视频文件。"
    videos = [x for x in local if x.endswith(".mp4") or x.endswith(".mov")]
    frames: list[str] = []
    if videos:
        import subprocess
        with tempfile.TemporaryDirectory() as td:
            r = subprocess.run([sys.executable, str(_ROOT_DIR / "scripts" / "vision_cli.py"),
                                "--video", videos[0], "--question", question, "--frames-only"],
                               capture_output=True, text=True, timeout=120)
            frames = [x for x in (r.stdout or "").splitlines() if x.endswith(".png")]
            if frames:
                desc = _default_media_describe(frames,
                        "这是同一视频按时间顺序抽取的关键帧。" + question)
                return desc or "视频帧拿到了，但视觉模型这次没跑成（内存或依赖），不伪造内容。"
        ans = describe(local, question)
    else:
        ans = describe(local, question)
    if not ans:
        return "视觉模型这次没跑成（可能是内存不足或依赖缺失），不伪造识别结果。"
    return ans


def try_weather(text: str) -> Optional[str]:
    """Open-Meteo 免费实时天气（城市→地理编码→预报）；网络不可达时如实说明。"""
    m = re.search(r"(?:查|看|看看|报告)?\s*([\u4e00-\u9fa5A-Za-z]{1,12}?)(?:市)?的?天气", text)
    if not m or not m.group(1):
        return None
    city = m.group(1)
    city = re.sub(r"^(今天|明天|后天|现在|最近|这|那)+", "", city)
    city = re.sub(r"(今天|明天|后天|现在|最近)+$", "", city)
    city = re.sub(r"(怎么样|如何|多少度|会下雨吗|呢|啊)$", "", city)
    if not city or city in ("天气", "什么"):
        city = os.environ.get("TANGRAM_HOME_CITY", "西安")
    import json as _json
    import urllib.parse
    import urllib.request

    def _get(url, timeout=12):
        with urllib.request.urlopen(url, timeout=timeout) as r:  # noqa: S310
            return _json.loads(r.read().decode())

    try:
        geo = _get(f"https://geocoding-api.open-meteo.com/v1/search?name={urllib.parse.quote(city)}&count=1&language=zh")
        res = geo.get("results") or []
        if not res:
            return f"没找到城市「{city}」，给我个标准城市名试试。"
        lat, lon, name = res[0]["latitude"], res[0]["longitude"], res[0]["name"]
        w = _get(f"https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}"
                 f"&current=temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m&timezone=Asia%2FShanghai")
        cur = w.get("current", {})
        code_map = {0: "晴", 1: "基本晴", 2: "局部多云", 3: "阴", 45: "雾", 48: "雾凇",
                    51: "毛毛雨", 53: "小雨", 55: "大雨", 61: "小雨", 63: "中雨", 65: "大雨",
                    71: "小雪", 73: "中雪", 75: "大雪", 80: "阵雨", 95: "雷雨"}
        desc = code_map.get(int(cur.get("weather_code", -1)), f"天气代码{cur.get('weather_code')}")
        return (f"{name}现在：{desc}，{cur.get('temperature_2m')}℃，"
                f"湿度 {cur.get('relative_humidity_2m')}%，风速 {cur.get('wind_speed_10m')} km/h"
                f"（Open-Meteo 实时，北京时间 {time.strftime('%H:%M')}）。")
    except Exception:
        return f"暂时连不上天气接口（网络受限或超时），{city}的天气这次没查成——不是我不报，是真查不到。"


def _default_fetch(url: str) -> str:
    import urllib.request

    req = urllib.request.Request(url, headers={"User-Agent": (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36")})
    with urllib.request.urlopen(req, timeout=12) as r:  # noqa: S310
        return r.read().decode("utf-8", "replace")


_BING_ALGO = re.compile(
    r'<h2><a[^>]*href="([^"]+)"[^>]*>(.*?)</a></h2>\s*(?:<div[^>]*>)?\s*<p[^>]*>(.*?)</p>',
    re.S)


def search_web(query: str, fetcher: Optional[Callable[[str], str]] = None, topk: int = 3) -> Optional[str]:
    """cn.bing.com HTML 搜索（无 key、国内直连）。失败如实说明，绝不编造结果。"""
    import html as _html
    import urllib.parse

    q = (query or "").strip()
    if not q:
        return None
    fetch = fetcher or _default_fetch
    url = f"https://cn.bing.com/search?q={urllib.parse.quote(q)}&setlang=zh-hans"
    try:
        page = fetch(url)
    except Exception:
        return f"联网搜索暂时连不上（{q} 这次查不到）——可以问我确定性能力：计算/时间/提醒/天气。"
    results = []
    for _m in _BING_ALGO.finditer(page):
        href, title, snippet = _m.groups()
        clean = lambda x: _html.unescape(re.sub(r"<[^>]+>", "", x)).strip()
        t, c = clean(title), clean(snippet)
        href_clean = href.split("url=")[-1] if "url=" in href else href
        if not t or not c or href_clean.startswith("/") or "bing.com" in href_clean:
            continue
        results.append(f"{len(results)+1}. {t}\n   {c[:110]}\n   来源：{href_clean[:90]}")
        if len(results) >= topk:
            break
    if not results:
        return f"搜了但页面结构变了，这次没提出「{q}」的结果——不编造，稍后再试或换个关键词。"
    return "「" + q + "」联网结果（Bing 实时）：\n" + "\n".join(results)


def try_search(text: str) -> Optional[str]:
    m = re.search(r"(?:搜索|搜一下|网上查|联网查|帮我查一下|查一下)[:：]?\s*(.+)", text)
    if not m:
        return None
    q = re.sub(r"(是什么|干嘛的|是谁|的资料|信息)$", "", m.group(1)).strip()
    return search_web(q) if q else None


class Brain:
    def __init__(self, deliver: Optional[Callable[[str, str], None]] = None,
                 llm: Optional[Callable[[str], str]] = None) -> None:
        self.deliver = deliver or (lambda key, text: None)
        self.llm = llm
        # 条目：(触发时刻, 展示事项, 渠道key, 周期秒(0=一次性), 到点执行的任务指令(可选))
        self._reminders: list[list] = []
        self._lock = threading.Lock()
        self._timer: Optional[threading.Thread] = None
        self._stop = threading.Event()

    # ---- 提醒调度 ----
    def _register(self, delay: float, item: str, key: str,
                  recur: float = 0, task: Optional[str] = None) -> None:
        with self._lock:
            self._reminders.append([time.time() + delay, item, key, recur, task])
        self._ensure_timer()

    def _ensure_timer(self) -> None:
        if self._timer is not None and self._timer.is_alive():
            return
        self._timer = threading.Thread(target=self._run_timer, daemon=True, name="tangram-remind")
        self._timer.start()

    def _run_timer(self) -> None:
        while not self._stop.wait(2.0):
            self._fire_due()

    def _fire_due(self, at: Optional[float] = None) -> int:
        """把到期提醒逐条推送；返回触发条数（可注入时间便于测试）。"""
        now = at if at is not None else time.time()
        due = []
        with self._lock:
            keep = []
            for e in self._reminders:
                (due if e[0] <= now else keep).append(e)
            self._reminders = keep
        for when, item, key, recur, task in due:
            try:
                if task:
                    out = self.handle(task, key)  # 到点真实执行任务指令
                    self.deliver(key, f"⏰ 周期任务｜{out or item}")
                else:
                    self.deliver(key, f"⏰ 提醒：{item}")
            except Exception:
                pass
            if recur > 0:  # 周期任务：执行完自动排下一次
                with self._lock:
                    self._reminders.append([time.time() + recur, item, key, recur, task])
                self._ensure_timer()
        return len(due)

    # ---- 主入口 ----
    def handle(self, text: str, key: str = "") -> Optional[str]:
        t = (text or "").strip()
        if not t:
            return None
        out = try_identity(t)
        if out:
            return out
        out = try_time(t)
        if out:
            return out
        out = try_math(t)
        if out:
            return out
        out = try_exec(t)
        if out:
            return out
        out = try_recurring(t, key or "default", self._register)
        if out:
            return out
        out = try_remind(t, key or "default", self._register)
        if out:
            return out
        if "天气" in t:
            out = try_weather(t)
            if out:
                return out
        out = try_search(t)
        if out:
            return out
        if self.llm is not None:
            try:
                return self.llm(t)
            except Exception:
                return "本地模型刚才没答上来（推理异常），换个问法试试。"
        return None

    def shutdown(self) -> None:
        self._stop.set()


# ---- 模块级默认实例（供 serve 注入 LLM/推送回调；测试可直接用 respond）----
_default = Brain()


def set_backend(llm: Optional[Callable[[str], str]] = None,
                deliver: Optional[Callable[[str, str], None]] = None) -> None:
    if llm is not None:
        _default.llm = llm
    if deliver is not None:
        _default.deliver = deliver


def respond(text: str, key: str = "") -> Optional[str]:
    return _default.handle(text, key)


def handle_deterministic(text: str) -> Optional[str]:
    """只走确定性能力、不回落 LLM 的纯函数入口。"""
    no_llm = Brain()
    return no_llm.handle(text)
