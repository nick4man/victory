"""E4 unit-тесты — cron health check + alert message formatter."""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest

from scripts.check_cron_health import (
    EXPECTED_INTERVAL_HOURS,
    collect_unhealthy_jobs,
    enqueue_alert,
    format_alert_message,
    run,
)


# -----------------------------------------------------------------------
# format_alert_message
# -----------------------------------------------------------------------

def test_format_empty_returns_empty_string():
    assert format_alert_message([]) == ""


def test_format_failed_includes_error():
    msg = format_alert_message([{
        "job_name": "fetch_macro_cbr",
        "reason": "last_run_failed",
        "started_at": "2026-05-11T10:00:00+00:00",
        "error": "connection refused",
    }])
    assert "audit-watchdog" in msg
    assert "fetch_macro_cbr" in msg
    assert "failed" in msg
    assert "connection refused" in msg


def test_format_silence_includes_age():
    msg = format_alert_message([{
        "job_name": "fetch_bank_offers",
        "reason": "silence_too_long",
        "last_success_age_hours": 120.5,
        "expected_interval_hours": 48,
    }])
    assert "fetch_bank_offers" in msg
    assert "120.5" in msg
    assert "48" in msg


def test_format_multiple_jobs():
    msg = format_alert_message([
        {"job_name": "a", "reason": "last_run_failed", "started_at": "...", "error": "err1"},
        {"job_name": "b", "reason": "silence_too_long", "last_success_age_hours": 50, "expected_interval_hours": 24},
    ])
    assert "2 проблемных" in msg
    assert "a" in msg
    assert "b" in msg


# -----------------------------------------------------------------------
# EXPECTED_INTERVAL_HOURS
# -----------------------------------------------------------------------

def test_intervals_defined_for_all_jobs():
    """Все job-ы из scheduler должны иметь expected interval."""
    from audit_engine.jobs.scheduler import JOBS

    job_names = {j.name for j in JOBS}
    interval_names = set(EXPECTED_INTERVAL_HOURS.keys())
    # cron_health_check сам себя не мониторит → исключение
    job_names.discard("cron_health_check")
    missing = job_names - interval_names
    assert not missing, f"jobs без EXPECTED_INTERVAL_HOURS: {missing}"


# -----------------------------------------------------------------------
# enqueue_alert (mock DB)
# -----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_enqueue_dry_run_does_not_write():
    post_id = await enqueue_alert("test message", dry_run=True)
    assert post_id is None


@pytest.mark.asyncio
async def test_enqueue_inserts_into_posts_queue():
    mock_result = MagicMock()
    mock_result.scalar = MagicMock(return_value=777)
    mock_session = MagicMock()
    mock_session.execute = AsyncMock(return_value=mock_result)
    mock_session.commit = AsyncMock()
    mock_cm = MagicMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_session)
    mock_cm.__aexit__ = AsyncMock(return_value=None)

    with patch("audit_engine.db.get_session", return_value=mock_cm):
        post_id = await enqueue_alert("🚨 alert message", dry_run=False)

    assert post_id == 777
    args, _ = mock_session.execute.call_args
    sql = str(args[0])
    params = args[1]
    assert "INSERT INTO posts_queue" in sql
    assert params["msg"] == "🚨 alert message"
    assert "audit-watchdog" in sql  # requester hardcoded


# -----------------------------------------------------------------------
# collect_unhealthy_jobs — простой scenario test через mock
# -----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_collect_failed_job_detected():
    """Mock сессия возвращает 'failed' для одного job-а — он должен попасть в alerts."""

    # Подготавливаем mock-execute: для каждого job-а возвращаем 2 запроса:
    # 1) last success → None (никогда не успешен)
    # 2) last run → ('failed', 'connection refused', datetime.now())
    now = datetime.now(timezone.utc)

    call_state = {"calls": 0}

    async def fake_execute(sql_clause, params):
        call_state["calls"] += 1
        sql_str = str(sql_clause).lower()
        if "status = 'success'" in sql_str:
            r = MagicMock()
            r.scalar = MagicMock(return_value=None)
            return r
        # last run
        r = MagicMock()
        # для job-а 'fetch_macro_cbr' — failed; для всех других — success свежий
        if params["name"] == "fetch_macro_cbr":
            row = ("failed", "connection refused", now - timedelta(minutes=10))
        else:
            row = ("success", None, now - timedelta(minutes=10))
        r.first = MagicMock(return_value=row)
        return r

    mock_session = MagicMock()
    mock_session.execute = AsyncMock(side_effect=fake_execute)
    mock_cm = MagicMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_session)
    mock_cm.__aexit__ = AsyncMock(return_value=None)

    with patch("audit_engine.db.get_session", return_value=mock_cm):
        unhealthy = await collect_unhealthy_jobs()

    # должна быть запись про fetch_macro_cbr=failed
    fetch_macro_issue = next((u for u in unhealthy if u["job_name"] == "fetch_macro_cbr"), None)
    assert fetch_macro_issue is not None
    assert fetch_macro_issue["reason"] == "last_run_failed"
    assert "connection refused" in fetch_macro_issue["error"]
