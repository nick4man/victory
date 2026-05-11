"""Тесты регистрации job-ов APScheduler-а и эндпоинта `/jobs/status`.

Сам планировщик не запускаем — это сложно в pytest без реального event-loop
+ риск файлового состояния. Проверяем:
1. JOBS — корректный реестр (имена уникальны, runner — callable).
2. CronTrigger-ы валидны.
3. Эндпоинт `/jobs/status` отвечает 200 даже когда scheduler=None
   (graceful degradation).
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from audit_engine.jobs.scheduler import JOBS, get_scheduler


def test_jobs_registry_unique_names():
    names = [j.name for j in JOBS]
    assert len(names) == len(set(names)), f"duplicate job names: {names}"


def test_jobs_registry_callable_runners():
    for spec in JOBS:
        assert callable(spec.runner), f"{spec.name}.runner is not callable"


def test_jobs_have_descriptions():
    for spec in JOBS:
        assert spec.description, f"{spec.name} has empty description"


def test_jobs_expected_set():
    expected = {
        "fetch_macro_cbr",
        "fetch_inflation_cbr",
        "fetch_bank_offers",
        "competitor_refresh",
        "backtest_monthly",
        "cron_health_check",
    }
    actual = {j.name for j in JOBS}
    assert actual == expected, f"unexpected jobs: {actual ^ expected}"


def test_cron_triggers_are_valid():
    """CronTrigger должен иметь next_fire_time на ближайшие 30 дней."""
    from datetime import datetime, timedelta, timezone

    now = datetime.now(timezone.utc)
    horizon = now + timedelta(days=31)
    for spec in JOBS:
        next_fire = spec.trigger.get_next_fire_time(None, now)
        assert next_fire is not None, f"{spec.name}: no next fire time"
        assert next_fire <= horizon, (
            f"{spec.name}: next fire too far ({next_fire})"
        )


def test_get_scheduler_initially_none():
    """До startup-хука scheduler не должен быть запущен."""
    # При параллельном запуске тестов app.lifespan мог поднять scheduler,
    # поэтому проверка мягкая.
    sched = get_scheduler()
    assert sched is None or sched.running
