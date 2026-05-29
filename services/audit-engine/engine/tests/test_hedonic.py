"""Unit-тесты для hedonic regression."""
import math
import os
import sys
from datetime import date

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.hedonic import (
    HedonicTarget,
    fit_and_predict,
    MIN_HEDONIC_SAMPLE,
)
from audit_engine.models import Competitor


def _comp(rooms: int, area: float, ppm: float, dist_m: int = 0) -> Competitor:
    return Competitor(
        complex_name="X",
        snapshot_date=date(2026, 1, 1),
        competitor_name="C",
        price_per_sqm=ppm,
        area_sqm=area,
        rooms=rooms,
        distance_m=dist_m,
        source="test",
    )


def test_fit_returns_none_on_insufficient_sample():
    comps = [_comp(2, 60, 200_000) for _ in range(MIN_HEDONIC_SAMPLE - 1)]
    assert fit_and_predict(HedonicTarget(2, 60), comps) is None


def test_fit_returns_none_on_rank_deficient():
    """Все компы — однокомнатные, одинаковая площадь, нулевая дистанция:
    нет вариативности → матрица вырождена."""
    comps = [_comp(1, 50, 200_000) for _ in range(15)]
    assert fit_and_predict(HedonicTarget(1, 50), comps) is None


def test_fit_recovers_known_log_linear_relationship():
    """Сгенерируем компы по точной log-линейной формуле — модель должна
    вернуть очень близкое предсказание."""
    rng_seed_seq = [
        (1, 40, 0), (1, 45, 100), (1, 50, 200),
        (2, 55, 100), (2, 60, 300), (2, 65, 400),
        (3, 70, 200), (3, 80, 500), (3, 90, 700),
        (4, 100, 600),
    ]
    # log(ppm) = 12.0 + 0.05·rooms − 0.002·distance_km + 0.1·log(area)
    base_ppm = lambda rooms, area, dkm: math.exp(
        12.0 + 0.05 * rooms - 0.002 * dkm + 0.1 * math.log(area)
    )
    comps = [
        _comp(r, a, base_ppm(r, a, d / 1000.0), d) for r, a, d in rng_seed_seq
    ]
    target = HedonicTarget(rooms=2, area_sqm=60.0, distance_km=0.0)
    result = fit_and_predict(target, comps)

    assert result is not None
    expected = base_ppm(2, 60, 0)
    assert result.predicted_price_per_sqm == pytest.approx(expected, rel=1e-3)
    assert result.r_squared > 0.99
    assert result.n_used == len(rng_seed_seq)


def test_fit_skips_rows_with_missing_fields():
    good_rows = [
        _comp(2, 60, 200_000),
        _comp(2, 65, 210_000),
        _comp(1, 40, 220_000),
        _comp(3, 80, 195_000),
        _comp(2, 55, 205_000),
        _comp(3, 90, 190_000),
        _comp(1, 45, 215_000),
        _comp(2, 70, 200_000),
    ]
    bad_rows = [
        Competitor(complex_name="X", snapshot_date=date(2026, 1, 1),
                   competitor_name="bad", price_per_sqm=200_000, source="t"),
        Competitor(complex_name="X", snapshot_date=date(2026, 1, 1),
                   competitor_name="bad", price_per_sqm=200_000,
                   area_sqm=60, source="t"),
    ]
    result = fit_and_predict(HedonicTarget(2, 60), good_rows + bad_rows)
    assert result is not None
    assert result.n_used == 8


def test_fit_ci_is_wider_than_point_prediction():
    comps = [
        _comp(1, 40, 220_000), _comp(1, 45, 215_000),
        _comp(2, 60, 200_000), _comp(2, 65, 195_000), _comp(2, 70, 190_000),
        _comp(3, 80, 185_000), _comp(3, 90, 180_000), _comp(3, 100, 175_000),
    ]
    result = fit_and_predict(HedonicTarget(2, 60), comps)
    assert result is not None
    assert result.ci_lo_95 < result.predicted_price_per_sqm < result.ci_hi_95


def test_to_dict_round_trips_keys():
    comps = [
        _comp(1, 40, 220_000), _comp(1, 45, 215_000),
        _comp(2, 60, 200_000), _comp(2, 65, 195_000), _comp(2, 70, 190_000),
        _comp(3, 80, 185_000), _comp(3, 90, 180_000), _comp(3, 100, 175_000),
    ]
    result = fit_and_predict(HedonicTarget(2, 60), comps)
    d = result.to_dict()
    assert set(d.keys()) >= {
        "predicted_price_per_sqm", "ci_lo_95", "ci_hi_95",
        "n_used", "r_squared", "residual_std",
        "feature_names", "coefficients",
    }
    # distance_km у всех компов = 0 → колонка отброшена; intercept/rooms/log_area
    assert d["feature_names"] == ["intercept", "rooms", "log_area"]
    assert len(d["coefficients"]) == 3


def test_apartment_type_to_rooms():
    from audit_engine.hedonic import apartment_type_to_rooms
    assert apartment_type_to_rooms("Studio") == 0
    assert apartment_type_to_rooms("студия") == 0
    assert apartment_type_to_rooms("1BR") == 1
    assert apartment_type_to_rooms("2BR") == 2
    assert apartment_type_to_rooms("3-комнатная") == 3
    assert apartment_type_to_rooms("") is None
    assert apartment_type_to_rooms(None) is None
    assert apartment_type_to_rooms("неведомое") is None


def test_fit_drops_zero_variance_distance_column():
    """Если у всех компов distance_m=0 — модель должна игнорировать distance,
    но всё равно оценить вклад rooms и area."""
    comps = [
        _comp(1, 40, 220_000), _comp(1, 45, 215_000),
        _comp(2, 60, 200_000), _comp(2, 65, 195_000), _comp(2, 70, 190_000),
        _comp(3, 80, 185_000), _comp(3, 90, 180_000), _comp(3, 100, 175_000),
    ]
    result = fit_and_predict(HedonicTarget(2, 60), comps)
    assert result is not None
    assert "distance_km" not in result.feature_names
    assert "rooms" in result.feature_names
    assert "log_area" in result.feature_names
