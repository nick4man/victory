"""C5 unit-тесты — оценка риск-индекса застройщика.

Сеть НЕ дёргаем — проверяем чистые функции классификации статуса,
подсчёта судов и расчёта multiplier-а. Интеграционный тест с реальным
fetch — отдельно (skipped по умолчанию).
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from audit_engine.parsers.developer_risk import (
    _calc_multiplier,
    _classify_status,
    _count_lawsuits,
    _extract_name,
)


# -----------------------------------------------------------------------
# _classify_status
# -----------------------------------------------------------------------

class TestClassifyStatus:
    def test_empty_html_returns_unknown(self):
        status, notes = _classify_status("")
        assert status == "unknown"
        assert "пустой" in notes.lower()

    def test_active_when_no_triggers(self):
        html = "<html><body>Обычная страница, действующая организация</body></html>"
        status, _ = _classify_status(html)
        assert status == "active"

    def test_bankruptcy_completed(self):
        html = "<html>Процедура банкротства завершена</html>"
        status, notes = _classify_status(html)
        assert status == "bankruptcy"
        assert "завершен" in notes

    def test_bankruptcy_liquidated(self):
        html = "<html>Организация ликвидирована 12 апреля</html>"
        status, _ = _classify_status(html)
        assert status == "liquidated"

    def test_bankruptcy_initiated_supervision(self):
        html = "<html>Введена процедура наблюдения по делу</html>"
        status, _ = _classify_status(html)
        assert status == "bankruptcy_initiated"

    def test_priority_liquidated_over_bankruptcy(self):
        # "ликвидирован" в STATUS_HINTS идёт первым → должно победить
        html = "<html>Конкурсное производство завершено, ликвидирован</html>"
        status, _ = _classify_status(html)
        assert status == "liquidated"


# -----------------------------------------------------------------------
# _count_lawsuits
# -----------------------------------------------------------------------

class TestCountLawsuits:
    def test_empty_returns_zero(self):
        assert _count_lawsuits("") == 0

    def test_no_cards_returns_zero(self):
        assert _count_lawsuits("<html>Просто текст</html>") == 0

    def test_publication_cards_counted(self):
        html = "publication-card" * 5
        assert _count_lawsuits(html) == 5

    def test_search_result_items_counted(self):
        html = "search-result-item " * 3 + "publication-card " * 2
        assert _count_lawsuits(html) == 5

    def test_cap_at_999(self):
        html = "publication-card " * 2000
        assert _count_lawsuits(html) == 999


# -----------------------------------------------------------------------
# _calc_multiplier
# -----------------------------------------------------------------------

class TestCalcMultiplier:
    def test_active_no_lawsuits(self):
        assert _calc_multiplier("active", 0) == 1.00

    def test_active_few_lawsuits(self):
        assert _calc_multiplier("active", 4) == 1.00

    def test_active_medium_lawsuits(self):
        assert _calc_multiplier("active", 5) == 0.95
        assert _calc_multiplier("active", 19) == 0.95

    def test_active_many_lawsuits(self):
        assert _calc_multiplier("active", 20) == 0.90
        assert _calc_multiplier("active", 100) == 0.90

    def test_bankruptcy_initiated(self):
        assert _calc_multiplier("bankruptcy_initiated", 0) == 0.90
        assert _calc_multiplier("bankruptcy_initiated", 100) == 0.90

    def test_bankruptcy_and_liquidated_strongest(self):
        assert _calc_multiplier("bankruptcy", 0) == 0.85
        assert _calc_multiplier("liquidated", 0) == 0.85

    def test_unknown_does_not_penalise(self):
        # Нет данных — не штрафуем
        assert _calc_multiplier("unknown", 0) == 1.00


# -----------------------------------------------------------------------
# _extract_name
# -----------------------------------------------------------------------

class TestExtractName:
    def test_returns_title_content(self):
        html = "<html><head><title>ООО Стройка Бетон — Поиск</title></head></html>"
        assert _extract_name(html, "1234567890") == "ООО Стройка Бетон — Поиск"

    def test_filters_out_fedresurs_brand(self):
        html = "<html><title>Fedresurs Search</title></html>"
        assert _extract_name(html, "1234567890") is None

    def test_no_title_returns_none(self):
        assert _extract_name("<html>nothing</html>", "1234567890") is None
