"""AI 量化研究助手：纯函数式技术指标与风险度量计算。

设计红线（与项目一致）：

* 所有数值都来自真实输入序列的计算，数据不足时如实抛错，绝不编造、填充或硬编码示例值。
* 只做研究/学习用途的分析，不接任何交易/下单 API。
* 输出中绝不出现「推荐买入/卖出」「目标价」「稳赚」「收益保证」等违规话术；
  signal 类字段只能是中性的历史技术形态描述，并强制附带合规免责声明。

本模块不依赖第三方库，仅用标准库，便于在本地后端与测试中直接调用。
"""

from __future__ import annotations

import math
import statistics
from typing import Any, Iterable, Sequence

__all__ = [
    "InsufficientDataError",
    "RISK_DISCLAIMER",
    "ma",
    "ema",
    "rsi",
    "macd",
    "bollinger_bands",
    "annualized_volatility",
    "max_drawdown",
    "sharpe_ratio",
    "analyze",
    "assert_compliant",
]


class InsufficientDataError(ValueError):
    """输入历史数据不足或非法：如实报错，不返回任何编造结果。"""


#: 合规免责声明：analyze 的强制字段，任何输出都必须原样携带。
RISK_DISCLAIMER = (
    "风险提示：本分析仅供研究学习使用，不构成任何投资建议，不承诺任何收益，"
    "不代客交易或代为下单；技术指标基于历史数据计算，不能预测未来走势，"
    "据此操作风险自担。股市有风险，入市需谨慎。"
)

#: 严禁出现在任何输出字段中的违规话术（自校验用）。
_BANNED_PHRASES: tuple[str, ...] = (
    "推荐买入", "推荐卖出", "建议买入", "建议卖出",
    "目标价", "稳赚", "收益保证", "保证收益",
    "必涨", "必赚", "包赚", "无风险",
)

#: analyze 需要的最少历史点数：MACD(12,26,9) 需要 26+9-1=34 个点。
ANALYSIS_MIN_POINTS = 34


def _to_series(prices: Iterable[float]) -> list[float]:
    """把输入规整为 float 序列；空序列/非数值/非有限值一律如实报错。"""
    if isinstance(prices, (str, bytes)):
        raise InsufficientDataError("价格序列必须是数值列表，不能是字符串")
    try:
        items = list(prices)
    except TypeError as exc:
        raise InsufficientDataError(f"价格序列不可迭代：{exc}") from exc
    if not items:
        raise InsufficientDataError("价格序列为空，无法计算任何指标")
    out: list[float] = []
    for i, v in enumerate(items):
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise InsufficientDataError(
                f"第 {i} 个价格不是有限数值：{v!r}"
            )
        f = float(v)
        if not math.isfinite(f):
            raise InsufficientDataError(f"第 {i} 个价格不是有限数值：{v!r}")
        out.append(f)
    return out


def _require(n: int, need: int, name: str) -> None:
    if n < need:
        raise InsufficientDataError(
            f"{name} 需要至少 {need} 个历史价格点，实际只有 {n} 个，拒绝编造结果"
        )


def ma(prices: Iterable[float], period: int) -> list[float]:
    """简单移动平均（SMA）。

    返回长度 ``len(prices) - period + 1`` 的列表，第 i 项为 prices[i:i+period] 的算术均值。
    """
    if isinstance(period, bool) or not isinstance(period, int) or period < 1:
        raise InsufficientDataError(f"period 必须是正整数，实际为 {period!r}")
    s = _to_series(prices)
    _require(len(s), period, f"MA({period})")
    return [sum(s[i:i + period]) / period for i in range(len(s) - period + 1)]


def _ema_full(prices: Sequence[float], period: int) -> list[float | None]:
    """内部用：等长 EMA 序列，前 period-1 项为 None（尚无有效值）。

    以首 period 个价格的 SMA 作为种子，平滑系数 k = 2/(period+1)。
    """
    seed = sum(prices[:period]) / period
    k = 2.0 / (period + 1.0)
    out: list[float | None] = [None] * (period - 1)
    out.append(seed)
    prev = seed
    for i in range(period, len(prices)):
        prev = k * prices[i] + (1.0 - k) * prev
        out.append(prev)
    return out


def ema(prices: Iterable[float], period: int) -> list[float]:
    """指数移动平均（EMA），SMA 种子法。

    返回长度 ``len(prices) - period + 1`` 的有效值列表（前 period-1 个无有效值，不返回）。
    """
    if isinstance(period, bool) or not isinstance(period, int) or period < 1:
        raise InsufficientDataError(f"period 必须是正整数，实际为 {period!r}")
    s = _to_series(prices)
    _require(len(s), period, f"EMA({period})")
    return [v for v in _ema_full(s, period) if v is not None]


def rsi(prices: Iterable[float], period: int = 14) -> list[float]:
    """相对强弱指标（Wilder 平滑）。

    返回长度 ``len(prices) - period`` 的列表，索引 i 对应第 i+period 个价格点。
    全涨返回 100，全跌返回 0，无波动且无涨跌按 50 处理。
    """
    if isinstance(period, bool) or not isinstance(period, int) or period < 1:
        raise InsufficientDataError(f"period 必须是正整数，实际为 {period!r}")
    s = _to_series(prices)
    _require(len(s), period + 1, f"RSI({period})")
    changes = [s[i] - s[i - 1] for i in range(1, len(s))]
    gains = [max(c, 0.0) for c in changes]
    losses = [max(-c, 0.0) for c in changes]
    avg_gain = sum(gains[:period]) / period
    avg_loss = sum(losses[:period]) / period

    def value(g: float, l: float) -> float:
        if l == 0.0 and g == 0.0:
            return 50.0
        if l == 0.0:
            return 100.0
        if g == 0.0:
            return 0.0
        rs = g / l
        return 100.0 - 100.0 / (1.0 + rs)

    out = [value(avg_gain, avg_loss)]
    for i in range(period, len(changes)):
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period
        out.append(value(avg_gain, avg_loss))
    return out


def macd(
    prices: Iterable[float], fast: int = 12, slow: int = 26, signal: int = 9
) -> dict[str, list[float]]:
    """MACD：返回等长的 macd / signal / histogram 三个列表。

    macd = EMA(fast) - EMA(slow)，signal 为 macd 的 EMA(signal)，histogram = macd - signal。
    三者都对齐到 signal 线的有效区间，长度 ``len(prices) - slow - signal + 2``。
    """
    for name, p in (("fast", fast), ("slow", slow), ("signal", signal)):
        if isinstance(p, bool) or not isinstance(p, int) or p < 1:
            raise InsufficientDataError(f"{name} 必须是正整数，实际为 {p!r}")
    if fast >= slow:
        raise InsufficientDataError(f"fast({fast}) 必须小于 slow({slow})")
    s = _to_series(prices)
    _require(len(s), slow + signal - 1, "MACD")
    fast_full = _ema_full(s, fast)
    slow_full = _ema_full(s, slow)
    macd_line = [
        fast_full[i] - slow_full[i]  # type: ignore[operator]
        for i in range(slow - 1, len(s))
    ]
    signal_line = [v for v in _ema_full(macd_line, signal) if v is not None]
    aligned_macd = macd_line[signal - 1:]
    histogram = [m - sg for m, sg in zip(aligned_macd, signal_line)]
    return {
        "macd": aligned_macd,
        "signal": signal_line,
        "histogram": histogram,
    }


def bollinger_bands(
    prices: Iterable[float], period: int = 20, num_std: float = 2.0
) -> dict[str, list[float]]:
    """布林带：返回 upper / middle / lower 三个等长列表。

    middle 为 SMA(period)，标准差用总体标准差（ddof=0），长度为 ``len(prices) - period + 1``。
    """
    if isinstance(period, bool) or not isinstance(period, int) or period < 1:
        raise InsufficientDataError(f"period 必须是正整数，实际为 {period!r}")
    if isinstance(num_std, bool) or not isinstance(num_std, (int, float)) or num_std < 0:
        raise InsufficientDataError(f"num_std 必须是非负数值，实际为 {num_std!r}")
    s = _to_series(prices)
    _require(len(s), period, f"布林带({period})")
    middle = ma(s, period)
    upper: list[float] = []
    lower: list[float] = []
    for i in range(len(middle)):
        window = s[i:i + period]
        sd = statistics.pstdev(window) if period > 1 else 0.0
        upper.append(middle[i] + num_std * sd)
        lower.append(middle[i] - num_std * sd)
    return {"upper": upper, "middle": middle, "lower": lower}


def _simple_returns(s: Sequence[float]) -> list[float]:
    """相邻价格的简单收益率 r_i = s[i]/s[i-1] - 1。"""
    out: list[float] = []
    for i in range(1, len(s)):
        if s[i - 1] == 0.0:
            raise InsufficientDataError("价格序列中出现 0，收益率无定义，拒绝计算")
        out.append(s[i] / s[i - 1] - 1.0)
    return out


def annualized_volatility(
    prices: Iterable[float], periods_per_year: int = 252
) -> float:
    """年化波动率：简单收益率样本标准差 × sqrt(periods_per_year)。"""
    if isinstance(periods_per_year, bool) or not isinstance(periods_per_year, int) or periods_per_year < 1:
        raise InsufficientDataError(f"periods_per_year 必须是正整数，实际为 {periods_per_year!r}")
    s = _to_series(prices)
    _require(len(s), 3, "年化波动率")
    rets = _simple_returns(s)
    return statistics.stdev(rets) * math.sqrt(periods_per_year)


def max_drawdown(prices: Iterable[float]) -> float:
    """最大回撤：从历史峰值到其后谷值的最大跌幅，返回正的小数（0.2 表示 20%）。"""
    s = _to_series(prices)
    _require(len(s), 2, "最大回撤")
    peak = s[0]
    worst = 0.0
    for p in s[1:]:
        if p > peak:
            peak = p
        elif peak > 0.0:
            dd = (peak - p) / peak
            if dd > worst:
                worst = dd
    return worst


def sharpe_ratio(
    prices: Iterable[float], risk_free_rate: float = 0.0, periods_per_year: int = 252
) -> float:
    """年化夏普比率：超额收益均值/样本标准差 × sqrt(periods_per_year)。

    risk_free_rate 为年化无风险利率（如 0.02 表示 2%）。
    收益率标准差为 0 时无定义，如实抛错，绝不返回编造数值。
    """
    if isinstance(periods_per_year, bool) or not isinstance(periods_per_year, int) or periods_per_year < 1:
        raise InsufficientDataError(f"periods_per_year 必须是正整数，实际为 {periods_per_year!r}")
    s = _to_series(prices)
    _require(len(s), 3, "夏普比率")
    rets = _simple_returns(s)
    excess = [r - risk_free_rate / periods_per_year for r in rets]
    sd = statistics.stdev(excess)
    if sd == 0.0:
        raise InsufficientDataError("收益率标准差为 0，夏普比率无定义，拒绝编造结果")
    return statistics.mean(excess) / sd * math.sqrt(periods_per_year)


def _round(x: float) -> float:
    return round(float(x), 6)


def _rsi_zone(v: float) -> str:
    if v > 70.0:
        return "RSI 处于超买区间（>70）"
    if v < 30.0:
        return "RSI 处于超卖区间（<30）"
    return "RSI 处于中性区间（30-70）"


def assert_compliant(result: Any) -> None:
    """递归扫描输出中的所有字符串，发现违规话术立即抛错（研究助手自校验）。"""
    bad: list[str] = []
    if isinstance(result, str):
        for phrase in _BANNED_PHRASES:
            if phrase in result:
                bad.append(phrase)
    elif isinstance(result, dict):
        for value in result.values():
            assert_compliant(value)
    elif isinstance(result, (list, tuple)):
        for value in result:
            assert_compliant(value)
    if bad:
        raise RuntimeError(f"输出包含违规话术，已拦截：{sorted(set(bad))}")


def analyze(prices: Iterable[float], symbol: str = "UNKNOWN") -> dict[str, Any]:
    """汇总技术指标与风险度量，返回结构化 dict。

    数据不足时抛 InsufficientDataError；输出强制包含 ``risk_disclaimer``；
    所有 signal 类字段均为中性历史技术形态描述，不含任何买卖建议。
    """
    s = _to_series(prices)
    _require(len(s), ANALYSIS_MIN_POINTS, "完整量化研究分析")
    sym = str(symbol or "").strip() or "UNKNOWN"
    last = s[-1]

    ma5 = ma(s, 5)[-1]
    ma10 = ma(s, 10)[-1]
    ma20 = ma(s, 20)[-1]
    ema12 = ema(s, 12)[-1]
    ema26 = ema(s, 26)[-1]
    rsi14 = rsi(s, 14)[-1]
    macd_d = macd(s)
    boll = bollinger_bands(s)

    try:
        sharpe: float | None = _round(sharpe_ratio(s))
        sharpe_note = ""
    except InsufficientDataError as exc:
        sharpe = None
        sharpe_note = str(exc)

    rsi_latest = rsi14
    macd_hist_latest = macd_d["histogram"][-1]
    boll_upper = boll["upper"][-1]
    boll_lower = boll["lower"][-1]

    if macd_hist_latest > 0:
        macd_pattern = "MACD 线位于信号线上方"
    elif macd_hist_latest < 0:
        macd_pattern = "MACD 线位于信号线下方"
    else:
        macd_pattern = "MACD 线与信号线重合"

    if last > ma20:
        ma_position = "最新价高于 MA20"
    elif last < ma20:
        ma_position = "最新价低于 MA20"
    else:
        ma_position = "最新价等于 MA20"

    if last > boll_upper:
        boll_position = "最新价高于布林带上轨"
    elif last < boll_lower:
        boll_position = "最新价低于布林带下轨"
    else:
        boll_position = "最新价位于布林带通道内"

    result: dict[str, Any] = {
        "symbol": sym,
        "data_points": len(s),
        "indicators": {
            "ma": {"ma5": _round(ma5), "ma10": _round(ma10), "ma20": _round(ma20)},
            "ema": {"ema12": _round(ema12), "ema26": _round(ema26)},
            "rsi": {"rsi14": _round(rsi_latest), "zone": _rsi_zone(rsi_latest)},
            "macd": {
                "macd": _round(macd_d["macd"][-1]),
                "signal": _round(macd_d["signal"][-1]),
                "histogram": _round(macd_hist_latest),
                "pattern": macd_pattern,
            },
            "bollinger_bands": {
                "upper": _round(boll_upper),
                "middle": _round(boll["middle"][-1]),
                "lower": _round(boll_lower),
            },
        },
        "risk_metrics": {
            "annualized_volatility": _round(annualized_volatility(s)),
            "max_drawdown": _round(max_drawdown(s)),
            "sharpe_ratio": sharpe,
            "sharpe_note": sharpe_note,
        },
        "technical_observations": [
            _rsi_zone(rsi_latest),
            macd_pattern,
            ma_position,
            boll_position,
            "以上均为对历史数据的中性技术形态描述，不构成投资建议，不能预测未来走势。",
        ],
        "risk_disclaimer": RISK_DISCLAIMER,
    }
    assert_compliant(result)
    return result


def backtest(
    candles: Sequence[Any],
    strategy: str | Any = "ma_cross",
    *,
    config: Any = None,
    **strategy_kwargs: Any,
) -> dict[str, Any]:
    """回测薄封装：调用 ``app.runtime.backtest`` 的事件驱动引擎。

    ``strategy`` 可以是内置策略名（``"ma_cross"`` / ``"rsi_reversion"``）或
    一个 ``Strategy`` 实例；``strategy_kwargs`` 透传给内置策略构造函数，
    ``config`` 为 ``BacktestConfig`` 或等价的 dict。数据不足/非法时如实抛错。
    """
    from .backtest import BacktestConfig, Backtester, MaCross, RsiReversion, Strategy

    if isinstance(strategy, Strategy):
        engine_strategy = strategy
    elif isinstance(strategy, str):
        key = strategy.strip().lower().replace("-", "_")
        if key in ("ma_cross", "macross"):
            engine_strategy = MaCross(**strategy_kwargs)
        elif key in ("rsi_reversion", "rsireversion"):
            engine_strategy = RsiReversion(**strategy_kwargs)
        else:
            raise ValueError(
                f"未知策略 {strategy!r}，可选：'ma_cross' / 'rsi_reversion'"
            )
    else:
        raise TypeError("strategy 必须是策略名或 Strategy 实例")

    if config is None:
        engine_config = BacktestConfig()
    elif isinstance(config, BacktestConfig):
        engine_config = config
    elif isinstance(config, dict):
        engine_config = BacktestConfig(**config)
    else:
        raise TypeError("config 必须是 BacktestConfig、dict 或 None")

    return Backtester(engine_config).run(candles, engine_strategy)
