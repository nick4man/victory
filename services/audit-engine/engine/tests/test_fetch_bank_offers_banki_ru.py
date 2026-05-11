"""Тесты для banki.ru-плагина в scripts/fetch_bank_offers.

Покрывают чистые функции (без сети), включая edge cases классификации
и парсинг полей schema.org. Live-тест отдельно через --source banki-ru.
"""
from __future__ import annotations

import pathlib

import pytest

from scripts.fetch_bank_offers import (
    _classify_product_type,
    _parse_amount_max,
    _parse_term_years,
    parse_banki_ru_html,
)


FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "banki_ru_mortgage.html"


# ----------------------------- Pure helpers -----------------------------


@pytest.mark.parametrize(
    "name,expected",
    [
        ("Семейная ипотека", "family_mortgage"),
        ("Ипотека для семей с детьми", "family_mortgage"),
        ("IT-ипотека от ВТБ", "it_mortgage"),
        ("Ит-ипотека для специалистов", "it_mortgage"),
        ("Дальневосточная и арктическая ипотека", "far_east_mortgage"),
        ("Сельская ипотека", "rural_mortgage"),
        ("Военная ипотека", "military_mortgage"),
        ("Ипотека с господдержкой", "subsidized_mortgage"),
        ("Стандартная ипотека", "mortgage"),
        ("Готовый дом", "mortgage"),
    ],
)
def test_classify_product_type(name, expected):
    assert _classify_product_type(name) == expected


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("500 000–60 000 000 ₽", 60_000_000.0),
        ("100 000-12 000 000 руб", 12_000_000.0),
        ("1,5", 1.5),  # one-value fallback
        ("", None),
        ("не число", None),
    ],
)
def test_parse_amount_max(raw, expected):
    assert _parse_amount_max(raw) == expected


@pytest.mark.parametrize(
    "loan_term,expected",
    [
        ({"value": 10950, "unitCode": "DAY"}, (1, 30)),
        ({"value": 360, "unitCode": "MON"}, (1, 30)),
        ({"value": 30, "unitCode": "ANN"}, (1, 30)),
        ({}, (None, None)),
        ({"value": "abc", "unitCode": "DAY"}, (None, None)),
        ({"value": 365, "unitCode": "FOO"}, (None, None)),
    ],
)
def test_parse_term_years(loan_term, expected):
    assert _parse_term_years(loan_term) == expected


# ----------------------------- HTML parse -----------------------------


def test_parse_banki_ru_html_filters_target_banks_only():
    """Из 10 офферов фикстуры (3 банка-цели × 2 + 2 alien × 2) парсер
    должен отдать только целевые: ВТБ, Альфа-Банк, Банк ДОМ.РФ."""
    html = FIXTURE.read_text(encoding="utf-8")
    offers = parse_banki_ru_html(html)
    assert len(offers) == 6, f"expected 6 target offers, got {len(offers)}"

    banks = {o.bank_name for o in offers}
    assert banks == {"ВТБ", "Альфа-Банк", "Банк ДОМ.РФ"}

    # Alien banks (Совкомбанк, Т-Банк) НЕ должны попасть
    for o in offers:
        bn = o.bank_name.lower()
        assert "совкомбанк" not in bn
        assert "т-банк" not in bn


def test_parse_banki_ru_html_extracts_full_offer():
    """Конкретный оффер «Семейная ипотека» от ДОМ.РФ должен иметь
    rate_min=6.0, product_type=family_mortgage, max_loan_amount > 0."""
    html = FIXTURE.read_text(encoding="utf-8")
    offers = parse_banki_ru_html(html)
    family = [
        o
        for o in offers
        if o.bank_name == "Банк ДОМ.РФ" and "семейн" in o.product_name.lower()
    ]
    assert family, "семейная ипотека ДОМ.РФ не найдена"
    o = family[0]
    assert o.rate_min == pytest.approx(6.0)
    assert o.product_type == "family_mortgage"
    assert o.max_loan_amount and o.max_loan_amount > 0
    assert o.term_years_max and o.term_years_max >= 10
    assert o.source == "banki.ru"
    assert o.source_url.startswith("http")


def test_parse_banki_ru_html_empty_input():
    assert parse_banki_ru_html("") == []
    assert parse_banki_ru_html("<html>no jsonld here</html>") == []


def test_parse_banki_ru_html_malformed_jsonld():
    html = '<script type="application/ld+json">{not valid json</script>'
    assert parse_banki_ru_html(html) == []
