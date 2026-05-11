"""Тесты для полиморфного EI-диспатчера (Phase C)."""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest
from pydantic import TypeAdapter, ValidationError

from audit_engine.ei import calculate_ei
from audit_engine.models import (
    AuditInput,
    BusinessEIDetails,
    BusinessInput,
    HouseEIDetails,
    HouseInput,
    LandEIDetails,
    LandInput,
    PropertyInput,
    PropertyType,
)


# ----------- builders -----------------------------------------------------

def _apartment() -> AuditInput:
    return AuditInput(
        complex_name="ЖК Тест",
        apartment_type="2BR",
        area_sqm=60.0,
        price_total=10_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        deposit_rate=14.0,
        price_growth_annual=8.0,
        horizon_years=5,
    )


def _house(**overrides) -> HouseInput:
    defaults = dict(
        object_name="Коттедж",
        area_sqm=150.0,
        price_total=25_000_000,
        monthly_rent=90_000,
        land_area_sotka=15,
        land_price_per_sotka=300_000,
        land_growth_annual=5.0,
        annual_utilities_cost=240_000,
        mortgage_rate=17.0,
        deposit_rate=14.0,
        price_growth_annual=7.0,
        horizon_years=5,
    )
    defaults.update(overrides)
    return HouseInput(**defaults)


def _land(**overrides) -> LandInput:
    defaults = dict(
        object_name="77:01:0001:123",
        area_sotka=10,
        price_total=3_000_000,
        zoning="ИЖС",
        deposit_rate=14.0,
        price_growth_annual=10.0,
        horizon_years=5,
        annual_tax=15_000,
        annual_maintenance=5_000,
    )
    defaults.update(overrides)
    return LandInput(**defaults)


def _business(**overrides) -> BusinessInput:
    defaults = dict(
        object_name="Кофейня",
        price_total=5_000_000,
        annual_revenue=12_000_000,
        ebitda=1_800_000,
        revenue_growth_annual=8.0,
        discount_rate=22.0,
        terminal_growth=3.0,
        tax_rate=20.0,
        horizon_years=5,
    )
    defaults.update(overrides)
    return BusinessInput(**defaults)


# ----------- dispatcher ---------------------------------------------------

def test_dispatcher_routes_to_correct_calculator():
    ap = calculate_ei(_apartment())
    assert isinstance(ap, dict)
    assert ap["property_type"] == "APARTMENT"
    assert set(ap.keys()) >= {"mortgage", "cash", "deposit", "best_strategy", "ei"}

    h = calculate_ei(_house())
    assert isinstance(h, HouseEIDetails)

    l = calculate_ei(_land())
    assert isinstance(l, LandEIDetails)

    b = calculate_ei(_business())
    assert isinstance(b, BusinessEIDetails)


# ----------- LAND ---------------------------------------------------------

def test_land_ei_no_rent_section():
    """LAND результат не содержит rent/mortgage — только рост vs депозит."""
    result = calculate_ei(_land())
    assert result.projected_price > 3_000_000  # рост 10% за 5 лет
    assert result.opportunity_cost_deposit > 0
    assert result.total_tax_and_maintenance == (15_000 + 5_000) * 5


def test_land_ei_vs_deposit_higher_growth_gives_higher_ei():
    """Чем выше рост земли, тем выше EI (при прочих равных)."""
    low = calculate_ei(_land(price_growth_annual=3.0))
    high = calculate_ei(_land(price_growth_annual=15.0))
    assert high.ei > low.ei


def test_land_ei_flips_below_one_when_deposit_dominates():
    """Если рост земли < депозитной ставки, EI должен быть < 1 (депозит выгоднее)."""
    result = calculate_ei(_land(price_growth_annual=2.0, deposit_rate=18.0))
    assert result.ei < 1.0


# ----------- BUSINESS -----------------------------------------------------

def test_business_dcf_monotone_in_revenue_growth():
    """Чем выше ожидаемый рост выручки, тем выше fair_value (и EI)."""
    low = calculate_ei(_business(revenue_growth_annual=2.0))
    high = calculate_ei(_business(revenue_growth_annual=15.0))
    assert high.ei > low.ei
    assert high.fair_value_dcf > low.fair_value_dcf


def test_business_fcf_list_matches_horizon():
    result = calculate_ei(_business(horizon_years=7))
    assert len(result.fcf_per_year) == 7
    # FCF монотонно растёт (при положительном revenue_growth)
    assert result.fcf_per_year == sorted(result.fcf_per_year)


def test_business_ei_below_one_when_overpriced():
    """Цена в 10x от ebitda — дорого."""
    # При ebitda=1.8M и discount=22%, fair_value ~ 9-10M.
    # Просим за 50M → EI должен быть <1.
    result = calculate_ei(_business(price_total=50_000_000))
    assert result.ei < 1.0


def test_business_handles_rate_close_to_terminal_growth():
    """r ≤ g_term не должно крашить DCF — используется multiple fallback."""
    result = calculate_ei(
        _business(discount_rate=4.0, terminal_growth=5.0, multiple_ebitda=6.0)
    )
    assert result.ei > 0
    assert result.fair_value_dcf > 0


# ----------- HOUSE --------------------------------------------------------

def test_house_adds_land_and_subtracts_utilities():
    """HouseEIDetails содержит земельную компоненту и утилиты."""
    result = calculate_ei(_house())
    assert result.land_projected_value > 15 * 300_000  # выросла
    assert result.total_utilities_cost == 240_000 * 5


def test_house_vs_apartment_same_base_differs_by_land_and_utilities():
    """HOUSE с нулевой землёй и нулевыми утилитами ≈ APARTMENT."""
    h = _house(
        land_area_sotka=0,
        land_price_per_sotka=0,
        annual_utilities_cost=0,
        area_sqm=60,
        price_total=10_000_000,
        monthly_rent=45_000,
        price_growth_annual=8.0,
    )
    h_result = calculate_ei(h)
    ap_result = calculate_ei(_apartment())
    # EI лучшей стратегии должен совпадать с точностью до округления
    assert abs(h_result.mortgage.ei - ap_result["mortgage"].ei) < 0.001


# ----------- discriminated union ------------------------------------------

def test_discriminator_parses_each_property_type():
    adapter = TypeAdapter(PropertyInput)

    ap_raw = {
        "property_type": "APARTMENT",
        "complex_name": "X",
        "apartment_type": "2BR",
        "area_sqm": 60.0,
        "price_total": 10_000_000,
        "monthly_rent": 45_000,
        "mortgage_rate": 17.0,
        "deposit_rate": 14.0,
        "price_growth_annual": 8.0,
    }
    parsed = adapter.validate_python(ap_raw)
    assert isinstance(parsed, AuditInput)

    land_raw = {
        "property_type": "LAND",
        "object_name": "Участок",
        "area_sotka": 10,
        "price_total": 3_000_000,
        "deposit_rate": 14.0,
        "price_growth_annual": 10.0,
    }
    parsed = adapter.validate_python(land_raw)
    assert isinstance(parsed, LandInput)

    biz_raw = {
        "property_type": "BUSINESS",
        "object_name": "Кофейня",
        "price_total": 5_000_000,
        "annual_revenue": 12_000_000,
        "ebitda": 1_800_000,
    }
    parsed = adapter.validate_python(biz_raw)
    assert isinstance(parsed, BusinessInput)


def test_discriminator_rejects_unknown_type():
    adapter = TypeAdapter(PropertyInput)
    with pytest.raises(ValidationError):
        adapter.validate_python({"property_type": "SPACESHIP", "price_total": 1})


def test_apartment_input_default_property_type_is_apartment():
    """Back-compat: AuditInput без явного property_type остаётся APARTMENT."""
    inp = _apartment()
    assert inp.property_type == PropertyType.APARTMENT
