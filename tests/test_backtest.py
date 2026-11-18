"""回测引擎测试：无未来函数 / 成本真实扣减 / 策略开平仓 / 回撤与拒绝非法输入。

所有 K 线均由确定性合成序列构造，期望值可在测试内独立手算，
不使用随机数、mock、联网数据或硬编码的收益结果。
"""

from __future__ import annotations

import pytest

from app.runtime.backtest import (
    MIN_BARS,
    BacktestConfig,
    Backtester,
    Candle,
    MaCross,
    RsiReversion,
    Strategy,
)
from app.runtime.quant_research import InsufficientDataError, backtest

ZERO_COST = BacktestConfig(fee_bps=0.0, slippage_bps=0.0)


def make_candles(closes, *, start_ts=0, spread=0.5, gap=0.0):
    """确定性 K 线：open 默认取上一根收盘价，gap 可制造确定性的跳空。"""
    candles = []
    for i, close in enumerate(closes):
        open_ = closes[i - 1] * (1.0 + gap) if i > 0 else close
        candles.append(
            Candle(
                ts=start_ts + i,
                open=open_,
                high=max(open_, close) + spread,
                low=min(open_, close) - spread,
                close=close,
                volume=1000.0,
            )
        )
    return candles


def sma(values, idx, period):
    window = values[idx - period + 1: idx + 1]
    return sum(window) / period


def detect_crosses(closes, fast, slow):
    """独立于实现检测均线交叉，返回 [(方向, 交叉所在 bar 下标)]。"""
    events = []
    for i in range(slow, len(closes)):
        f_now, s_now = sma(closes, i, fast), sma(closes, i, slow)
        f_prev, s_prev = sma(closes, i - 1, fast), sma(closes, i - 1, slow)
        if f_prev <= s_prev and f_now > s_now:
            events.append(("up", i))
        elif f_prev >= s_prev and f_now < s_now:
            events.append(("down", i))
    return events


def trend_closes():
    """跌 → 涨 → 跌 的确定性序列，确保 MA 先金叉后死叉。"""
    down = [120.0 - 1.0 * i for i in range(30)]          # 120 → 91
    up = [91.0 + 2.0 * i for i in range(1, 31)]          # 93 → 151
    down2 = [151.0 - 2.5 * i for i in range(1, 27)]      # 148.5 → 86
    return down + up + down2


class BuyAndHold(Strategy):
    """测试用：首根 bar 发出买入信号，之后一直持有。"""

    def on_bar(self, ctx):
        if ctx.index == 0:
            ctx.buy("test_entry")


class Spy(Strategy):
    """测试用：记录策略在每根 bar 能看到的上下文。"""

    def __init__(self):
        self.lengths = []
        self.seen_closes = []
        self.candle_closes = []

    def on_bar(self, ctx):
        self.lengths.append(len(ctx.closes))
        self.seen_closes.append(ctx.closes)
        self.candle_closes.append(ctx.candle.close)
        if ctx.index == 0:
            ctx.buy("spy")


# ---- MA 金叉/死叉：产生交易，且严格下一 bar 开盘成交（无未来函数）----

def test_ma_cross_trades_execute_at_next_bar_open():
    closes = trend_closes()
    candles = make_candles(closes, gap=0.001)  # 开盘价与上一收盘价不同，可区分成交价来源
    fast, slow = 5, 20
    events = detect_crosses(closes, fast, slow)
    assert [e[0] for e in events] == ["up", "down"], "合成数据应恰好先金叉后死叉"

    up_idx = events[0][1]
    down_idx = events[1][1]
    result = Backtester(ZERO_COST).run(candles, MaCross(fast=fast, slow=slow))

    assert result["trade_count"] == 1
    trade = result["trades"][0]
    # 信号在交叉 bar 收盘后产生，只能在下一 bar 开盘成交。
    assert trade["entry_ts"] == candles[up_idx + 1].ts
    assert trade["exit_ts"] == candles[down_idx + 1].ts
    assert trade["entry_price"] == pytest.approx(candles[up_idx + 1].open, rel=1e-9)
    assert trade["entry_price"] != pytest.approx(candles[up_idx].close, rel=1e-9)
    assert trade["entry_reason"] == "ma_golden_cross"
    assert trade["reason"] == "ma_death_cross"

    # 用截断到入场 bar 的数据重跑，入场必须完全一致：说明入场未使用任何未来数据。
    prefix = Backtester(ZERO_COST).run(candles[: up_idx + 2], MaCross(fast=fast, slow=slow))
    assert prefix["trades"][0]["entry_ts"] == trade["entry_ts"]
    assert prefix["trades"][0]["entry_price"] == pytest.approx(trade["entry_price"])


def test_strategy_sees_only_history_up_to_current_bar():
    closes = [100.0, 101.0, 102.0, 103.0, 104.0, 105.0]
    candles = make_candles(closes)
    spy = Spy()
    Backtester(ZERO_COST).run(candles, spy)

    assert spy.lengths == list(range(1, len(candles) + 1))
    for i, seen in enumerate(spy.seen_closes):
        assert seen == tuple(closes[: i + 1])
    assert spy.candle_closes == closes


# ---- 手续费与滑点必须真实降低收益 ----

def test_fees_and_slippage_reduce_returns():
    closes = trend_closes()
    candles = make_candles(closes)
    strategy = MaCross(fast=5, slow=20)

    free = Backtester(ZERO_COST).run(candles, strategy)
    paid = Backtester(BacktestConfig(fee_bps=5.0, slippage_bps=2.0)).run(candles, strategy)

    assert free["trade_count"] == paid["trade_count"] == 1
    assert paid["final_equity"] < free["final_equity"]
    assert paid["total_return_pct"] < free["total_return_pct"]

    # 成交价必须含滑点：买入价 = 下一 bar 开盘价 × (1 + 2bps)。
    events = detect_crosses(closes, 5, 20)
    per_bar = Backtester(BacktestConfig(fee_bps=5.0, slippage_bps=2.0))
    paid = per_bar.run(candles, strategy)
    trade = paid["trades"][0]
    entry_bar = candles[events[0][1] + 1]
    assert trade["entry_price"] == pytest.approx(entry_bar.open * (1.0 + 0.0002), rel=1e-6)
    assert trade["exit_price"] < candles[events[1][1] + 1].open

    # pnl 必须等于「价差 × 数量 − 双边手续费」，手续费率为 5bps。
    qty = trade["qty"]
    expected_fee = qty * (trade["entry_price"] + trade["exit_price"]) * 0.0005
    expected_pnl = qty * (trade["exit_price"] - trade["entry_price"]) - expected_fee
    assert trade["pnl"] == pytest.approx(expected_pnl, abs=1e-4)


# ---- RSI 策略能开平仓 ----

def test_rsi_reversion_opens_and_closes_position():
    closes = [100.0 - 2.0 * i for i in range(10)] + [82.0 + 3.0 * i for i in range(1, 13)]
    candles = make_candles(closes)
    result = Backtester(ZERO_COST).run(candles, RsiReversion(period=2, buy=30, sell=70))

    assert result["trade_count"] >= 1
    trade = result["trades"][0]
    assert trade["entry_reason"] == "rsi_oversold"
    assert trade["reason"] == "rsi_overbought"
    assert trade["exit_ts"] > trade["entry_ts"]
    assert trade["entry_price"] > 0.0 and trade["exit_price"] > 0.0
    assert result["win_rate_pct"] in (0.0, 100.0)


# ---- 最大回撤 / 亏损如实返回 ----

def test_max_drawdown_and_total_return_are_exact():
    closes = [100.0, 100.0, 120.0, 90.0, 60.0]
    result = Backtester(ZERO_COST).run(make_candles(closes), BuyAndHold())

    equities = [point["equity"] for point in result["equity_curve"]]
    assert equities == [10000.0, 10000.0, 12000.0, 9000.0, 6000.0]
    # 峰值 12000 → 谷值 6000：回撤 50%。
    assert result["max_drawdown_pct"] == pytest.approx(50.0)
    assert result["final_equity"] == pytest.approx(6000.0)
    assert result["total_return_pct"] == pytest.approx(-40.0)
    assert result["trade_count"] == 1
    assert result["trades"][0]["pnl"] == pytest.approx(-4000.0)
    assert result["trades"][0]["reason"] == "end_of_data"
    assert result["win_rate_pct"] == 0.0


# ---- 非法 K 线拒绝 ----

@pytest.mark.parametrize("kwargs", [
    dict(open=100.0, high=99.0, low=101.0, close=100.0),   # high < low
    dict(open=0.0, high=101.0, low=99.0, close=100.0),      # open <= 0
    dict(open=100.0, high=101.0, low=99.0, close=-1.0),     # close <= 0
    dict(open=100.0, high=float("nan"), low=99.0, close=100.0),
    dict(open=100.0, high=101.0, low=99.0, close=100.0, volume=-5.0),
])
def test_invalid_candle_rejected(kwargs):
    with pytest.raises(ValueError):
        Candle(ts=0, **kwargs)


def test_non_candle_input_rejected():
    with pytest.raises(TypeError):
        Backtester().run([{"ts": 0}], MaCross())


# ---- 数据不足必须拒绝 ----

def test_insufficient_data_rejected():
    with pytest.raises(InsufficientDataError):
        Backtester().run([], MaCross())
    with pytest.raises(InsufficientDataError):
        Backtester().run(make_candles([100.0, 101.0]), MaCross())
    assert len(make_candles([100.0, 101.0])) < MIN_BARS


# ---- 无交易：指标为 0 且不除零 ----

def test_no_trades_does_not_divide_by_zero():
    closes = [100.0] * 10
    result = Backtester().run(make_candles(closes), MaCross(fast=3, slow=5))

    assert result["trade_count"] == 0
    assert result["trades"] == []
    assert result["win_rate_pct"] == 0.0
    assert result["profit_factor"] == 0.0
    assert result["total_return_pct"] == 0.0
    assert result["max_drawdown_pct"] == 0.0
    assert result["sharpe"] == 0.0
    assert result["final_equity"] == pytest.approx(10000.0)
    assert result["buy_and_hold_return_pct"] == 0.0
    assert len(result["equity_curve"]) == len(closes)
    assert all(point["equity"] == pytest.approx(10000.0) for point in result["equity_curve"])


# ---- 基准与薄封装 ----

def test_buy_and_hold_benchmark_is_price_change():
    closes = [100.0, 110.0, 120.0]
    result = Backtester().run(make_candles(closes), MaCross(fast=3, slow=5))
    assert result["trade_count"] == 0
    assert result["buy_and_hold_return_pct"] == pytest.approx(20.0)


def test_quant_research_backtest_wrapper():
    candles = make_candles(trend_closes())
    direct = Backtester(ZERO_COST).run(candles, MaCross(fast=5, slow=20))

    by_name = backtest(candles, "ma_cross", config=ZERO_COST, fast=5, slow=20)
    by_instance = backtest(candles, MaCross(fast=5, slow=20), config=ZERO_COST)
    by_dict = backtest(candles, "ma_cross", config={"fee_bps": 0.0, "slippage_bps": 0.0})

    assert by_name["trade_count"] == direct["trade_count"] == 1
    assert by_instance["final_equity"] == pytest.approx(direct["final_equity"])
    assert by_dict["trades"][0]["entry_ts"] == direct["trades"][0]["entry_ts"]

    with pytest.raises(ValueError):
        backtest(candles, "no_such_strategy")
