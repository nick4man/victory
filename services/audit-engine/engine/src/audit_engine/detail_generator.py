"""
Detail Report Generator — Генератор детализированных технических отчётов.

Формирует «Пояснительную записку к расчётам» — полную математическую
детализацию ПО КАЖДОМУ блоку аудита:
- Ипотека (аннуитет, проценты, тело, упущенная выгода ПВ)
- Cash (скидка, упущенная выгода 100%, прогнозная стоимость)
- Deposit (капитализация, будущая цена, аренда, чистая позиция)
- Сценарии (оптимистичный, реалистичный, пессимистичный)
- Ретроспектива (если есть)
"""

from __future__ import annotations
from datetime import date
from audit_engine.models import (
    AuditInput,
    AuditResult,
    RetroResult,
    ScenarioResult,
    MortgageDetails,
    CashDetails,
    DepositDetails,
)


def _fmt(value: float) -> str:
    """Format number with thousands separator and ₽ sign."""
    return f"{value:,.0f} ₽".replace(",", " ")


def _fmt_plain(value: float) -> str:
    """Format number with thousands separator, no currency."""
    return f"{value:,.0f}".replace(",", " ")


def _pct(value: float) -> str:
    """Format percentage."""
    return f"{value:.1f}%"


def _generate_mortgage_detail(scenario: ScenarioResult, input_data: AuditInput) -> list[str]:
    """Детализация ипотечного блока для одного сценария."""
    m = scenario.mortgage
    p = scenario.params
    lines = []

    lines.append(f"#### 🏦 Ипотека ({scenario.scenario_name} сценарий)")
    lines.append("")
    lines.append("**Исходные данные:**")
    lines.append(f"- Цена квартиры: **{_fmt(input_data.price_total)}**")
    lines.append(f"- Первоначальный взнос ({_pct(input_data.down_payment_pct)}): **{_fmt(m.down_payment)}**")
    lines.append(f"- Тело кредита: {_fmt(input_data.price_total)} − {_fmt(m.down_payment)} = **{_fmt(m.loan_amount)}**")
    lines.append(f"- Ставка ипотеки: **{_pct(p.mortgage_rate)}** годовых")
    lines.append(f"- Срок: {input_data.mortgage_term_years} лет ({input_data.mortgage_term_years * 12} мес.)")
    lines.append("")

    # Формула аннуитета
    monthly_rate = p.mortgage_rate / 100 / 12
    n_payments = input_data.mortgage_term_years * 12
    lines.append("**Формула аннуитета:** PMT = P × r × (1+r)ⁿ / ((1+r)ⁿ − 1)")
    lines.append("")
    lines.append(f"- P = {_fmt(m.loan_amount)}")
    lines.append(f"- r = {_pct(p.mortgage_rate)} / 12 = **{monthly_rate:.5f}**")
    lines.append(f"- n = {n_payments}")
    power = (1 + monthly_rate) ** n_payments
    lines.append(f"- (1 + r)ⁿ = {power:.3f}")
    numerator = m.loan_amount * monthly_rate * power
    denominator = power - 1
    lines.append(f"- **PMT = {_fmt(m.monthly_payment)}/мес**")
    lines.append("")

    # Итого выплат
    lines.append("**Итого за весь срок:**")
    lines.append(f"- Всего выплат: {_fmt(m.monthly_payment)} × {n_payments} = **{_fmt(m.total_payments)}**")
    lines.append(f"- Переплата (проценты): {_fmt(m.total_payments)} − {_fmt(m.loan_amount)} = **{_fmt(m.total_interest)}**")
    lines.append("")

    # Упущенная выгода ПВ
    deposit_rate = p.deposit_rate / 100
    fv_dp = m.down_payment * ((1 + deposit_rate) ** input_data.horizon_years)
    lines.append("**Упущенная выгода ПВ (если бы ПВ лежал на депозите):**")
    lines.append(f"- FV = {_fmt(m.down_payment)} × (1 + {_pct(p.deposit_rate)})^{input_data.horizon_years} = {_fmt(fv_dp)}")
    lines.append(f"- Упущенная выгода = {_fmt(fv_dp)} − {_fmt(m.down_payment)} = **{_fmt(m.opportunity_cost_dp)}**")
    lines.append("")

    # Прогнозная стоимость
    growth = p.price_growth_annual / 100
    lines.append("**Прогнозная стоимость актива:**")
    lines.append(f"- FV = {_fmt(input_data.price_total)} × (1 + {_pct(p.price_growth_annual)})^{input_data.horizon_years} = **{_fmt(m.projected_asset_value)}**")
    lines.append("")

    # Экономия на аренде
    lines.append("**Экономия на аренде (не платим аренду, живём в своём):**")
    lines.append(f"- {_fmt(input_data.monthly_rent)}/мес × 12 × {input_data.horizon_years} лет = **{_fmt(m.rent_savings)}**")
    lines.append("")

    # EI
    num = m.projected_asset_value + m.rent_savings
    den = m.total_payments + m.opportunity_cost_dp
    lines.append("**Расчёт EI (ипотека):**")
    lines.append(f"> EI = (Прогнозная стоимость + Экономия аренды) / (Выплаты + Упущенная выгода ПВ)")
    lines.append(f"> EI = ({_fmt(m.projected_asset_value)} + {_fmt(m.rent_savings)}) / ({_fmt(m.total_payments)} + {_fmt(m.opportunity_cost_dp)})")
    lines.append(f"> EI = {_fmt(num)} / {_fmt(den)} = **{m.ei:.4f}**")
    lines.append("")

    return lines


def _generate_cash_detail(scenario: ScenarioResult, input_data: AuditInput) -> list[str]:
    """Детализация блока Cash для одного сценария."""
    c = scenario.cash
    p = scenario.params
    lines = []

    lines.append(f"#### 💵 Покупка за наличные ({scenario.scenario_name} сценарий)")
    lines.append("")
    lines.append("**Скидка за 100% оплату:**")
    lines.append(f"- Базовая цена: {_fmt(input_data.price_total)}")
    lines.append(f"- Скидка: {_pct(input_data.cash_discount_pct)} = **{_fmt(c.discount_amount)}**")
    lines.append(f"- Цена со скидкой: {_fmt(input_data.price_total)} − {_fmt(c.discount_amount)} = **{_fmt(c.price_with_discount)}**")
    lines.append("")

    # Упущенная выгода
    deposit_rate = p.deposit_rate / 100
    fv_full = input_data.price_total * ((1 + deposit_rate) ** input_data.horizon_years)
    lines.append("**Упущенная выгода (вся сумма могла лежать на депозите):**")
    lines.append(f"- FV = {_fmt(input_data.price_total)} × (1 + {_pct(p.deposit_rate)})^{input_data.horizon_years} = {_fmt(fv_full)}")
    lines.append(f"- Упущенная выгода = {_fmt(fv_full)} − {_fmt(input_data.price_total)} = **{_fmt(c.opportunity_cost)}**")
    lines.append("")

    # Прогнозная стоимость
    lines.append("**Прогнозная стоимость актива:**")
    lines.append(f"- FV = {_fmt(input_data.price_total)} × (1 + {_pct(p.price_growth_annual)})^{input_data.horizon_years} = **{_fmt(c.projected_asset_value)}**")
    lines.append("")

    # Экономия на аренде
    lines.append("**Экономия на аренде:**")
    lines.append(f"- {_fmt(input_data.monthly_rent)}/мес × 12 × {input_data.horizon_years} лет = **{_fmt(c.rent_savings)}**")
    lines.append("")

    # EI
    num = c.projected_asset_value + c.rent_savings
    den = c.price_with_discount + c.opportunity_cost
    lines.append("**Расчёт EI (Cash):**")
    lines.append(f"> EI = (Прогнозная стоимость + Экономия аренды) / (Цена со скидкой + Упущенная выгода)")
    lines.append(f"> EI = ({_fmt(c.projected_asset_value)} + {_fmt(c.rent_savings)}) / ({_fmt(c.price_with_discount)} + {_fmt(c.opportunity_cost)})")
    lines.append(f"> EI = {_fmt(num)} / {_fmt(den)} = **{c.ei:.4f}**")
    lines.append("")

    return lines


def _generate_deposit_detail(scenario: ScenarioResult, input_data: AuditInput) -> list[str]:
    """Детализация блока Deposit для одного сценария."""
    d = scenario.deposit
    p = scenario.params
    lines = []

    lines.append(f"#### 🏦 Депозит + Ожидание ({scenario.scenario_name} сценарий)")
    lines.append("")

    # Капитал на депозите
    deposit_rate = p.deposit_rate / 100
    lines.append("**Капитал на депозите через N лет:**")
    lines.append(f"- PV = {_fmt(input_data.price_total)} (вся сумма на депозите)")
    lines.append(f"- Ставка: {_pct(p.deposit_rate)} годовых")
    lines.append(f"- FV = {_fmt(input_data.price_total)} × (1 + {_pct(p.deposit_rate)})^{input_data.horizon_years} = **{_fmt(d.capital_after_horizon)}**")
    lines.append("")

    # Будущая цена квартиры
    lines.append("**Прогнозная цена квартиры через N лет:**")
    lines.append(f"- FV = {_fmt(input_data.price_total)} × (1 + {_pct(p.price_growth_annual)})^{input_data.horizon_years} = **{_fmt(d.projected_price)}**")
    lines.append("")

    # Затраты на аренду
    lines.append("**Затраты на аренду за весь период:**")
    lines.append(f"- {_fmt(input_data.monthly_rent)}/мес × 12 × {input_data.horizon_years} лет = **{_fmt(d.total_rent_cost)}**")
    lines.append("")

    # Чистая позиция
    lines.append("**Чистая позиция:**")
    lines.append(f"> Капитал − Будущая цена − Аренда = {_fmt(d.capital_after_horizon)} − {_fmt(d.projected_price)} − {_fmt(d.total_rent_cost)}")
    lines.append(f"> = **{_fmt(d.net_position)}**")
    sign = "+" if d.net_position > 0 else ""
    lines.append(f"> {'Покупатель может позволить себе квартиру и остаться в плюсе' if d.net_position > 0 else 'Накоплений не хватит на покупку + покрытие аренды'}")
    lines.append("")

    # EI
    den = d.projected_price + d.total_rent_cost
    lines.append("**Расчёт EI (Deposit):**")
    lines.append(f"> EI = Капитал / (Будущая цена + Затраты на аренду)")
    lines.append(f"> EI = {_fmt(d.capital_after_horizon)} / ({_fmt(d.projected_price)} + {_fmt(d.total_rent_cost)})")
    lines.append(f"> EI = {_fmt(d.capital_after_horizon)} / {_fmt(den)} = **{d.ei:.4f}**")
    lines.append("")

    return lines


def _generate_retro_detail(retro: RetroResult, input_data: AuditInput) -> list[str]:
    """Детализация ретроспективного анализа."""
    lines = []
    lines.append("---")
    lines.append("## 🔄 Блок: Ретроспективный анализ")
    lines.append("")
    lines.append("Пересчёт EI для каждого исторического среза: «Что было бы, если бы купили тогда?»")
    lines.append("")

    if retro.snapshots:
        lines.append("**Исторические цены:**")
        lines.append("")
        lines.append("| Дата | Цена за м² | Полная цена | Источник |")
        lines.append("|------|-----------|------------|---------|")
        for snap in retro.snapshots:
            total = snap.price_per_sqm * input_data.area_sqm
            lines.append(f"| {snap.date} | {_fmt(snap.price_per_sqm)}/м² | {_fmt(total)} | {snap.source or 'н/д'} |")
        lines.append("")

    if retro.delta_analysis:
        lines.append("**Дельта-анализ (изменение стоимости):**")
        lines.append("")
        lines.append("| Дата покупки | Цена тогда | Стоимость сейчас | Дельта | EI тогда |")
        lines.append("|-------------|-----------|-----------------|--------|---------|")
        for d in retro.delta_analysis:
            sign = "+" if d.delta_pct > 0 else ""
            lines.append(f"| {d.purchase_date} | {_fmt(d.purchase_price)} | {_fmt(d.current_value)} | {sign}{d.delta_pct}% ({_fmt(d.delta_absolute)}) | {d.ei_at_that_time:.2f} |")
        lines.append("")

    if retro.ei_history:
        lines.append("**История EI по стратегиям:**")
        lines.append("")
        lines.append("| Дата | EI Mortgage | EI Cash | EI Deposit |")
        lines.append("|------|-----------|---------|-----------|")
        for eh in retro.ei_history:
            ei_m = eh.get("ei_mortgage", 0)
            ei_c = eh.get("ei_cash", 0)
            ei_d = eh.get("ei_deposit", 0)
            lines.append(f"| {eh['date']} | {ei_m:.4f} | {ei_c:.4f} | {ei_d:.4f} |")
        lines.append("")

    if retro.developer_accuracy_pct is not None:
        lines.append(f"**Точность прогнозов застройщика:** {retro.developer_accuracy_pct:.1f}%")
        lines.append("")

    return lines


def generate_detail_report(
    input_data: AuditInput,
    result: AuditResult,
    retro: RetroResult | None = None,
    financial_context: dict | None = None,
) -> str:
    """
    Сгенерировать полный детализированный Markdown-отчёт.
    
    Раскрывает математику ПО КАЖДОМУ блоку расчётов:
    - Ипотека, Cash, Deposit — для каждого из 3 сценариев.
    - Ретроспектива (если есть).
    - Формулы, промежуточные расчёты, проверки.
    
    Args:
        input_data: Входные параметры аудита.
        result: Результат аудита (матрица 3×3).
        retro: Результат ретроспективного анализа (опционально).
        financial_context: Контекст финансовой сетки (опционально).
    
    Returns:
        Markdown-строка с детализированным отчётом.
    """
    lines = []

    # Header
    lines.append(f"## 📐 ПОЯСНИТЕЛЬНАЯ ЗАПИСКА К РАСЧЁТАМ")
    lines.append("")
    lines.append(f"**ЖК «{result.complex_name}» · {result.apartment_type} · {result.area_sqm} м²**")
    lines.append("")
    lines.append("Полная математическая детализация всех блоков аудита.")
    lines.append("")

    # ═══ Блок 1: Исходные параметры ═══
    lines.append("---")
    lines.append("## 🔑 Блок 1. Исходные параметры")
    lines.append("")
    lines.append("| Параметр | Значение | Примечание |")
    lines.append("|----------|---------|-----------|")
    lines.append(f"| Цена квартиры | **{_fmt(input_data.price_total)}** | Прайс |")
    lines.append(f"| Площадь | {input_data.area_sqm} м² | Карточка объекта |")
    lines.append(f"| Цена за м² | **{_fmt(result.price_per_sqm)}/м²** | {_fmt(input_data.price_total)} / {input_data.area_sqm} |")
    lines.append(f"| Первоначальный взнос | {_pct(input_data.down_payment_pct)} | Стандарт |")
    lines.append(f"| Ставка ипотеки (база) | **{_pct(input_data.mortgage_rate)}** | Реалистичный сценарий |")
    lines.append(f"| Ставка депозита | **{_pct(input_data.deposit_rate)}** | ТОП-10 банков |")
    lines.append(f"| Прогноз роста цен | {_pct(input_data.price_growth_annual)}/год | Реалистичный сценарий |")
    lines.append(f"| Аренда аналога | **{_fmt(input_data.monthly_rent)}/мес** | Рыночная оценка |")
    lines.append(f"| Срок ипотеки | {input_data.mortgage_term_years} лет ({input_data.mortgage_term_years * 12} мес.) | Стандарт |")
    lines.append(f"| Горизонт анализа | **{input_data.horizon_years} лет** | |")
    lines.append(f"| Скидка за 100% оплату | {_pct(input_data.cash_discount_pct)} | |")
    lines.append("")

    if financial_context:
        lines.append("### Финансовый контекст")
        lines.append("")
        for key, value in financial_context.items():
            lines.append(f"- **{key}:** {value}")
        lines.append("")

    # ═══ Блок 2: Формулы (справочно) ═══
    lines.append("---")
    lines.append("## 📖 Блок 2. Формулы (справочно)")
    lines.append("")
    lines.append("**EI (Ипотека)** = (Прогнозная стоимость + Экономия аренды) / (Выплаты + Упущенная выгода ПВ)")
    lines.append("")
    lines.append("**EI (Cash)** = (Прогнозная стоимость + Экономия аренды) / (Цена со скидкой + Упущенная выгода 100%)")
    lines.append("")
    lines.append("**EI (Deposit)** = Капитал через N лет / (Будущая цена + Затраты на аренду)")
    lines.append("")
    lines.append("**Аннуитет:** PMT = P × r × (1+r)ⁿ / ((1+r)ⁿ − 1)")
    lines.append("")
    lines.append("> EI > 1.2 → Покупка оправдана · EI < 0.8 → Рекомендуется ожидание · 0.8–1.2 → Нейтральная зона")
    lines.append("")

    # ═══ Блок 3+: Детализация по каждому сценарию ═══
    for i, scenario in enumerate(result.scenarios, start=3):
        lines.append("---")
        lines.append(f"## 📊 Блок {i}. {scenario.scenario_name} сценарий")
        lines.append("")
        lines.append(f"**Параметры сценария:**")
        lines.append(f"- Рост цен: **{_pct(scenario.params.price_growth_annual)}**/год")
        lines.append(f"- Ставка ипотеки: **{_pct(scenario.params.mortgage_rate)}**")
        lines.append(f"- Ставка депозита: **{_pct(scenario.params.deposit_rate)}**")
        lines.append(f"- Инфляция: **{_pct(scenario.params.inflation)}**")
        lines.append(f"- Лучшая стратегия: **{scenario.best_strategy}**")
        lines.append("")

        # Mortgage detail
        lines.extend(_generate_mortgage_detail(scenario, input_data))

        # Cash detail
        lines.extend(_generate_cash_detail(scenario, input_data))

        # Deposit detail
        lines.extend(_generate_deposit_detail(scenario, input_data))

        # Summary table for this scenario
        lines.append(f"#### ⚖️ Сводная таблица EI ({scenario.scenario_name})")
        lines.append("")
        lines.append("| Стратегия | EI | Интерпретация |")
        lines.append("|-----------|-----|-------------|")
        for name, ei in [("Ипотека", scenario.mortgage.ei), ("Cash", scenario.cash.ei), ("Deposit", scenario.deposit.ei)]:
            if ei >= 1.2:
                interp = "✅ Покупка оправдана"
            elif ei < 0.8:
                interp = "❌ Рекомендуется ожидание"
            else:
                interp = "⚖️ Нейтральная зона"
            lines.append(f"| {name} | **{ei:.4f}** | {interp} |")
        lines.append("")

    # ═══ Ретроспектива ═══
    if retro and retro.snapshots:
        retro_block = len(result.scenarios) + 3
        lines.extend(_generate_retro_detail(retro, input_data))

    # ═══ Итоговая матрица 3×3 ═══
    lines.append("---")
    lines.append("## 📋 Итоговая матрица EI (3 сценария × 3 стратегии)")
    lines.append("")
    lines.append("| Сценарий | EI Mortgage | EI Cash | EI Deposit | Лучшая стратегия |")
    lines.append("|----------|-----------|---------|-----------|-----------------|")
    for s in result.scenarios:
        lines.append(f"| {s.scenario_name} | **{s.mortgage.ei:.4f}** | **{s.cash.ei:.4f}** | **{s.deposit.ei:.4f}** | {s.best_strategy} |")
    lines.append("")

    # ═══ Вердикт ═══
    lines.append("---")
    lines.append("## 🎯 Вердикт")
    lines.append("")
    lines.append(f"**{result.verdict.value}** — {result.verdict_explanation}")
    lines.append("")

    # ═══ Риски ═══
    if result.risks:
        lines.append("### ⚠️ Риски")
        for r in result.risks:
            lines.append(f"- {r}")
        lines.append("")

    # ═══ Допущения ═══
    lines.append("### 📌 Допущения модели")
    for a in result.assumptions:
        lines.append(f"- {a}")
    lines.append("")

    # Footer
    lines.append("---")
    months_ru = {1: "января", 2: "февраля", 3: "марта", 4: "апреля",
                 5: "мая", 6: "июня", 7: "июля", 8: "августа",
                 9: "сентября", 10: "октября", 11: "ноября", 12: "декабря"}
    d = date.today()
    date_str = f"{d.day} {months_ru[d.month]} {d.year} г."
    lines.append(f"*Детализация сформирована агентством недвижимости «Виктори» · {date_str}*")
    lines.append("")
    lines.append("*Примечание: Все расчёты носят информационный характер и не являются инвестиционной рекомендацией.*")

    return "\n".join(lines)
