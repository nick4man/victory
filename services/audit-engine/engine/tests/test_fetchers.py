"""Pure-функции в fetch_macro_cbr и fetch_bank_offers — тесты без сети/БД."""
import json
import os
import sys
from datetime import date

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from scripts.fetch_macro_cbr import (
    MacroSnapshot,
    merge_snapshots,
    parse_daily_payload,
    parse_keyrate_payload,
)
from scripts.fetch_bank_offers import (
    OfferUpdate,
    derive_offers_from_keyrate,
    parse_manual_yaml,
)


# ---------- fetch_macro_cbr ----------


def test_parse_keyrate_picks_first_entry():
    payload = [{"date": "2026-04-01", "rate": 16.5}, {"date": "2026-03-01", "rate": 18.0}]
    assert parse_keyrate_payload(payload) == 16.5


def test_parse_keyrate_handles_string_rate():
    assert parse_keyrate_payload([{"rate": "21.0"}]) == 21.0


def test_parse_keyrate_returns_none_on_empty_or_invalid():
    assert parse_keyrate_payload([]) is None
    assert parse_keyrate_payload(None) is None  # type: ignore[arg-type]
    assert parse_keyrate_payload([{"foo": "bar"}]) is None


def test_parse_daily_finds_inflation_in_supported_keys():
    assert parse_daily_payload({"Inflation": 7.8}) == 7.8
    assert parse_daily_payload({"inflation": "8.4"}) == 8.4
    assert parse_daily_payload({"InflationAnnual": 6.0}) == 6.0


def test_parse_daily_returns_none_when_no_inflation_key():
    assert parse_daily_payload({"Valute": {"USD": {}}}) is None
    assert parse_daily_payload({}) is None
    assert parse_daily_payload(None) is None  # type: ignore[arg-type]


def test_merge_snapshots_combines_both_sources():
    snap = merge_snapshots(
        keyrate_payload=[{"rate": 17.0}],
        daily_payload={"Inflation": 8.5},
        snapshot_date=date(2026, 4, 24),
    )
    assert snap.cbr_key_rate == 17.0
    assert snap.inflation_annual == 8.5
    assert snap.date == date(2026, 4, 24)
    assert snap.source.startswith("cbr-xml-daily")


def test_merge_snapshots_handles_missing_inflation():
    snap = merge_snapshots([{"rate": 17.0}], None, date(2026, 1, 1))
    assert snap.cbr_key_rate == 17.0
    assert snap.inflation_annual is None


def test_macro_snapshot_to_db_payload_keys():
    snap = MacroSnapshot(date=date(2026, 1, 1), cbr_key_rate=17.0, inflation_annual=8.5)
    payload = snap.to_db_payload()
    assert set(payload.keys()) == {"date", "cbr_key_rate", "inflation_annual", "source"}


# ---------- fetch_bank_offers ----------


def test_derive_offers_emits_three_products():
    offers = derive_offers_from_keyrate(17.0, date(2026, 1, 1))
    assert len(offers) == 3
    names = {o.product_name for o in offers}
    assert any("Базовая" in n for n in names)
    assert any("Семейная" in n for n in names)
    assert any("IT" in n for n in names)


def test_derive_offers_base_rate_is_keyrate_plus_2pp():
    offers = derive_offers_from_keyrate(15.0, date.today())
    base = next(o for o in offers if "Базовая" in o.product_name)
    assert base.rate_min == 17.0
    assert base.rate_max == 21.0


def test_derive_offers_subsidized_floor_kicks_in_when_keyrate_low():
    """При очень низкой keyrate=10% субсидированные программы должны
    остановиться на floor (6% / 5%), а не уйти ниже."""
    offers = derive_offers_from_keyrate(10.0, date.today())
    family = next(o for o in offers if "Семейная" in o.product_name)
    it = next(o for o in offers if "IT" in o.product_name)
    assert family.rate_min == 6.0  # floor
    assert it.rate_min == 5.0  # floor


def test_derive_offers_subsidized_when_keyrate_high():
    """При keyrate=20% субсидированные = 13% (без зануления о floor)."""
    offers = derive_offers_from_keyrate(20.0, date.today())
    family = next(o for o in offers if "Семейная" in o.product_name)
    it = next(o for o in offers if "IT" in o.product_name)
    assert family.rate_min == 13.0
    assert it.rate_min == 13.0


def test_derive_offers_carry_source_metadata():
    offers = derive_offers_from_keyrate(16.0, date(2026, 6, 1))
    for o in offers:
        assert o.source == "cbr-keyrate-derived"
        assert o.bank_name == "Рынок (ориентир)"
        assert o.product_type == "MORTGAGE"
        assert o.valid_from == date(2026, 6, 1)
        assert "derived_from_keyrate" in o.requirements


def test_parse_manual_yaml_via_json_fallback():
    """Без yaml-зависимости парсер падает на json.loads."""
    raw = json.dumps(
        {
            "offers": [
                {
                    "bank_name": "Сбер",
                    "product_type": "MORTGAGE",
                    "product_name": "Тест",
                    "rate_min": 14.5,
                }
            ]
        }
    )
    offers = parse_manual_yaml(raw)
    assert len(offers) == 1
    assert offers[0].bank_name == "Сбер"
    assert offers[0].rate_min == 14.5
    assert offers[0].is_active is True  # default


def test_parse_manual_yaml_accepts_top_level_list():
    raw = json.dumps(
        [
            {
                "bank_name": "Тест",
                "product_type": "MORTGAGE",
                "product_name": "X",
                "rate_min": 10.0,
            }
        ]
    )
    offers = parse_manual_yaml(raw)
    assert len(offers) == 1


def test_parse_manual_yaml_empty_returns_empty_list():
    assert parse_manual_yaml("null") == []
    assert parse_manual_yaml("[]") == []


def test_offer_update_default_is_active_true():
    o = OfferUpdate(bank_name="X", product_type="Y", product_name="Z", rate_min=10.0)
    assert o.is_active is True
    assert o.valid_from == date.today()
