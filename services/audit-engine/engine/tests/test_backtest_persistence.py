"""E3 — тест persist_backtest_run без живой БД.

Мокаем `get_session` и проверяем что INSERT-запрос содержит правильные
поля и что значения берутся из BacktestResult.
"""
from __future__ import annotations

import os
import sys
from datetime import date
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from scripts.backtest import BacktestResult, Forecast, persist_backtest_run


def _forecast(name: str, original: float, actual: float, growth: float, verdict: str) -> Forecast:
    return Forecast(
        audit_id="ab12cd34",
        complex_name=name,
        apartment_type="2BR",
        audit_date=date(2025, 6, 1),
        horizon_years=1.0,
        original_price=original,
        growth_annual_pct=growth,
        verdict=verdict,
        target_date=date(2026, 6, 1),
        projected_price=original * (1 + growth / 100),
        actual_price=actual,
    )


def _make_result() -> BacktestResult:
    """BacktestResult с парой forecast-ов."""
    return BacktestResult(
        period_from=date(2025, 6, 1),
        period_to=date(2026, 6, 1),
        forecasts=[
            _forecast("ЖК A", 10_000_000, 10_500_000, 8.0, "BUY"),
            _forecast("ЖК B", 6_000_000, 6_400_000, 5.0, "NEUTRAL"),
        ],
    )


@pytest.mark.asyncio
async def test_persist_backtest_run_inserts_with_correct_fields():
    result = _make_result()
    report_text = "# Back-test 2025-06 → 2026-06\n\n…"

    # Mock session
    mock_result = MagicMock()
    mock_result.scalar = MagicMock(return_value=42)

    mock_session = MagicMock()
    mock_session.execute = AsyncMock(return_value=mock_result)
    mock_session.commit = AsyncMock()

    # async ctx mgr — get_session() returns this
    mock_cm = MagicMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_session)
    mock_cm.__aexit__ = AsyncMock(return_value=None)

    with patch("audit_engine.db.get_session", return_value=mock_cm):
        run_id = await persist_backtest_run(result, report_text)

    assert run_id == 42

    # Проверим SQL и параметры
    mock_session.execute.assert_called_once()
    args, _ = mock_session.execute.call_args
    sql_text = str(args[0])
    params = args[1]

    assert "INSERT INTO backtest_runs" in sql_text
    assert "n_forecasts" in sql_text
    assert "mape" in sql_text
    assert "markdown_report" in sql_text

    assert params["n"] == 2
    assert params["pf"] == date(2025, 6, 1)
    assert params["pt"] == date(2026, 6, 1)
    assert params["md"] == report_text
    assert params["mape"] is not None
    assert params["mape"] > 0  # есть отклонение от факта


@pytest.mark.asyncio
async def test_persist_handles_empty_forecasts():
    """Пустой результат всё равно создаёт запись (трекинг тишины)."""
    result = BacktestResult(period_from=date(2025, 6, 1), period_to=date(2026, 6, 1), forecasts=[])

    mock_result = MagicMock()
    mock_result.scalar = MagicMock(return_value=99)

    mock_session = MagicMock()
    mock_session.execute = AsyncMock(return_value=mock_result)
    mock_session.commit = AsyncMock()

    mock_cm = MagicMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_session)
    mock_cm.__aexit__ = AsyncMock(return_value=None)

    with patch("audit_engine.db.get_session", return_value=mock_cm):
        run_id = await persist_backtest_run(result, "empty report")

    assert run_id == 99
    args, _ = mock_session.execute.call_args
    params = args[1]
    assert params["n"] == 0
    assert params["mape"] is None
    assert params["rmse"] is None
