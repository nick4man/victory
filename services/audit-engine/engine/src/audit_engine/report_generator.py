"""
Report Generator — Генератор Markdown-отчётов.

Собирает AuditResult и RetroResult в финальный Markdown-документ.
Также генерирует HTML с диаграммами для вставки в PDF.
"""

from __future__ import annotations
from audit_engine.models import AuditResult, RetroResult, Verdict


def _verdict_emoji(verdict: Verdict) -> str:
    return {
        Verdict.BUY: "✅",
        Verdict.WAIT: "❌",
        Verdict.NEUTRAL: "⚖️",
    }.get(verdict, "❓")


def _verdict_label(verdict: Verdict) -> str:
    return {
        Verdict.BUY: "Покупка оправдана",
        Verdict.WAIT: "Рекомендуется ожидание",
        Verdict.NEUTRAL: "Нейтрально — зависит от нефинансовых факторов",
    }.get(verdict, "Неопределённо")


def generate_audit_report(
    result: AuditResult,
    retro: RetroResult | None = None,
    financial_context: dict | None = None,
) -> str:
    """
    Сгенерировать полный Markdown-отчёт.
    
    Args:
        result: Результат аудита (матрица 3×3).
        retro: Результат ретроспективного анализа (опционально).
        financial_context: Контекст финансовой сетки (опционально).
    
    Returns:
        Markdown-строка с финальным отчётом.
    """
    lines = []

    # Header
    lines.append(f"# АУДИТ ЖК «{result.complex_name}»")
    lines.append(f"## Дата: {result.audit_date}")
    lines.append("")

    # Executive Summary
    emoji = _verdict_emoji(result.verdict)
    label = _verdict_label(result.verdict)
    lines.append(f"### {emoji} ВЕРДИКТ: {label}")
    lines.append(f"> {result.verdict_explanation}")
    lines.append("")

    # 1. Property Card
    lines.append("---")
    lines.append("### 1. Карточка объекта")
    lines.append(f"- **ЖК:** {result.complex_name}")
    lines.append(f"- **Тип:** {result.apartment_type}")
    lines.append(f"- **Площадь:** {result.area_sqm} м²")
    lines.append(f"- **Цена:** {result.price_total:,.0f} руб.")
    lines.append(f"- **Цена за м²:** {result.price_per_sqm:,.0f} руб.")
    lines.append("")

    # 2. Financial Context
    if financial_context:
        lines.append("### 2. Финансовая сетка")
        for key, value in financial_context.items():
            lines.append(f"- **{key}:** {value}")
        lines.append("")

    # 3. EI Matrix
    lines.append("### 3. Индекс Целесообразности (матрица 3×3)")
    lines.append("")
    lines.append("| Сценарий | Cash EI | Deposit EI | Mortgage EI | Лучшая стратегия |")
    lines.append("|----------|---------|------------|-------------|-----------------|")
    for s in result.scenarios:
        lines.append(
            f"| {s.scenario_name} | {s.cash.ei:.2f} | {s.deposit.ei:.2f} | "
            f"{s.mortgage.ei:.2f} | {s.best_strategy} |"
        )
    lines.append("")

    # Detail for each scenario
    for s in result.scenarios:
        lines.append(f"#### {s.scenario_name} сценарий")
        lines.append(f"- Рост цен: {s.params.price_growth_annual:.1f}% / год")
        lines.append(f"- Ставка ипотеки: {s.params.mortgage_rate:.1f}%")
        lines.append(f"- Ставка депозита: {s.params.deposit_rate:.1f}%")
        lines.append(f"- Инфляция: {s.params.inflation:.1f}%")
        lines.append("")

        # Mortgage details
        lines.append(f"  **Ипотека:** ПВ {s.mortgage.down_payment:,.0f} руб, "
                     f"платёж {s.mortgage.monthly_payment:,.0f} руб/мес, "
                     f"переплата {s.mortgage.total_interest:,.0f} руб, "
                     f"EI = **{s.mortgage.ei:.2f}**")
        
        # Cash details
        lines.append(f"  **Cash:** Цена со скидкой {s.cash.price_with_discount:,.0f} руб, "
                     f"упущенная выгода {s.cash.opportunity_cost:,.0f} руб, "
                     f"EI = **{s.cash.ei:.2f}**")
        
        # Deposit details
        lines.append(f"  **Deposit:** Капитал через N лет {s.deposit.capital_after_horizon:,.0f} руб, "
                     f"будущая цена {s.deposit.projected_price:,.0f} руб, "
                     f"EI = **{s.deposit.ei:.2f}**")
        lines.append("")

    # 4. Sensitivity
    lines.append("### 4. Таблица чувствительности (Ипотека)")
    lines.append("Как меняется целесообразность в зависимости от ставки:")
    lines.append("")
    lines.append("| Ставка (%) | EI | Статус |")
    lines.append("|------------|----|--------|")
    # Show subset to keep it readable in Markdown summary
    for row in result.sensitivity_table[::2]: # Every 2%
        status = "✅ Выгодно" if row["is_profitable"] else "❌ Невыгодно"
        lines.append(f"| {row['rate']}% | {row['ei']:.2f} | {status} |")
    lines.append("")

    # 5. Retro
    if retro and retro.snapshots:
        lines.append("### 4. Ретроспектива")
        lines.append("")
        lines.append("| Дата | Цена за м² | Дельта (%) | EI тогда |")
        lines.append("|------|-----------|-----------|---------|")
        for d in retro.delta_analysis:
            lines.append(
                f"| {d.purchase_date} | {d.purchase_price/result.area_sqm:,.0f} руб | "
                f"{'+' if d.delta_pct > 0 else ''}{d.delta_pct}% | {d.ei_at_that_time:.2f} |"
            )
        lines.append("")
        if retro.developer_accuracy_pct is not None:
            lines.append(
                f"**Точность прогнозов застройщика:** {retro.developer_accuracy_pct:.1f}%"
            )
            lines.append("")

    # 5. Risks
    lines.append("### 5. Риски")
    if result.risks:
        for r in result.risks:
            lines.append(f"- ⚠️ {r}")
    else:
        lines.append("- Существенных рисков не выявлено.")
    lines.append("")

    # 6. Assumptions
    lines.append("### 6. Допущения")
    for a in result.assumptions:
        lines.append(f"- {a}")
    lines.append("")

    # Footer
    lines.append("---")
    from datetime import date
    months_ru = {1:"января",2:"февраля",3:"марта",4:"апреля",
                5:"мая",6:"июня",7:"июля",8:"августа",
                9:"сентября",10:"октября",11:"ноября",12:"декабря"}
    d = date.today()
    date_str = f"{d.day} {months_ru[d.month]} {d.year} г."
    lines.append(f"*Отчёт сформирован агентством недвижимости «Виктори» · {date_str}*")
    lines.append("")
    lines.append("*Примечание: Все расчёты носят информационный характер и не являются инвестиционной рекомендацией.*")

    return "\n".join(lines)


def generate_charts_html(result: AuditResult) -> str:
    """
    Сгенерировать HTML-блок с диаграммами для вставки в PDF.
    
    Генерирует диаграммы для каждого блока (Ипотека, Cash, Депозит)
    по каждому сценарию и итоговую диаграмму сравнения EI.
    
    Returns:
        HTML-строка с диаграммами для pdf_branded.
    """
    from audit_engine.chart_generator import generate_all_charts
    
    charts = generate_all_charts(result)
    
    html_parts = []
    html_parts.append('<div style="page-break-before: always;"></div>')
    html_parts.append('<h2 style="color: #006837; border-bottom: 2.5px solid #92C04E; padding-bottom: 4px;">')
    html_parts.append('ВИЗУАЛИЗАЦИЯ РАСЧЁТОВ</h2>')
    
    for s in result.scenarios:
        key = s.scenario_name.lower().replace(" ", "_")
        html_parts.append(f'<h3>{s.scenario_name} сценарий</h3>')
        html_parts.append('<div class="chart-row">')
        html_parts.append(f'<img class="chart-img" src="{charts[f"mortgage_{key}"]}" alt="Ипотека"/>')
        html_parts.append(f'<img class="chart-img" src="{charts[f"cash_{key}"]}" alt="Cash"/>')
        html_parts.append('</div>')
        html_parts.append('<div class="chart-full">')
        html_parts.append(f'<img class="chart-img" src="{charts[f"deposit_{key}"]}" alt="Депозит"/>')
        html_parts.append('</div>')
    
    html_parts.append('<div style="page-break-before: always;"></div>')
    html_parts.append('<h3>Итоговое сравнение</h3>')
    html_parts.append('<div class="chart-full">')
    html_parts.append(f'<img class="chart-img" src="{charts["ei_comparison"]}" alt="EI Comparison"/>')
    html_parts.append('</div>')
    html_parts.append('<div class="chart-full">')
    html_parts.append(f'<img class="chart-img" src="{charts["strategy_pie"]}" alt="Strategy"/>')
    html_parts.append('</div>')
    
    return "\n".join(html_parts)
