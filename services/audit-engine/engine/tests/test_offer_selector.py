"""Unit-тесты для `offer_selector.is_eligible` и `effective_rate`."""
from __future__ import annotations

import os
import sys
from datetime import date

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.models import AuditInput, BankOffer, BankProductType
from audit_engine.offer_selector import (
    effective_rate,
    eligible_offers,
    is_eligible,
)


def _audit_input(**kwargs) -> AuditInput:
    defaults = dict(
        complex_name="ЖК Тест",
        apartment_type="2BR",
        area_sqm=60.0,
        price_total=10_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        mortgage_term_years=20,
        down_payment_pct=20.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
    )
    defaults.update(kwargs)
    return AuditInput(**defaults)


def _offer(**kwargs) -> BankOffer:
    defaults = dict(
        bank_name="Сбер",
        product_type=BankProductType.MORTGAGE,
        product_name="Ипотека",
        rate_min=18.0,
        rate_max=22.0,
        term_years_min=1,
        term_years_max=30,
        down_payment_min_pct=15.0,
        max_loan_amount=50_000_000,
        requirements={},
        valid_from=date(2026, 1, 1),
    )
    defaults.update(kwargs)
    return BankOffer(**defaults)


def test_eligibility_down_payment_filter():
    # клиент даёт 10%, оффер требует минимум 15% → мимо
    inp = _audit_input(down_payment_pct=10.0)
    offer = _offer(down_payment_min_pct=15.0)
    assert is_eligible(inp, offer) is False

    # клиент даёт 20%, требование 15% → ок
    inp2 = _audit_input(down_payment_pct=20.0)
    assert is_eligible(inp2, offer) is True


def test_eligibility_term_range_filter():
    inp = _audit_input(mortgage_term_years=5)
    offer = _offer(term_years_min=10, term_years_max=30)
    assert is_eligible(inp, offer) is False

    inp2 = _audit_input(mortgage_term_years=35)
    assert is_eligible(inp2, offer) is False

    inp3 = _audit_input(mortgage_term_years=20)
    assert is_eligible(inp3, offer) is True


def test_eligibility_loan_cap_filter():
    # price = 100M, down 20% → loan = 80M; cap 50M → мимо
    inp = _audit_input(price_total=100_000_000, down_payment_pct=20.0)
    offer = _offer(max_loan_amount=50_000_000)
    assert is_eligible(inp, offer) is False

    # cap 100M → ок
    offer2 = _offer(max_loan_amount=100_000_000)
    assert is_eligible(inp, offer2) is True


def test_special_products_filtered_out_without_flags():
    """Семейная ипотека с непустыми requirements должна отсекаться
    (у базового AuditInput нет флагов — это фаза C)."""
    inp = _audit_input()
    offer = _offer(
        product_type=BankProductType.FAMILY_MORTGAGE,
        requirements={"has_children_under_18": True},
    )
    assert is_eligible(inp, offer) is False

    # Тот же тип, но requirements пусты — оффер открыт всем
    open_offer = _offer(
        product_type=BankProductType.FAMILY_MORTGAGE,
        requirements={},
    )
    assert is_eligible(inp, open_offer) is True


def test_eligible_offers_filters_mixed_list():
    inp = _audit_input(down_payment_pct=20.0, mortgage_term_years=15)
    offers = [
        _offer(bank_name="A"),
        _offer(bank_name="B", down_payment_min_pct=30.0),  # фильтр по ПВ
        _offer(bank_name="C", term_years_min=20),  # фильтр по сроку
        _offer(bank_name="D"),
    ]
    result = eligible_offers(inp, offers)
    banks = {o.bank_name for o in result}
    assert banks == {"A", "D"}


def test_effective_rate_mid_range():
    # (18 + 22) / 2 = 20
    offer = _offer(rate_min=18.0, rate_max=22.0)
    assert effective_rate(offer) == 20.0


def test_effective_rate_falls_back_to_min_when_no_range():
    offer = _offer(rate_min=19.5, rate_max=None)
    assert effective_rate(offer) == 19.5

    # rate_max == rate_min → используем rate_min (или эквивалент)
    offer2 = _offer(rate_min=6.0, rate_max=6.0)
    assert effective_rate(offer2) == 6.0
