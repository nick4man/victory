"""Prometheus metrics for MC endpoint.

Optional dependency — if `prometheus_client` is not installed, all metrics
collapse to no-ops so the API still boots.
"""
from __future__ import annotations

try:
    from prometheus_client import Counter, Histogram

    MC_DURATION = Histogram(
        "mc_duration_seconds",
        "Wall-clock duration of a Monte-Carlo run, by strategy and size bucket.",
        labelnames=("strategy", "size_bucket"),
        buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5),
    )
    MC_SIMS_TOTAL = Counter(
        "mc_sims_total",
        "Total Monte-Carlo simulations executed (summed across runs).",
        labelnames=("strategy",),
    )
    MC_CACHE_HITS = Counter(
        "mc_cache_hits_total",
        "Idempotent MC cache hits by (audit_id, n, seed, correlation).",
    )

    def size_bucket(n: int) -> str:
        if n <= 10_000:
            return "10k"
        if n <= 100_000:
            return "100k"
        if n <= 500_000:
            return "500k"
        return "1m_plus"

    _ENABLED = True
except ImportError:  # pragma: no cover — optional dependency
    class _NoopMetric:
        def labels(self, *_, **__):
            return self

        def observe(self, *_):
            return None

        def inc(self, *_):
            return None

    MC_DURATION = _NoopMetric()
    MC_SIMS_TOTAL = _NoopMetric()
    MC_CACHE_HITS = _NoopMetric()

    def size_bucket(n: int) -> str:
        return "unknown"

    _ENABLED = False
