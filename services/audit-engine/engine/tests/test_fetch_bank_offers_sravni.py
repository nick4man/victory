"""Тесты для sravni-bank-плагина в scripts/fetch_bank_offers.

Покрывают чистые функции (без сети), включая edge cases маппинга
programCode → product_type и конвертацию months → years.
"""
from __future__ import annotations

import pathlib

import pytest

from scripts.fetch_bank_offers import (
    SRAVNI_PROGRAM_TO_TYPE,
    SRAVNI_SLUG_TO_NAME,
    _months_to_years,
    parse_sravni_html,
)


FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "sravni_gazprombank.html"


@pytest.mark.parametrize(
    "months,expected",
    [
        (12, 1),
        (228, 19),
        (360, 30),
        (None, None),
        (0, None),  # falsy
        ("abc", None),
    ],
)
def test_months_to_years(months, expected):
    assert _months_to_years(months) == expected


def test_sravni_slug_table_covers_top5():
    for slug in ("sberbank", "gazprombank", "vtb", "alfabank", "domrf"):
        assert slug in SRAVNI_SLUG_TO_NAME
        assert SRAVNI_SLUG_TO_NAME[slug]


def test_sravni_program_codes_mapped():
    """Должны быть в маппинге все ключевые программы."""
    for code in ("semejnaya", "it-ipoteka", "selskaya", "voennaya", "dalnevostochnaya"):
        assert code in SRAVNI_PROGRAM_TO_TYPE


def test_parse_sravni_html_gazprombank_4_offers():
    html = FIXTURE.read_text(encoding="utf-8")
    offers = parse_sravni_html(html, "gazprombank")
    assert len(offers) == 4
    assert {o.bank_name for o in offers} == {"Газпромбанк"}
    # Все стандартные mortgage без programCode
    types = {o.product_type for o in offers}
    assert types == {"mortgage"}
    # Ставки/суммы корректны
    for o in offers:
        assert o.rate_min and o.rate_min > 0
        assert o.source == "sravni.ru"
        assert o.term_years_max and o.term_years_max >= 1


def test_parse_sravni_html_empty_or_malformed():
    assert parse_sravni_html("", "gazprombank") == []
    assert parse_sravni_html("<html>nothing</html>", "gazprombank") == []
    bad = '<script id="__NEXT_DATA__">{not json</script>'
    assert parse_sravni_html(bad, "gazprombank") == []


def test_parse_sravni_html_unknown_slug_uses_slug_as_name():
    """Если slug нет в SRAVNI_SLUG_TO_NAME — используется slug как имя."""
    html = FIXTURE.read_text(encoding="utf-8")
    offers = parse_sravni_html(html, "unknown-bank")
    assert len(offers) == 4
    assert all(o.bank_name == "unknown-bank" for o in offers)
