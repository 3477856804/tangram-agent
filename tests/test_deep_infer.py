"""DeepInfer 推理规划的真实行为测试。

覆盖：token 估算、分块预填充、稳定前缀拼接、上下文预算、起草长度、
统计记账。全部确定性，不需要 llama_cpp 或模型权重。
"""

from __future__ import annotations

from app.runtime.deep_infer import (
    DeepInferPlanner,
    estimate_tokens,
    prefill_chunks,
    stable_prompt,
)


def test_stable_prompt_is_deterministic():
    a = stable_prompt("系统提示", "用户问题")
    b = stable_prompt("系统提示  ", "  用户问题")
    assert a == b == "系统提示\n\n用户问题"
    assert stable_prompt("", "只有用户") == "只有用户"
    assert stable_prompt("只有系统", "") == "只有系统"


def test_estimate_tokens_counts_cjk_and_words():
    assert estimate_tokens("") == 0
    assert estimate_tokens("你好世界") == 4
    assert estimate_tokens("hello world") >= 2
    assert estimate_tokens("中文 and English!") > 6


def test_prefill_chunks_grow_and_cover_prompt():
    assert prefill_chunks(0) == []
    assert prefill_chunks(100) == [100]
    assert prefill_chunks(128 + 256 + 512) == [128, 256, 512]
    big = prefill_chunks(3000)
    assert big[0] == 128
    assert sum(big) == 3000
    assert all(c <= 1024 for c in big)


def test_plan_clamps_generation_to_context_budget():
    p = DeepInferPlanner(context_size=256, threads=2)
    plan = p.plan("你是助手", "写一段话", max_tokens=512)
    assert plan.max_tokens <= 256 - plan.prompt_tokens - 64
    assert plan.max_tokens >= 1
    assert plan.threads == 2


def test_plan_detects_stable_prefix():
    p = DeepInferPlanner(threads=2)
    a = p.plan("固定人设", "第一问", 64)
    b = p.plan("固定人设", "第二问", 64)
    c = p.plan("换了人设", "第三问", 64)
    assert a.prefix_reused is False
    assert b.prefix_reused is True
    assert c.prefix_reused is False
    stats = p.metrics()["prefix"]
    assert stats["hits"] == 1
    assert stats["misses"] == 2


def test_draft_length_adapts_to_acceptance():
    p = DeepInferPlanner(threads=2)
    assert p.draft_length() == 2  # 无数据时保守起草

    p.record(
        prompt_tokens=10, completion_tokens=5, latency_ms=100, drafted=6, accepted=6
    )
    p.record(
        prompt_tokens=10, completion_tokens=5, latency_ms=100, drafted=6, accepted=5
    )
    assert p.draft_length() == 6

    q = DeepInferPlanner(threads=2)
    q.record(
        prompt_tokens=10, completion_tokens=5, latency_ms=100, drafted=6, accepted=0
    )
    q.record(
        prompt_tokens=10, completion_tokens=5, latency_ms=100, drafted=6, accepted=1
    )
    assert q.draft_length() == 0


def test_metrics_accumulate_only_real_records():
    p = DeepInferPlanner(threads=2)
    p.record(prompt_tokens=100, completion_tokens=50, latency_ms=500)
    p.record(
        prompt_tokens=200, completion_tokens=150, latency_ms=1000, drafted=4, accepted=3
    )
    m = p.metrics()
    assert m["generations"] == 2
    assert m["prompt_tokens"] == 300
    assert m["completion_tokens"] == 200
    assert m["avg_latency_ms"] == 750.0
    assert m["tokens_per_second"] == 133.33
    assert m["speculation"]["rounds"] == 1
    assert m["speculation"]["accepted"] == 3


def test_threads_stay_in_sane_range():
    p = DeepInferPlanner()
    assert 2 <= p.threads <= 6
    small = DeepInferPlanner(context_size=1024)
    assert 2 <= small.threads <= p.threads
