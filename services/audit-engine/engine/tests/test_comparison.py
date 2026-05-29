"""D3 unit-тесты — comparison сервиса.

Юнит:
1. _best_strategy выбирает максимальный EI и его стратегию.
2. rank_by_best_ei сортирует по убыванию best_ei.
3. winning_audit возвращает row с максимальным EI.
4. Шаблон comparison.md.j2 рендерится без ошибок и содержит ключевые секции.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from datetime import date
from pathlib import Path

import pytest
from jinja2 import Environment, FileSystemLoader

from audit_engine.services.comparison import (
    ComparisonRow,
    _best_strategy,
    _coerce_risks,
    rank_by_best_ei,
    winning_audit,
)


def _row(
    audit_id: str,
    ei_cash: float,
    ei_mortgage: float,
    ei_deposit: float,
    *,
    address: str | None = None,
    price: float = 10_000_000,
    area: float = 50.0,
    verdict: str = "BUY",
) -> ComparisonRow:
    best_name, best_val = _best_strategy(ei_cash, ei_mortgage, ei_deposit)
    return ComparisonRow(
        audit_id=audit_id,
        object_address=address or f"ЖК Тест {audit_id[:4]}",
        apartment_type="2BR",
        area_sqm=area,
        audit_date="2026-05-10",
        price_total=price,
        price_per_sqm=price / area if area else None,
        ei_cash=ei_cash,
        ei_mortgage=ei_mortgage,
        ei_deposit=ei_deposit,
        best_strategy=best_name,
        best_ei=round(best_val, 4),
        verdict=verdict,
        monte_carlo_buy_prob=70.0,
        monte_carlo_mean_ei=1.15,
        property_type="APARTMENT",
        risks_count=2,
    )


# -----------------------------------------------------------------------
# _best_strategy
# -----------------------------------------------------------------------

def test_best_strategy_picks_mortgage():
    name, val = _best_strategy(0.9, 1.3, 1.1)
    assert name == "mortgage"
    assert val == 1.3


def test_best_strategy_picks_cash():
    name, val = _best_strategy(1.5, 1.2, 1.0)
    assert name == "cash"
    assert val == 1.5


def test_best_strategy_picks_deposit():
    name, val = _best_strategy(0.7, 0.8, 1.2)
    assert name == "deposit"


def test_best_strategy_handles_none():
    name, val = _best_strategy(None, None, None)
    assert val == 0.0


# -----------------------------------------------------------------------
# rank_by_best_ei
# -----------------------------------------------------------------------

def test_rank_descending():
    rows = [
        _row("aaaa", 0.8, 0.9, 1.0),  # best=1.0
        _row("bbbb", 1.3, 1.0, 0.9),  # best=1.3
        _row("cccc", 1.1, 1.2, 1.1),  # best=1.2
    ]
    ranked = rank_by_best_ei(rows)
    assert [r.audit_id for r in ranked] == ["bbbb", "cccc", "aaaa"]


# -----------------------------------------------------------------------
# winning_audit
# -----------------------------------------------------------------------

def test_winning_audit_finds_max():
    rows = [
        _row("aaaa", 1.0, 1.0, 1.0),
        _row("bbbb", 1.5, 1.4, 1.3),
        _row("cccc", 1.1, 1.2, 1.1),
    ]
    w = winning_audit(rows)
    assert w is not None
    assert w.audit_id == "bbbb"


def test_winning_audit_empty():
    assert winning_audit([]) is None


# -----------------------------------------------------------------------
# _coerce_risks
# -----------------------------------------------------------------------

def test_coerce_risks_from_list():
    assert _coerce_risks(["a", "b"]) == 2


def test_coerce_risks_from_json_string():
    assert _coerce_risks('["a", "b", "c"]') == 3


def test_coerce_risks_from_none():
    assert _coerce_risks(None) == 0


def test_coerce_risks_from_garbage():
    assert _coerce_risks("not-json") == 0


# -----------------------------------------------------------------------
# Template rendering
# -----------------------------------------------------------------------

def test_template_renders_three_complexes():
    templates_dir = Path(__file__).resolve().parents[1] / "templates"
    env = Environment(loader=FileSystemLoader(str(templates_dir)))
    tpl = env.get_template("comparison.md.j2")

    rows = [
        _row("11111111-1111-1111-1111-111111111111", 1.3, 1.5, 1.0, address="ЖК Альфа", price=12_000_000),
        _row("22222222-2222-2222-2222-222222222222", 1.1, 0.9, 1.0, address="ЖК Бета", price=9_000_000),
        _row("33333333-3333-3333-3333-333333333333", 0.9, 0.8, 1.1, address="ЖК Гамма", price=15_000_000),
    ]
    ranked = rank_by_best_ei(rows)
    winner = winning_audit(rows)

    md = tpl.render(rows=ranked, winner=winner, report_date="2026-05-11")
    assert "СРАВНЕНИЕ АУДИТОВ (3 объекта)" in md
    assert "ЖК Альфа" in md
    assert "ЖК Бета" in md
    assert "ЖК Гамма" in md
    assert "🏆" in md  # winner section
    assert "Победитель" in md
    # Дельта между лучшим (1.5) и худшим (1.1) = 0.40
    assert "0.40" in md or "0.4" in md


def test_template_renders_two_complexes():
    templates_dir = Path(__file__).resolve().parents[1] / "templates"
    env = Environment(loader=FileSystemLoader(str(templates_dir)))
    tpl = env.get_template("comparison.md.j2")

    rows = [
        _row("aaaa1111-1111-1111-1111-111111111111", 1.3, 1.2, 1.0),
        _row("bbbb2222-2222-2222-2222-222222222222", 1.0, 1.1, 1.0),
    ]
    md = tpl.render(rows=rank_by_best_ei(rows), winner=winning_audit(rows), report_date="2026-05-11")
    assert "СРАВНЕНИЕ АУДИТОВ (2 объекта)" in md
