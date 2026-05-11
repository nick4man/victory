"""D1 smoke: Jinja2-рендерер аудит-отчёта.

Проверки:
1. Шаблон рендерится без LLM-нарратива (narrative=None).
2. Шаблон рендерится с LLM-нарративом (narrative={...}).
3. Один и тот же шаблон даёт РАЗНЫЙ выход для трёх ЖК (универсальность).
4. Структурно (заголовки, EI, ставки) — одинаково.
5. Monte-Carlo блок появляется, когда передан monte_carlo dict.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.models import (
    AuditResult,
    CashDetails,
    DepositDetails,
    MortgageDetails,
    ScenarioParams,
    ScenarioResult,
    Verdict,
)
from audit_engine.services.report_renderer import render_audit_report_sync


def _scenario(name: str, ei_cash: float, ei_mortgage: float, ei_deposit: float) -> ScenarioResult:
    return ScenarioResult(
        scenario_name=name,
        params=ScenarioParams(
            name=name,
            price_growth_annual=7.5,
            mortgage_rate=16.5,
            deposit_rate=14.0,
            inflation=8.5,
        ),
        mortgage=MortgageDetails(
            down_payment=2_400_000,
            loan_amount=9_600_000,
            monthly_payment=146_700,
            total_payments=17_604_000,
            total_interest=8_004_000,
            opportunity_cost_dp=1_400_000,
            projected_asset_value=17_200_000,
            rent_savings=2_700_000,
            ei=ei_mortgage,
        ),
        cash=CashDetails(
            price_with_discount=10_800_000,
            discount_amount=1_200_000,
            opportunity_cost=6_500_000,
            projected_asset_value=17_200_000,
            rent_savings=2_700_000,
            ei=ei_cash,
        ),
        deposit=DepositDetails(
            capital_after_horizon=23_000_000,
            projected_price=17_200_000,
            total_rent_cost=2_700_000,
            net_position=3_100_000,
            ei=ei_deposit,
        ),
        best_strategy="mortgage" if ei_mortgage >= max(ei_cash, ei_deposit) else "deposit",
    )


def _result(complex_name: str, area: float, price: float, verdict: Verdict) -> AuditResult:
    return AuditResult(
        complex_name=complex_name,
        apartment_type="2BR",
        area_sqm=area,
        price_total=price,
        price_per_sqm=price / area,
        audit_date="2026-05-10",
        scenarios=[
            _scenario("Оптимистичный", 1.25, 1.18, 0.98),
            _scenario("Реалистичный", 1.10, 1.05, 1.02),
            _scenario("Пессимистичный", 0.85, 0.78, 1.15),
        ],
        ei_cash=1.10,
        ei_deposit=1.02,
        ei_mortgage=1.05,
        sensitivity_table=[
            {"rate": r, "ei": 1.5 - (r - 10) * 0.08, "is_profitable": r < 15}
            for r in (10, 12, 14, 16, 18, 20)
        ],
        verdict=verdict,
        verdict_explanation=f"Для ЖК «{complex_name}» оптимальная стратегия — комбинированная.",
        risks=["Ставка ЦБ может вырасти", "Спрос может остыть"],
        assumptions=["Горизонт 5 лет", "Инфляция 8.5%"],
    )


def test_renders_without_narrative():
    r = _result("ЖК Тестовый Дом", 60, 12_000_000, Verdict.NEUTRAL)
    md = render_audit_report_sync(result=r)
    assert "ЖК Тестовый Дом" in md
    assert "Тестовый Дом" in md
    assert "60.0 м²" in md or "60 м²" in md
    assert "12 000 000" in md  # цена с пробелами как разделителями
    assert "ВЕРДИКТ" in md
    # narrative секций не должно быть
    assert "Почему так?" not in md
    assert "Итоговый вердикт" not in md


def test_renders_with_narrative():
    r = _result("ЖК Тестовый Дом", 60, 12_000_000, Verdict.BUY)
    narrative = {
        "summary": "Покупка оправдана — комбинированная стратегия.",
        "why_so": "Ставка ниже инфляции, рост цен превышает депозитную доходность.",
        "final_recommendation": "Брать ипотеку 70/30 и реинвестировать аренду.",
    }
    md = render_audit_report_sync(result=r, narrative=narrative)
    assert "Покупка оправдана — комбинированная стратегия." in md
    assert "Ставка ниже инфляции" in md
    assert "Брать ипотеку 70/30" in md


def test_three_complexes_produce_different_output():
    r1 = _result("ЖК 1-й Донской", 65, 14_500_000, Verdict.NEUTRAL)
    r2 = _result("ЖК Мостовая 5", 28, 6_800_000, Verdict.BUY)
    r3 = _result("ЖК Поляны Малосемейка", 22, 3_400_000, Verdict.WAIT)

    md1 = render_audit_report_sync(result=r1)
    md2 = render_audit_report_sync(result=r2)
    md3 = render_audit_report_sync(result=r3)

    # каждый имеет своё имя
    assert "ЖК 1-й Донской" in md1
    assert "ЖК Мостовая 5" in md2
    assert "ЖК Поляны Малосемейка" in md3

    # цена/площадь разные
    assert "14 500 000" in md1
    assert "6 800 000" in md2
    assert "3 400 000" in md3

    # вердикт разный
    assert "Покупка оправдана" in md2
    assert "Рекомендуется ожидание" in md3


def test_monte_carlo_section():
    r = _result("ЖК С MC", 60, 12_000_000, Verdict.BUY)
    mc = {
        "num_simulations": 1_000_000,
        "recommended_strategy": "mortgage",
        "confidence_level": "high",
        "cash":     {"ei_mean": 1.10, "ei_median": 1.08, "ei_p5": 0.85, "ei_p95": 1.35, "buy_probability": 0.62},
        "mortgage": {"ei_mean": 1.18, "ei_median": 1.16, "ei_p5": 0.92, "ei_p95": 1.44, "buy_probability": 0.71},
        "deposit":  {"ei_mean": 1.02, "ei_median": 1.00, "ei_p5": 0.78, "ei_p95": 1.26, "buy_probability": 0.45},
    }
    md = render_audit_report_sync(result=r, monte_carlo=mc)
    assert "Monte-Carlo" in md
    assert "1 000 000" in md
    assert "P(EI" in md
    assert "62%" in md or "71%" in md


def test_no_mc_no_mc_section():
    r = _result("ЖК без MC", 60, 12_000_000, Verdict.NEUTRAL)
    md = render_audit_report_sync(result=r, monte_carlo=None)
    assert "Monte-Carlo" not in md
