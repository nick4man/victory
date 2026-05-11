"""
EI Calculator — Ядро расчёта Индекса Целесообразности.

Формулы:
- EI_mortgage = (Прогнозная_Стоимость + Экономия_Аренды) / (Затраты_Ипотека + Упущенная_Выгода_ПВ)
- EI_cash = (Прогнозная_Стоимость + Экономия_Аренды) / (Цена_со_скидкой + Упущенная_Выгода_100%)
- EI_deposit = Капитал_через_N_лет / (Будущая_Цена + Затраты_Аренда)
"""

from __future__ import annotations
from audit_engine.models import (
    AuditInput,
    MortgageDetails,
    CashDetails,
    DepositDetails,
    Verdict,
)
from audit_engine.config import settings


def calculate_monthly_payment(
    principal: float, annual_rate: float, term_years: int
) -> float:
    """Аннуитетный ежемесячный платёж по ипотеке."""
    if annual_rate <= 0:
        return principal / (term_years * 12)
    monthly_rate = annual_rate / 100 / 12
    n_payments = term_years * 12
    payment = principal * (monthly_rate * (1 + monthly_rate) ** n_payments) / (
        (1 + monthly_rate) ** n_payments - 1
    )
    return round(payment, 2)


def calculate_mortgage_scenario(input_data: AuditInput) -> MortgageDetails:
    """Рассчитать ипотечный сценарий v2.0."""
    down_payment = input_data.price_total * (input_data.down_payment_pct / 100)
    loan_amount = input_data.price_total - down_payment

    monthly_payment = calculate_monthly_payment(
        loan_amount, input_data.mortgage_rate, input_data.mortgage_term_years
    )
    total_payments = monthly_payment * input_data.mortgage_term_years * 12
    total_interest = total_payments - loan_amount

    # v2.0: Сложные проценты с ежемесячной капитализацией (FV = PV * (1 + r/12)^n)
    monthly_deposit_rate = input_data.deposit_rate / 100 / 12
    n_months = input_data.horizon_years * 12
    fv_dp = down_payment * ((1 + monthly_deposit_rate) ** n_months)
    opportunity_cost_dp = fv_dp - down_payment

    # Прогнозная стоимость актива (также с капитализацией или по году - ГОСТ 2.0 использует годовой шаг)
    growth = input_data.price_growth_annual / 100
    projected_value = input_data.price_total * (1 + growth) ** input_data.horizon_years

    # Экономия на аренде
    rent_savings = input_data.monthly_rent * 12 * input_data.horizon_years

    # EI v2.0
    numerator = projected_value + rent_savings
    denominator = total_payments + opportunity_cost_dp
    ei = round(numerator / denominator, 4) if denominator > 0 else 0.0

    return MortgageDetails(
        down_payment=round(down_payment, 2),
        loan_amount=round(loan_amount, 2),
        monthly_payment=monthly_payment,
        total_payments=round(total_payments, 2),
        total_interest=round(total_interest, 2),
        opportunity_cost_dp=round(opportunity_cost_dp, 2),
        projected_asset_value=round(projected_value, 2),
        rent_savings=round(rent_savings, 2),
        ei=ei,
    )


def calculate_cash_scenario(input_data: AuditInput) -> CashDetails:
    """Рассчитать сценарий покупки за наличные v2.0."""
    discount = input_data.cash_discount_pct / 100
    price_with_discount = input_data.price_total * (1 - discount)
    discount_amount = input_data.price_total * discount

    # v2.0: Сложные проценты с капитализацией
    monthly_deposit_rate = input_data.deposit_rate / 100 / 12
    n_months = input_data.horizon_years * 12
    fv_full = input_data.price_total * ((1 + monthly_deposit_rate) ** n_months)
    opportunity_cost = fv_full - input_data.price_total

    # Прогнозная стоимость
    growth = input_data.price_growth_annual / 100
    projected_value = input_data.price_total * (1 + growth) ** input_data.horizon_years

    rent_savings = input_data.monthly_rent * 12 * input_data.horizon_years

    numerator = projected_value + rent_savings
    denominator = price_with_discount + opportunity_cost
    ei = round(numerator / denominator, 4) if denominator > 0 else 0.0

    return CashDetails(
        price_with_discount=round(price_with_discount, 2),
        discount_amount=round(discount_amount, 2),
        opportunity_cost=round(opportunity_cost, 2),
        projected_asset_value=round(projected_value, 2),
        rent_savings=round(rent_savings, 2),
        ei=ei,
    )


def calculate_deposit_scenario(input_data: AuditInput) -> DepositDetails:
    """Рассчитать сценарий 'депозит + ожидание' v2.0."""
    # v2.0: Ежемесячная капитализация
    monthly_deposit_rate = input_data.deposit_rate / 100 / 12
    n_months = input_data.horizon_years * 12
    capital_after = input_data.price_total * ((1 + monthly_deposit_rate) ** n_months)

    growth = input_data.price_growth_annual / 100
    projected_price = input_data.price_total * ((1 + growth) ** input_data.horizon_years)

    total_rent = input_data.monthly_rent * 12 * input_data.horizon_years

    # EI
    denominator = projected_price + total_rent
    ei = round(capital_after / denominator, 4) if denominator > 0 else 0.0

    net_position = capital_after - projected_price - total_rent

    return DepositDetails(
        capital_after_horizon=round(capital_after, 2),
        projected_price=round(projected_price, 2),
        total_rent_cost=round(total_rent, 2),
        net_position=round(net_position, 2),
        ei=ei,
    )


def determine_verdict(
    ei_cash: float, ei_deposit: float, ei_mortgage: float
) -> tuple[Verdict, str]:
    """Определить вердикт на основе EI реалистичного сценария."""
    best_ei = max(ei_cash, ei_deposit, ei_mortgage)
    best_strategy = "cash" if best_ei == ei_cash else (
        "deposit" if best_ei == ei_deposit else "mortgage"
    )

    # Если лучший — депозит с высоким EI, рекомендуем ждать
    if best_strategy == "deposit" and ei_deposit > settings.ei_buy_threshold:
        verdict = Verdict.WAIT
        explanation = (
            f"Депозитная стратегия (EI={ei_deposit:.2f}) значительно выгоднее покупки. "
            f"Рекомендуется ожидание."
        )
    elif best_ei > settings.ei_buy_threshold:
        verdict = Verdict.BUY
        explanation = (
            f"Стратегия '{best_strategy}' (EI={best_ei:.2f}) показывает высокую "
            f"целесообразность покупки."
        )
    elif best_ei < settings.ei_reject_threshold:
        verdict = Verdict.WAIT
        explanation = (
            f"Все стратегии имеют низкий EI (макс. {best_ei:.2f}). "
            f"Покупка нецелесообразна при текущих условиях."
        )
    else:
        verdict = Verdict.NEUTRAL
        explanation = (
            f"EI в нейтральной зоне (макс. {best_ei:.2f}). "
            f"Решение зависит от нефинансовых факторов."
        )

    return verdict, explanation


def identify_risks(input_data: AuditInput) -> list[str]:
    """Определить ключевые риски аудита."""
    risks = []

    if input_data.mortgage_rate > 15:
        risks.append(
            f"Высокая ипотечная ставка ({input_data.mortgage_rate}%) "
            f"существенно увеличивает переплату."
        )

    if input_data.price_growth_annual < 0:
        risks.append("Прогнозируется падение цен на недвижимость.")

    if input_data.price_growth_annual > 15:
        risks.append(
            "Прогноз роста цен агрессивный (>15% в год). Высокий риск завышения."
        )

    if input_data.deposit_rate > input_data.mortgage_rate:
        risks.append(
            "Ставка депозита выше ипотечной — аномальная ситуация, "
            "может измениться."
        )

    if input_data.horizon_years > 7:
        risks.append(
            f"Горизонт оценки {input_data.horizon_years} лет — "
            f"прогнозы теряют точность."
        )

    if input_data.down_payment_pct < 15:
        risks.append(
            "Низкий ПВ (<15%) может привести к повышенной ставке."
        )

    return risks


def list_assumptions(input_data: AuditInput) -> list[str]:
    """Список допущений аудита."""
    return [
        f"Рост цен = {input_data.price_growth_annual}% годовых (равномерно)",
        f"Ставка ипотеки фиксирована на весь срок ({input_data.mortgage_rate}%)",
        f"Ставка депозита стабильна ({input_data.deposit_rate}%)",
        f"Аренда не меняется ({input_data.monthly_rent} руб/мес)",
        f"Скидка за 100% оплату = {input_data.cash_discount_pct}%",
        "Инфляция учтена через прогноз роста цен, но не через корректировку потоков",
        f"Горизонт оценки: {input_data.horizon_years} лет",
    ]
