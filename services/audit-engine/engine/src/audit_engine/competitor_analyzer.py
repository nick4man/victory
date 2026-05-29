"""Конкурентный анализ: перцентиль цены аудируемого объекта среди компов.

Подход: собираем `price_per_sqm` по компам → считаем p25/p50/p75 → для
аудитной цены определяем эмпирический перцентиль (с линейной
интерполяцией) → выдаём сигнал OVERPAY/FAIR/UNDERPAY. При меньше чем
`MIN_SAMPLE_SIZE` компах сигнал INSUFFICIENT — не принимаем решений на
шуме.

Дополнительно: при N >= 8 параллельно прогоняется hedonic-регрессия
(см. `hedonic.py`) — модель учитывает rooms/area/distance, в отличие
от чисто-перцентильного подхода.
"""
from __future__ import annotations

import statistics
from typing import Iterable, Optional

from audit_engine.hedonic import HedonicTarget, fit_and_predict
from audit_engine.models import (
    Competitor,
    CompetitorAnalysis,
    CompetitorSignal,
)

MIN_SAMPLE_SIZE = 5
OVERPAY_PERCENTILE = 75.0
UNDERPAY_PERCENTILE = 25.0
TOP_N = 5


def analyze(
    audit_price_per_sqm: float,
    competitors: Iterable[Competitor],
    radius_m: int = 2000,
    *,
    target_rooms: Optional[int] = None,
    target_area_sqm: Optional[float] = None,
) -> CompetitorAnalysis:
    """Синхронный analyzer. IO-less — получает уже загруженный список компов.

    `target_rooms` / `target_area_sqm` — параметры аудитного объекта; если
    оба заданы и компов >= 8, считаем hedonic regression и кладём в `hedonic`.
    """
    comps = list(competitors)
    sample_size = len(comps)

    hedonic_dict: Optional[dict] = None
    if (
        target_rooms is not None
        and target_area_sqm is not None
        and target_area_sqm > 0
    ):
        hed = fit_and_predict(
            HedonicTarget(rooms=target_rooms, area_sqm=target_area_sqm),
            comps,
        )
        if hed is not None:
            hedonic_dict = hed.to_dict()

    if sample_size < MIN_SAMPLE_SIZE:
        return CompetitorAnalysis(
            audit_price_per_sqm=audit_price_per_sqm,
            sample_size=sample_size,
            radius_m=radius_m,
            signal=CompetitorSignal.INSUFFICIENT,
            top5=_closest_to_price(comps, audit_price_per_sqm, TOP_N),
            hedonic=hedonic_dict,
        )

    prices = sorted(c.price_per_sqm for c in comps)
    median = statistics.median(prices)
    p25 = _quantile(prices, 0.25)
    p75 = _quantile(prices, 0.75)
    percentile = _empirical_percentile(prices, audit_price_per_sqm)

    if percentile >= OVERPAY_PERCENTILE:
        signal = CompetitorSignal.OVERPAY
    elif percentile <= UNDERPAY_PERCENTILE:
        signal = CompetitorSignal.UNDERPAY
    else:
        signal = CompetitorSignal.FAIR

    return CompetitorAnalysis(
        audit_price_per_sqm=audit_price_per_sqm,
        sample_size=sample_size,
        radius_m=radius_m,
        median_price_per_sqm=round(median, 2),
        p25_price_per_sqm=round(p25, 2),
        p75_price_per_sqm=round(p75, 2),
        percentile=round(percentile, 1),
        signal=signal,
        top5=_closest_to_price(comps, audit_price_per_sqm, TOP_N),
        hedonic=hedonic_dict,
    )


def _quantile(sorted_values: list[float], q: float) -> float:
    """Линейная интерполяция перцентиля (как numpy `linear`).

    sorted_values — отсортированный по возрастанию; q ∈ [0, 1].
    """
    if not sorted_values:
        raise ValueError("empty sample")
    n = len(sorted_values)
    if n == 1:
        return sorted_values[0]
    pos = q * (n - 1)
    lo = int(pos)
    hi = min(lo + 1, n - 1)
    frac = pos - lo
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * frac


def _empirical_percentile(sorted_values: list[float], target: float) -> float:
    """Эмпирический перцентиль `target` в отсортированной выборке (0..100).

    Используем rank / (n - 1) * 100 — симметрично `_quantile`. target за
    пределами выборки клампится на [0, 100].
    """
    n = len(sorted_values)
    if n <= 1:
        return 50.0
    if target <= sorted_values[0]:
        return 0.0
    if target >= sorted_values[-1]:
        return 100.0
    for i in range(n - 1):
        if sorted_values[i] <= target <= sorted_values[i + 1]:
            span = sorted_values[i + 1] - sorted_values[i]
            frac = 0.0 if span == 0 else (target - sorted_values[i]) / span
            rank = i + frac
            return rank / (n - 1) * 100.0
    return 50.0


def _closest_to_price(
    comps: list[Competitor],
    target: float,
    n: int,
) -> list[Competitor]:
    return sorted(comps, key=lambda c: abs(c.price_per_sqm - target))[:n]
