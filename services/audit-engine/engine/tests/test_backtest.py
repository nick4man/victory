"""Unit-тесты для scripts/backtest — только pure-функции, без DB/сети."""
from datetime import date

import pytest

from scripts.backtest import (
    BacktestResult,
    Forecast,
    forecasts_from_pairs,
    mape,
    project_price,
    render_markdown,
    rmse,
    sign_accuracy,
)


def _fc(**overrides) -> Forecast:
    base = dict(
        audit_id="a1",
        complex_name="ЖК Тест",
        apartment_type="1BR",
        audit_date=date(2025, 1, 1),
        horizon_years=5,
        original_price=10_000_000,
        growth_annual_pct=5.0,
        verdict="buy",
        target_date=date(2026, 1, 1),
        projected_price=10_500_000,
        actual_price=10_500_000,
    )
    base.update(overrides)
    return Forecast(**base)


def test_project_price_basic():
    assert project_price(100.0, 10.0, 1.0) == pytest.approx(110.0)
    assert project_price(100.0, 10.0, 2.0) == pytest.approx(121.0)


def test_project_price_zero_growth():
    assert project_price(100.0, 0.0, 5.0) == 100.0


def test_project_price_fractional_years():
    result = project_price(100.0, 20.0, 0.5)
    assert 109.0 < result < 110.0


def test_abs_pct_error_exact_hit():
    f = _fc(projected_price=100.0, actual_price=100.0)
    assert f.abs_pct_error == 0.0


def test_abs_pct_error_25_pct_over():
    f = _fc(projected_price=125.0, actual_price=100.0)
    assert f.abs_pct_error == pytest.approx(25.0)


def test_abs_pct_error_zero_actual_is_inf():
    import math
    f = _fc(projected_price=100.0, actual_price=0.0)
    assert math.isinf(f.abs_pct_error)


def test_direction_correct_buy_up():
    f = _fc(original_price=100.0, actual_price=110.0, verdict="buy")
    assert f.direction_correct is True


def test_direction_correct_buy_down_is_wrong():
    f = _fc(original_price=100.0, actual_price=90.0, verdict="buy")
    assert f.direction_correct is False


def test_direction_correct_hold_flat():
    f = _fc(original_price=100.0, actual_price=100.0, verdict="neutral")
    assert f.direction_correct is True


def test_mape_multiple():
    fs = [
        _fc(projected_price=100, actual_price=100),
        _fc(projected_price=120, actual_price=100),
        _fc(projected_price=80, actual_price=100),
    ]
    assert mape(fs) == pytest.approx(40.0 / 3, rel=1e-3)


def test_mape_empty_returns_none():
    assert mape([]) is None


def test_rmse_basic():
    fs = [
        _fc(projected_price=110, actual_price=100),
        _fc(projected_price=90, actual_price=100),
    ]
    assert rmse(fs) == pytest.approx(10.0)


def test_rmse_skips_zero_actual():
    fs = [_fc(projected_price=100, actual_price=0)]
    assert rmse(fs) is None


def test_sign_accuracy_all_correct():
    fs = [
        _fc(original_price=100, actual_price=110, verdict="buy"),
        _fc(original_price=100, actual_price=100, verdict="neutral"),
    ]
    assert sign_accuracy(fs) == 100.0


def test_sign_accuracy_mixed():
    fs = [
        _fc(original_price=100, actual_price=110, verdict="buy"),
        _fc(original_price=100, actual_price=90, verdict="buy"),
    ]
    assert sign_accuracy(fs) == 50.0


def test_sign_accuracy_empty():
    assert sign_accuracy([]) is None


def test_forecasts_from_pairs_minimal():
    pairs = [
        {
            "audit_id": "x",
            "complex_name": "ЖК",
            "audit_date": "2025-01-01",
            "target_date": "2026-01-01",
            "original_price": 10_000_000,
            "growth_annual_pct": 10.0,
            "verdict": "buy",
            "actual_price": 11_000_000,
        }
    ]
    fs = forecasts_from_pairs(pairs)
    assert len(fs) == 1
    # 365 календарных дней / 365.25 ≈ 0.9993 года — допуск 0.1%
    assert fs[0].projected_price == pytest.approx(10_000_000 * 1.1, rel=1e-3)
    assert fs[0].abs_pct_error < 0.1
    assert fs[0].direction_correct is True


def test_render_markdown_empty_case():
    r = BacktestResult(date(2025, 1, 1), date(2025, 12, 31), [])
    md = render_markdown(r)
    assert "Нет пар" in md


def test_render_markdown_includes_metrics_and_headers():
    fs = [
        _fc(projected_price=100, actual_price=100, original_price=100, verdict="buy"),
        _fc(projected_price=140, actual_price=100, original_price=100, verdict="buy"),
    ]
    r = BacktestResult(date(2025, 1, 1), date(2026, 1, 1), fs)
    md = render_markdown(r)
    assert "MAPE" in md and "Sign-accuracy" in md
    assert "| ЖК |" in md
    assert "Топ-5 худших прогнозов" in md


def test_render_markdown_flags_mape_over_20():
    fs = [_fc(projected_price=150, actual_price=100) for _ in range(3)]
    r = BacktestResult(date(2025, 1, 1), date(2026, 1, 1), fs)
    md = render_markdown(r)
    assert "> 20%" in md
    assert "откалибровать" in md.lower()


def test_render_markdown_flags_sign_accuracy_under_70():
    fs = [
        _fc(original_price=100, actual_price=90, verdict="buy"),
        _fc(original_price=100, actual_price=80, verdict="buy"),
        _fc(original_price=100, actual_price=70, verdict="buy"),
    ]
    r = BacktestResult(date(2025, 1, 1), date(2026, 1, 1), fs)
    md = render_markdown(r)
    assert "< 70%" in md
    assert "verdict" in md.lower()
