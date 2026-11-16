"""量化研究助手测试：指标正确性 / 数据不足如实报错 / 合规免责 / 无违规话术。

所有期望值均可手算或由标准库 statistics 在同一序列上独立算出，
不依赖 mock、硬编码示例结果或任何联网数据。
"""

from __future__ import annotations

import json
import math
import statistics

import pytest

from app.runtime.quant_research import (
    ANALYSIS_MIN_POINTS,
    InsufficientDataError,
    RISK_DISCLAIMER,
    analyze,
    annualized_volatility,
    assert_compliant,
    bollinger_bands,
    ema,
    macd,
    ma,
    max_drawdown,
    rsi,
    sharpe_ratio,
)

# 测试侧独立维护违规话术清单，避免只测实现自己声明的常量。
BANNED = (
    "推荐买入", "推荐卖出", "建议买入", "建议卖出",
    "目标价", "稳赚", "收益保证", "保证收益",
    "必涨", "必赚", "包赚", "无风险",
)

# 合规免责声明必须包含的关键语义词。
REQUIRED_DISCLAIMER_WORDS = (
    "仅供研究学习", "不构成", "投资建议", "不承诺", "收益",
    "不代客交易", "股市有风险", "入市需谨慎",
)


def sample_series(n: int = ANALYSIS_MIN_POINTS + 4) -> list[float]:
    """确定性、非恒定、且足够长的测试价格序列（无随机、无网络）。"""
    return [round(100.0 + 0.5 * i + (i % 3) * 0.3, 4) for i in range(n)]


# ---- 指标计算正确性：用手算简单序列 ----

def test_ma_simple():
    assert ma([1, 2, 3, 4, 5], 2) == pytest.approx([1.5, 2.5, 3.5, 4.5])
    assert ma([1, 2, 3, 4, 5], 3) == pytest.approx([2.0, 3.0, 4.0])


def test_ema_sma_seed():
    # 种子 = SMA([1,2]) = 1.5；k = 2/3；后续 2.5 / 3.5 / 4.5 可手算。
    assert ema([1, 2, 3, 4, 5], 2) == pytest.approx([1.5, 2.5, 3.5, 4.5])


def test_rsi_all_up_all_down():
    assert rsi([1, 2, 3, 4, 5], 3) == pytest.approx([100.0, 100.0])
    assert rsi([5, 4, 3, 2, 1], 3) == pytest.approx([0.0, 0.0])


def test_rsi_flat_is_neutral():
    assert rsi([7, 7, 7, 7], 3) == pytest.approx([50.0])


def test_macd_hand_calculable():
    result = macd([1, 2, 3, 4, 5, 6], fast=2, slow=3, signal=2)
    assert result["macd"] == pytest.approx([0.5, 0.5, 0.5])
    assert result["signal"] == pytest.approx([0.5, 0.5, 0.5])
    assert result["histogram"] == pytest.approx([0.0, 0.0, 0.0])
    assert len(result["macd"]) == len(result["signal"]) == len(result["histogram"])


def test_bollinger_bands_hand_calculable():
    result = bollinger_bands([1, 2, 3, 4], period=2, num_std=1)
    assert result["middle"] == pytest.approx([1.5, 2.5, 3.5])
    assert result["upper"] == pytest.approx([2.0, 3.0, 4.0])
    assert result["lower"] == pytest.approx([1.0, 2.0, 3.0])


def test_annualized_volatility_matches_statistics():
    prices = [10, 11, 10.5, 12, 11.8, 12.4]
    rets = [prices[i] / prices[i - 1] - 1 for i in range(1, len(prices))]
    expected = statistics.stdev(rets) * math.sqrt(252)
    assert annualized_volatility(prices) == pytest.approx(expected)


def test_annualized_volatility_constant_is_zero():
    assert annualized_volatility([10, 10, 10, 10, 10]) == pytest.approx(0.0)


def test_max_drawdown():
    # 峰值 120 -> 谷值 80，跌幅 = 40/120 = 0.3333。
    assert max_drawdown([100, 120, 90, 110, 80]) == pytest.approx(40.0 / 120.0)
    assert max_drawdown([100, 101, 102]) == pytest.approx(0.0)


def test_sharpe_matches_statistics():
    prices = [100, 110, 99, 108.9, 120]
    rets = [prices[i] / prices[i - 1] - 1 for i in range(1, len(prices))]
    expected = statistics.mean(rets) / statistics.stdev(rets) * math.sqrt(252)
    assert sharpe_ratio(prices) == pytest.approx(expected)


# ---- 数据不足 / 非法输入：如实报错，不编造 ----

@pytest.mark.parametrize("fn,args", [
    (ma, ([1, 2], 3)),
    (ema, ([1, 2], 3)),
    (rsi, ([1, 2, 3], 3)),
    (bollinger_bands, ([1, 2, 3], 5)),
    (annualized_volatility, ([10, 10],)),
    (sharpe_ratio, ([10, 10],)),
    (max_drawdown, ([10],)),
])
def test_insufficient_data_raises(fn, args):
    with pytest.raises(InsufficientDataError):
        fn(*args)


def test_macd_insufficient_data_raises():
    with pytest.raises(InsufficientDataError):
        macd([1, 2, 3, 4], 12, 26, 9)


def test_analyze_insufficient_data_raises():
    with pytest.raises(InsufficientDataError):
        analyze([100.0, 101.0, 99.0], "SHORT")


def test_invalid_price_values_raise():
    with pytest.raises(InsufficientDataError):
        ma([1, "not-a-number", 3], 2)
    with pytest.raises(InsufficientDataError):
        ma([1, float("nan"), 3], 2)


# ---- 合规：免责声明常驻 + 无违规话术 ----

def test_analyze_has_risk_disclaimer_with_keywords():
    result = analyze(sample_series(), "TEST")
    assert "risk_disclaimer" in result
    disclaimer = result["risk_disclaimer"]
    assert isinstance(disclaimer, str) and disclaimer
    for word in REQUIRED_DISCLAIMER_WORDS:
        assert word in disclaimer, f"免责声明缺少关键合规词：{word}"


def test_risk_disclaimer_constant_matches_analyze():
    assert analyze(sample_series(), "TEST")["risk_disclaimer"] == RISK_DISCLAIMER


def test_analyze_has_no_banned_phrases():
    result = analyze(sample_series(), "TEST")
    blob = json.dumps(result, ensure_ascii=False)
    for phrase in BANNED:
        assert phrase not in blob, f"输出包含违规话术：{phrase}"


def test_technical_observations_are_neutral():
    result = analyze(sample_series(), "TEST")
    observations = result["technical_observations"]
    assert isinstance(observations, list) and observations
    blob = " ".join(observations)
    for phrase in BANNED:
        assert phrase not in blob
    # signal 类描述只能是中性技术形态词。
    allowed_markers = ("RSI", "MACD", "MA20", "布林带", "历史数据", "不构成投资建议")
    assert any(marker in blob for marker in allowed_markers)


def test_individual_outputs_have_no_banned_phrases():
    series = sample_series()
    outputs = [
        ma(series, 5), ema(series, 12), rsi(series, 14),
        macd(series), bollinger_bands(series),
        annualized_volatility(series), max_drawdown(series), sharpe_ratio(series),
    ]
    for out in outputs:
        assert_compliant(out)
        blob = json.dumps(out, ensure_ascii=False)
        for phrase in BANNED:
            assert phrase not in blob


def test_assert_compliant_catches_banned_phrase():
    with pytest.raises(RuntimeError):
        assert_compliant({"note": "推荐买入这只股票"})


def test_analyze_values_are_real_computed_numbers():
    result = analyze(sample_series(), "TEST")
    ind = result["indicators"]
    assert isinstance(ind["ma"]["ma5"], float)
    assert ind["ema"]["ema12"] != ind["ema"]["ema26"]
    assert 0.0 <= ind["rsi"]["rsi14"] <= 100.0
    assert result["risk_metrics"]["annualized_volatility"] >= 0.0
    assert result["risk_metrics"]["max_drawdown"] >= 0.0
