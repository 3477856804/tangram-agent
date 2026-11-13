"""tangram-agent CLI：在这里训练出你自己的模型。

用法（均走真实 I/O / 真实训练）：
  python -m harness version
  python -m harness catalog                          # 可下载的基底模型清单
  python -m harness download qwen2.5-0.5b --mirror   # 真实下载基底模型
  python -m harness models                           # 已登记基座 / 已产出私人模型
  python -m harness work "帮我写一个快排" --source api     # 干一件真实工作并采集轨迹
  python -m harness distill --source api --epochs 8 # 工作蒸馏 → 产出自己的模型
  python -m harness distill --source local --base qwen2.5-0.5b
  python -m harness describe                         # agent = model + harness 自述
  python -m harness demo                             # 离线端到端自测（注入教师）

API 凭据：TANGRAM_API_BASE / TANGRAM_API_KEY / TANGRAM_API_MODEL（或 CLI 参数）。
本地路径：先 download，再 --source local --base <id>。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from .agent import TangramAgent  # noqa: E402
from .base_model import BaseModelManager  # noqa: E402
from .distiller import DistillConfig  # noqa: E402
from .teachers import CallableTeacher  # noqa: E402
from .version import PRODUCT_NAME, PRODUCT_VERSION, assert_version_frozen  # noqa: E402
from .work_trace import WorkLog  # noqa: E402


def _models_root(args) -> str:
    return args.models_root


def _config(args) -> DistillConfig:
    return DistillConfig(
        epochs=args.epochs,
        lr=args.lr,
        model_name=args.name,
        min_samples=args.min_samples,
    )


def _teacher(args):
    from .teachers import teacher_from_source

    if args.source == "local":
        return teacher_from_source(
            "local", base_model=args.base, models_root=_models_root(args)
        )
    return teacher_from_source(
        "api",
        api_base=args.api_base,
        api_key=args.api_key,
        api_model=args.api_model,
    )


def _agent(args) -> TangramAgent:
    from .distiller import WorkDistiller

    return TangramAgent(
        WorkDistiller(_teacher(args), models_root=_models_root(args), config=_config(args)),
        models_root=_models_root(args),
    )


def cmd_version(args) -> int:
    assert_version_frozen()
    print(f"{PRODUCT_NAME} {PRODUCT_VERSION}  (agent = model + harness)")
    print("产品版本定版前恒为 0.0.1；唯一真源：仓库根 VERSION")
    return 0


def cmd_catalog(args) -> int:
    assert_version_frozen()
    for row in BaseModelManager(_models_root(args)).catalog():
        print(f"  {row['id']:<18} {row['name']:<40} {row['params']:<6} {row['fmt']}")
        print(f"      {row['url_cn'] or row['url']}")
    return 0


def cmd_download(args) -> int:
    def progress(n, total):
        if total:
            sys.stderr.write(f"\r  下载 {n/1048576:.1f}/{total/1048576:.1f} MB")
        else:
            sys.stderr.write(f"\r  下载 {n/1048576:.1f} MB")
        sys.stderr.flush()

    try:
        rec = BaseModelManager(_models_root(args)).download(
            args.model,
            use_cn_mirror=args.mirror,
            expected_sha256=args.sha256,
            force=args.force,
            on_progress=progress,
        )
    except Exception as exc:
        print(f"下载失败：{exc}", file=sys.stderr)
        return 1
    sys.stderr.write("\n")
    print(json.dumps({
        "id": rec.id, "path": rec.path, "size": rec.size,
        "sha256": rec.sha256, "fmt": rec.fmt,
    }, ensure_ascii=False, indent=2))
    return 0


def cmd_models(args) -> int:
    root = Path(_models_root(args))
    print("== 本地基底模型 ==")
    for r in BaseModelManager(root).list_local():
        print(f"  {r['id']:<18} {r['size']/1048576:.1f} MB  {r['path']}")
    print("== 已产出的私人模型（模型卡）==")
    cards = sorted((root / "cards").glob("*.model_card.json"))
    if not cards:
        print("  （暂无，先 work 采集工作轨迹再 distill）")
    for c in cards:
        try:
            d = json.loads(c.read_text(encoding="utf-8"))
            print(f"  {d.get('name')}  samples={d.get('samples')}  "
                  f"teacher={d.get('teacher', {}).get('kind')}  {c.name}")
        except (json.JSONDecodeError, OSError):
            continue
    return 0


def cmd_work(args) -> int:
    try:
        agent = _agent(args)
        trace = agent.work(args.task, accept=not args.no_accept, corrected=args.corrected)
    except Exception as exc:
        print(f"工作失败：{exc}", file=sys.stderr)
        return 1
    print(trace.target)
    print(f"[轨迹] accepted={trace.accepted} source={trace.source} "
          f"teacher={trace.meta.get('teacher')}", file=sys.stderr)
    return 0


def cmd_distill(args) -> int:
    try:
        agent = _agent(args)
        result = agent.train()
    except Exception as exc:
        print(f"蒸馏失败：{exc}", file=sys.stderr)
        return 1
    print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))
    return 0 if result.ok else 1


def cmd_describe(args) -> int:
    # describe 不强制教师可用（可能只是查看已产出的模型卡）
    from .distiller import WorkDistiller
    try:
        teacher = _teacher(args)
    except Exception:
        teacher = CallableTeacher(lambda p, s: "(未配置教师)", label="unconfigured")
    agent = TangramAgent(
        WorkDistiller(teacher, models_root=_models_root(args), config=_config(args)),
        models_root=_models_root(args),
    )
    print(json.dumps(agent.describe(), ensure_ascii=False, indent=2))
    return 0


def cmd_demo(args) -> int:
    """离线端到端自测：注入教师 → 真实工作轨迹 → 真实 torch 训练 → 产出模型。

    明确标注：注入教师不是真实权重，仅用于在没有外网/API 凭据时验证
    「采集→蒸馏→训练→合并→晋升→模型卡」整条链路真的在跑、真的落盘。
    """
    assert_version_frozen()
    root = Path(args.models_root)

    def reference(prompt: str, system: str) -> str:
        return f"[work-output] 已按任务执行：{prompt.strip()[:60]}"

    agent = TangramAgent.for_teacher(
        CallableTeacher(reference, label="offline-selftest"),
        models_root=root,
        config=DistillConfig(epochs=6, model_name="demo-agent", min_samples=3),
    )
    tasks = [
        "帮我写一个 Python 快排函数",
        "把这段话总结成一句话",
        "列出今天要做的三件事",
        "解释一下什么是知识图谱",
    ]
    for t in tasks:
        agent.work(t)
    print(f"[demo] 采集工作轨迹 {agent.work_log.count()} 条", file=sys.stderr)
    result = agent.train()
    print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))
    print("\n[demo] agent = model + harness 自述：", file=sys.stderr)
    print(json.dumps(agent.describe(), ensure_ascii=False, indent=2), file=sys.stderr)
    return 0 if result.ok else 1


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="tangram-agent",
        description="agent = model + harness：在本地训练出你自己的私人模型",
    )
    p.add_argument("--models-root", default="models", help="模型池根目录（默认 ./models）")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("version", help="打印产品版本与冻结状态")
    sub.add_parser("catalog", help="列出可下载的基底模型")
    sub.add_parser("models", help="列出本地基座与已产出私人模型")
    sub.add_parser("describe", help="打印 agent = model + harness 自述")

    dl = sub.add_parser("download", help="真实下载基底模型")
    dl.add_argument("model", help="BASE_CATALOG 的 id 或 http(s) 直链")
    dl.add_argument("--mirror", action="store_true", help="使用国内 hf-mirror 直链")
    dl.add_argument("--sha256", default="", help="期望的 SHA-256")
    dl.add_argument("--force", action="store_true", help="强制重新下载")

    def add_common(sp):
        sp.add_argument("--source", choices=["local", "api"], default="api")
        sp.add_argument("--base", default="", help="source=local 时的基底模型 id/路径")
        sp.add_argument("--api-base", default=os.environ.get("TANGRAM_API_BASE", ""))
        sp.add_argument("--api-key", default=os.environ.get("TANGRAM_API_KEY", ""))
        sp.add_argument("--api-model", default=os.environ.get("TANGRAM_API_MODEL", ""))
        sp.add_argument("--epochs", type=int, default=8)
        sp.add_argument("--lr", type=float, default=2e-4)
        sp.add_argument("--name", default="my-agent")
        sp.add_argument("--min-samples", type=int, default=1)

    wk = sub.add_parser("work", help="干一件真实工作并采集轨迹")
    wk.add_argument("task")
    wk.add_argument("--no-accept", action="store_true", help="不采纳（不进训练集）")
    wk.add_argument("--corrected", default="", help="用户修正版")
    add_common(wk)

    ds = sub.add_parser("distill", help="工作蒸馏 → 产出自己的模型")
    add_common(ds)

    sub.add_parser("demo", help="离线端到端自测（注入教师）")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    handlers = {
        "version": cmd_version,
        "catalog": cmd_catalog,
        "download": cmd_download,
        "models": cmd_models,
        "work": cmd_work,
        "distill": cmd_distill,
        "describe": cmd_describe,
        "demo": cmd_demo,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
