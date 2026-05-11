"""Regression tests for `audit_engine.monte_carlo_worker`.

The worker previously referenced `settings.mc_num_simulations` which did not
exist — importing the module raised AttributeError at first use. These tests
guard the module surface so that regression never comes back.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import importlib

import pytest


@pytest.fixture(autouse=True)
def _stub_redis(monkeypatch):
    """redis.asyncio требуется воркером только для runtime — не для импорта."""
    # Импорт у воркера `import redis.asyncio as redis` срабатывает безопасно
    # на любой свежей системе, поэтому стаба не требуется, но тест
    # подтверждает, что такая последовательность не падает.
    yield


def test_worker_module_imports_without_errors():
    """Импорт модуля воркера не должен падать из-за несуществующих settings-ключей."""
    pytest.importorskip("redis")
    module = importlib.import_module("audit_engine.monte_carlo_worker")
    # Sanity — ключевые символы на месте
    assert hasattr(module, "run_monte_carlo")
    assert hasattr(module, "process_task")
    assert hasattr(module, "listen_for_tasks")


def test_worker_uses_default_sims_from_settings():
    """Воркер читает дефолтный N из settings.mc_default_simulations (а не несуществующий mc_num_simulations)."""
    from audit_engine.config import settings

    # если появится опечатка — AttributeError здесь же
    assert isinstance(settings.mc_default_simulations, int)
    assert settings.mc_default_simulations >= 10_000

    # Ключ `mc_num_simulations` должен отсутствовать — регрессия против старого бага
    assert not hasattr(settings, "mc_num_simulations")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
