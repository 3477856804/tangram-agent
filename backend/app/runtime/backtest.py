"""事件驱动回测核心引擎（纯标准库实现，行为参考 Jesse 的逐 bar 回测）。

设计红线（与项目一致）：

* 只用标准库，不引入任何第三方依赖；所有指标都由真实 K 线与成交记录计算，
  绝不补造数据、绝不预设收益。
* 严格避免未来函数：策略在 ``i`` 根 K 线**收盘后**才能看到该 bar 及之前的收盘价，
  其产生的信号统一在**下一根 K 线开盘价**成交；信号不会用当根收盘价成交。
* 成交价格计入滑点（买入上浮、卖出下调）与双边手续费；long-only、不加杠杆。
* 数据不足（少于 ``MIN_BARS`` 根）或 K 线非法时如实抛错，不返回任何编造结果。

本模块只做历史模拟，不接任何交易/下单 API，也不构成投资建议。
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Sequence

from .quant_research import (
    InsufficientDataError,
    max_drawdown as _max_drawdown,
    rsi as _rsi,
    sharpe_ratio as _sharpe_ratio,
)

__all__ = [
    "MIN_BARS",
    "Candle",
    "Strategy",
    "MaCross",
    "RsiReversion",
    "BacktestConfig",
    "Backtester",
]

#: 回测所需的最少 K 线数：至少要能算出两个 bar 收益（夏普需要样本标准差）。
MIN_BARS = 3


def _finite_number(name: str, value: Any, *, positive: bool = False, non_negative: bool = False) -> float:
    """校验一个数值字段：必须是有限数值，按需要求 >0 / >=0；否则抛 ValueError。"""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} 必须是数值，实际为 {value!r}")
    f = float(value)
    if not math.isfinite(f):
        raise ValueError(f"{name} 必须是有限数值，实际为 {value!r}")
    if positive and f <= 0.0:
        raise ValueError(f"{name} 必须大于 0，实际为 {f!r}")
    if non_negative and f < 0.0:
        raise ValueError(f"{name} 不能为负数，实际为 {f!r}")
    return f


def _positive_int(name: str, value: Any, *, minimum: int = 1) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ValueError(f"{name} 必须是 >= {minimum} 的整数，实际为 {value!r}")
    return value


@dataclass(frozen=True, slots=True)
class Candle:
    """单根 K 线。价格必须为正、high 必须 >= low，否则构造即抛 ValueError。"""

    ts: int | float | str
    open: float
    high: float
    low: float
    close: float
    volume: float = 0.0

    def __post_init__(self) -> None:
        ts_ok = (
            isinstance(self.ts, (int, float, str))
            and not isinstance(self.ts, bool)
            and not (isinstance(self.ts, str) and not self.ts.strip())
        )
        if not ts_ok:
            raise ValueError(f"Candle.ts 必须是非空字符串或有限数值，实际为 {self.ts!r}")
        if isinstance(self.ts, (int, float)) and not math.isfinite(float(self.ts)):
            raise ValueError(f"Candle.ts 必须是有限数值，实际为 {self.ts!r}")
        for name in ("open", "high", "low", "close"):
            _finite_number(f"Candle.{name}", getattr(self, name), positive=True)
        _finite_number("Candle.volume", self.volume, non_negative=True)
        if float(self.high) < float(self.low):
            raise ValueError(
                f"Candle.high({self.high!r}) 不能小于 Candle.low({self.low!r})"
            )


class Strategy:
    """策略接口：每个已收盘的 bar 调用一次 ``on_bar(ctx)``。

    策略只能通过 ``ctx`` 读取截至当前 bar 的历史数据，并通过 ``ctx.buy()`` /
    ``ctx.close()`` 下单；下单会在下一根 bar 的开盘价成交。
    """

    name = "strategy"

    def on_bar(self, ctx: "BarContext") -> None:  # pragma: no cover - 接口定义
        raise NotImplementedError("策略必须实现 on_bar(ctx)")


class BarContext:
    """单根 bar 的策略上下文：只暴露当前及历史数据，不暴露任何未来数据。"""

    __slots__ = ("_candle", "_closes", "_index", "_position", "_equity", "_pending")

    def __init__(
        self,
        candle: Candle,
        closes: Sequence[float],
        index: int,
        position: float,
        equity: float,
    ) -> None:
        self._candle = candle
        self._closes = tuple(closes)
        self._index = index
        self._position = position
        self._equity = equity
        self._pending: tuple[str, str] | None = None

    @property
    def candle(self) -> Candle:
        """当前已收盘的 bar。"""
        return self._candle

    @property
    def closes(self) -> tuple[float, ...]:
        """截至当前 bar（含）的收盘价序列，长度恒为 ``index + 1``。"""
        return self._closes

    @property
    def index(self) -> int:
        return self._index

    @property
    def position(self) -> float:
        """当前持仓数量（long-only，未持仓为 0.0）。"""
        return self._position

    @property
    def has_position(self) -> bool:
        return self._position > 0.0

    @property
    def equity(self) -> float:
        """按当前 bar 收盘价盯市后的账户权益。"""
        return self._equity

    def buy(self, reason: str = "buy_signal") -> None:
        """请求全仓买入（下一根 bar 开盘成交）；已持仓时忽略。"""
        if self._position > 0.0:
            return
        self._pending = ("buy", str(reason))

    def close(self, reason: str = "exit_signal") -> None:
        """请求清仓（下一根 bar 开盘成交）；未持仓时忽略。"""
        if self._position <= 0.0:
            return
        self._pending = ("sell", str(reason))


def _sma(values: Sequence[float], period: int) -> float:
    window = values[-period:]
    return sum(window) / period


class MaCross(Strategy):
    """均线交叉策略（long-only）：fast 上穿 slow 全仓买入，下穿清仓。"""

    name = "ma_cross"

    def __init__(self, fast: int = 5, slow: int = 20) -> None:
        _positive_int("fast", fast)
        _positive_int("slow", slow)
        if fast >= slow:
            raise ValueError(f"fast({fast}) 必须小于 slow({slow})")
        self.fast = fast
        self.slow = slow

    def on_bar(self, ctx: BarContext) -> None:
        closes = ctx.closes
        if len(closes) < self.slow + 1:
            return
        fast_now = _sma(closes, self.fast)
        slow_now = _sma(closes, self.slow)
        fast_prev = _sma(closes[:-1], self.fast)
        slow_prev = _sma(closes[:-1], self.slow)
        if fast_prev <= slow_prev and fast_now > slow_now:
            ctx.buy("ma_golden_cross")
        elif fast_prev >= slow_prev and fast_now < slow_now:
            ctx.close("ma_death_cross")


class RsiReversion(Strategy):
    """RSI 均值回归策略（long-only）：RSI 低于 buy 买入，高于 sell 清仓。"""

    name = "rsi_reversion"

    def __init__(self, period: int = 14, buy: float = 30.0, sell: float = 70.0) -> None:
        _positive_int("period", period, minimum=2)
        buy_f = _finite_number("buy", buy)
        sell_f = _finite_number("sell", sell)
        if not 0.0 < buy_f < sell_f < 100.0:
            raise ValueError(
                f"必须满足 0 < buy < sell < 100，实际 buy={buy!r}, sell={sell!r}"
            )
        self.period = period
        self.buy = buy_f
        self.sell = sell_f

    def on_bar(self, ctx: BarContext) -> None:
        closes = ctx.closes
        if len(closes) < self.period + 1:
            return
        value = _rsi(closes, self.period)[-1]
        if not ctx.has_position:
            if value < self.buy:
                ctx.buy("rsi_oversold")
        elif value > self.sell:
            ctx.close("rsi_overbought")


@dataclass(slots=True)
class BacktestConfig:
    """回测参数：费率/滑点以 bps（万分之一）计。"""

    fee_bps: float = 5.0
    slippage_bps: float = 2.0
    initial_cash: float = 10000.0
    position_pct: float = 1.0

    def __post_init__(self) -> None:
        _finite_number("fee_bps", self.fee_bps, non_negative=True)
        _finite_number("slippage_bps", self.slippage_bps, non_negative=True)
        _finite_number("initial_cash", self.initial_cash, positive=True)
        pct = _finite_number("position_pct", self.position_pct, positive=True)
        if pct > 1.0:
            raise ValueError(f"position_pct 必须在 (0, 1]，实际为 {self.position_pct!r}")


def _validate_candles(candles: Sequence[Candle]) -> list[Candle]:
    if isinstance(candles, (str, bytes)):
        raise TypeError("candles 必须是 Candle 序列，不能是字符串")
    try:
        bars = list(candles)
    except TypeError as exc:
        raise TypeError(f"candles 不可迭代：{exc}") from exc
    for i, bar in enumerate(bars):
        if not isinstance(bar, Candle):
            raise TypeError(f"第 {i} 根 K 线不是 Candle 实例：{type(bar).__name__}")
    if len(bars) < MIN_BARS:
        raise InsufficientDataError(
            f"回测至少需要 {MIN_BARS} 根 K 线，实际只有 {len(bars)} 根，拒绝编造回测结果"
        )
    return bars


def _round(value: float) -> float:
    return round(float(value), 6)


class Backtester:
    """逐 bar 事件驱动回测器。

    每个 bar 的处理顺序：

    1. 用本 bar **开盘价** 成交上一 bar 收盘后产生的挂单（计入滑点与手续费）；
    2. 用本 bar **收盘价** 盯市，计算权益；
    3. 调用 ``strategy.on_bar(ctx)``，策略只能看到截至本 bar 的数据；
    4. 最后一根 bar 若仍持仓，按收盘价强制平仓（``reason="end_of_data"``）。
    """

    def __init__(self, config: BacktestConfig | None = None) -> None:
        if config is not None and not isinstance(config, BacktestConfig):
            raise TypeError("config 必须是 BacktestConfig 实例或 None")
        self.config = config or BacktestConfig()

    def run(self, candles: Sequence[Candle], strategy: Strategy) -> dict[str, Any]:
        bars = _validate_candles(candles)
        if not isinstance(strategy, Strategy):
            raise TypeError("strategy 必须是 Strategy 实例")

        cfg = self.config
        fee_rate = float(cfg.fee_bps) / 10000.0
        slippage = float(cfg.slippage_bps) / 10000.0
        cash = float(cfg.initial_cash)
        qty = 0.0
        entry: dict[str, Any] | None = None
        pending: tuple[str, str] | None = None
        trades: list[dict[str, Any]] = []
        equity_curve: list[dict[str, Any]] = []
        equity_values: list[float] = []

        def close_position(exit_ts: Any, exit_price: float, reason: str) -> None:
            nonlocal cash, qty, entry
            assert entry is not None
            gross = qty * exit_price
            fee = gross * fee_rate
            cash += gross - fee
            entry_cost = entry["gross"] + entry["fee"]
            pnl = (gross - fee) - entry_cost
            trades.append(
                {
                    "entry_ts": entry["ts"],
                    "exit_ts": exit_ts,
                    "entry_price": _round(entry["price"]),
                    "exit_price": _round(exit_price),
                    "qty": _round(qty),
                    "pnl": _round(pnl),
                    "return_pct": _round(pnl / entry_cost * 100.0) if entry_cost > 0.0 else 0.0,
                    "reason": reason,
                    "entry_reason": entry["reason"],
                }
            )
            qty = 0.0
            entry = None

        last_index = len(bars) - 1
        for i, bar in enumerate(bars):
            # 1) 上一 bar 的信号在本 bar 开盘成交。
            if pending is not None:
                side, reason = pending
                pending = None
                if side == "buy" and qty == 0.0:
                    exec_price = bar.open * (1.0 + slippage)
                    budget = cash * float(cfg.position_pct)
                    filled = budget / (exec_price * (1.0 + fee_rate))
                    if filled > 0.0:
                        gross = filled * exec_price
                        fee = gross * fee_rate
                        cash -= gross + fee
                        qty = filled
                        entry = {
                            "ts": bar.ts,
                            "price": exec_price,
                            "gross": gross,
                            "fee": fee,
                            "reason": reason,
                        }
                elif side == "sell" and qty > 0.0:
                    close_position(bar.ts, bar.open * (1.0 - slippage), reason)

            # 2) 按收盘价盯市。
            equity = cash + qty * bar.close

            # 3) 策略只能看到截至本 bar 收盘的数据。
            ctx = BarContext(bar, [b.close for b in bars[: i + 1]], i, qty, equity)
            strategy.on_bar(ctx)
            pending = ctx._pending

            # 4) 数据结束仍有持仓：按收盘价如实强制平仓。
            if i == last_index and qty > 0.0:
                close_position(bar.ts, bar.close * (1.0 - slippage), "end_of_data")
                equity = cash

            equity_values.append(equity)
            equity_curve.append({"ts": bar.ts, "equity": _round(equity)})

        final_equity = cash if qty == 0.0 else equity_values[-1]
        total_return_pct = (final_equity / float(cfg.initial_cash) - 1.0) * 100.0

        try:
            max_dd_pct = _max_drawdown(equity_values) * 100.0
        except InsufficientDataError:  # pragma: no cover - MIN_BARS 已保证
            max_dd_pct = 0.0
        try:
            sharpe = _sharpe_ratio(equity_values)
        except InsufficientDataError:
            # 权益无波动（如全程空仓）时夏普无定义，如实记 0.0。
            sharpe = 0.0

        wins = [t for t in trades if t["pnl"] > 0.0]
        gross_profit = sum(t["pnl"] for t in trades if t["pnl"] > 0.0)
        gross_loss = -sum(t["pnl"] for t in trades if t["pnl"] < 0.0)
        if not trades or (gross_profit == 0.0 and gross_loss == 0.0):
            profit_factor: float | None = 0.0
        elif gross_loss == 0.0:
            profit_factor = None  # 无亏损交易，盈亏比无定义，不编造数值
        else:
            profit_factor = gross_profit / gross_loss

        buy_and_hold_pct = (bars[-1].close / bars[0].close - 1.0) * 100.0

        return {
            "total_return_pct": _round(total_return_pct),
            "max_drawdown_pct": _round(max_dd_pct),
            "sharpe": _round(sharpe),
            "win_rate_pct": _round(len(wins) / len(trades) * 100.0) if trades else 0.0,
            "trade_count": len(trades),
            "profit_factor": None if profit_factor is None else _round(profit_factor),
            "final_equity": _round(final_equity),
            "buy_and_hold_return_pct": _round(buy_and_hold_pct),
            "equity_curve": equity_curve,
            "trades": trades,
        }
