#!/usr/bin/env python3
"""Benchmark Monte-Carlo simulation speed.

Сравнивает reference (`MonteCarloSimulator`) и fast (`MonteCarloSimulatorFast`)
симуляторы на N ∈ {10k, 100k, 500k, 1M}. Измеряет wall-clock, печатает
сводную таблицу + ускорение fast-версии относительно reference.
"""
from __future__ import annotations

import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.models import AuditInput
from audit_engine.monte_carlo import MonteCarloSimulator
from audit_engine.monte_carlo_fast import MonteCarloSimulatorFast


SIZES = [10_000, 100_000, 500_000, 1_000_000]
REFERENCE_MAX = 100_000  # reference симулятор слишком медленный выше
REPEATS = 3


def make_input() -> AuditInput:
    return AuditInput(
        complex_name="Мостовая 5",
        apartment_type="2BR",
        area_sqm=65.0,
        price_total=12_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
        cash_discount_pct=10.0,
    )


def time_run(cls, inp: AuditInput, n: int, seed: int = 42) -> list[float]:
    runs = []
    for _ in range(REPEATS):
        sim = cls(inp, num_simulations=n, seed=seed)
        t0 = time.perf_counter()
        sim.run()
        runs.append(time.perf_counter() - t0)
    return runs


def summarize(runs: list[float]) -> dict[str, float]:
    runs_sorted = sorted(runs)
    return {
        "p50": statistics.median(runs_sorted),
        "min": runs_sorted[0],
        "max": runs_sorted[-1],
    }


def main() -> None:
    inp = make_input()

    print(f"\nMonte-Carlo bench  (repeats={REPEATS})")
    print("-" * 78)
    print(f"{'N':>10} {'ref p50':>12} {'fast p50':>12} {'fast min':>12} {'fast max':>12} {'speedup':>10}")
    print("-" * 78)

    for n in SIZES:
        ref_stats = None
        if n <= REFERENCE_MAX:
            ref_runs = time_run(MonteCarloSimulator, inp, n)
            ref_stats = summarize(ref_runs)

        fast_runs = time_run(MonteCarloSimulatorFast, inp, n)
        fast_stats = summarize(fast_runs)

        if ref_stats:
            speedup = ref_stats["p50"] / fast_stats["p50"]
            ref_p50_str = f"{ref_stats['p50'] * 1000:8.1f} ms"
            speedup_str = f"{speedup:7.1f}x"
        else:
            ref_p50_str = "     — (skip)"
            speedup_str = "         —"

        print(
            f"{n:>10,} "
            f"{ref_p50_str:>12} "
            f"{fast_stats['p50'] * 1000:>9.1f} ms "
            f"{fast_stats['min'] * 1000:>9.1f} ms "
            f"{fast_stats['max'] * 1000:>9.1f} ms "
            f"{speedup_str:>10}"
        )

    # Sanity-check output on the canonical N
    sim = MonteCarloSimulatorFast(inp, num_simulations=100_000, seed=42)
    result = sim.run()
    print("-" * 78)
    print(f"\nResults at N=100,000 (seed=42):")
    print(
        f"  Cash:     EI mean={result.cash.ei_mean:.4f} "
        f"p1={result.cash.ei_p1:.4f} p99={result.cash.ei_p99:.4f}"
    )
    print(
        f"  Mortgage: EI mean={result.mortgage.ei_mean:.4f} "
        f"p1={result.mortgage.ei_p1:.4f} p99={result.mortgage.ei_p99:.4f}"
    )
    print(
        f"  Deposit:  EI mean={result.deposit.ei_mean:.4f} "
        f"p1={result.deposit.ei_p1:.4f} p99={result.deposit.ei_p99:.4f}"
    )
    print(f"  Recommended: {result.recommended_strategy}  ({result.confidence_level})")


if __name__ == "__main__":
    main()
