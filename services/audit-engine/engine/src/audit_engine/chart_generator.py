"""
Chart Generator — Генератор круговых диаграмм (Pie Charts) для PDF-отчётов.

Создаёт визуализации для каждого блока расчётов:
- Ипотека: структура затрат (тело кредита, проценты, упущенная выгода ПВ)
- Cash: структура затрат (цена со скидкой, скидка, упущенная выгода)
- Deposit: баланс позиции (капитал vs. будущая цена + аренда)
- Итоговая: сравнение EI по стратегиям (по реалистичному сценарию)

Каждая функция возвращает base64-encoded PNG для встраивания в HTML/PDF.
"""

from __future__ import annotations
import base64
import io
import matplotlib
matplotlib.use("Agg")  # Non-interactive backend
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm

from audit_engine.models import AuditResult, ScenarioResult


# ─── Brand Colours ──────────────────────────────────────────────
C_GREEN_DARK = "#006837"
C_GREEN_LIGHT = "#92C04E"
C_BLUE_LIGHT = "#A7D9ED"
C_GREY_LIGHT = "#E6E7E8"
C_ORANGE = "#F0AD4E"
C_RED = "#DC3545"
C_TEAL = "#20C997"
C_PURPLE = "#6F42C1"

# Palette for pie charts (brand-aligned)
PIE_COLORS_3 = [C_GREEN_DARK, C_GREEN_LIGHT, C_BLUE_LIGHT]
PIE_COLORS_4 = [C_GREEN_DARK, C_GREEN_LIGHT, C_BLUE_LIGHT, C_ORANGE]
PIE_COLORS_5 = [C_GREEN_DARK, C_GREEN_LIGHT, C_BLUE_LIGHT, C_ORANGE, C_RED]
PIE_COLORS_COMPARE = [C_GREEN_DARK, C_BLUE_LIGHT, C_ORANGE]

# Try to use a font that supports Cyrillic
_FONT_CANDIDATES = [
    "DejaVu Sans", "Noto Sans", "Liberation Sans",
    "FreeSans", "Arial", "Helvetica",
]
_CHART_FONT = "DejaVu Sans"
for _fc in _FONT_CANDIDATES:
    _found = fm.findfont(fm.FontProperties(family=_fc), fallback_to_default=False)
    if _found and "LastResort" not in _found:
        _CHART_FONT = _fc
        break

plt.rcParams["font.family"] = _CHART_FONT
plt.rcParams["font.size"] = 10


def _fmt_rub(value: float) -> str:
    """Format ruble amount for chart labels."""
    if abs(value) >= 1_000_000:
        return f"{value / 1_000_000:.1f} млн ₽"
    elif abs(value) >= 1_000:
        return f"{value / 1_000:.0f} тыс ₽"
    return f"{value:.0f} ₽"


def _fig_to_base64(fig: plt.Figure, dpi: int = 150) -> str:
    """Convert matplotlib figure to base64 PNG data URI."""
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=dpi, bbox_inches="tight",
                facecolor="white", edgecolor="none")
    plt.close(fig)
    buf.seek(0)
    b64 = base64.b64encode(buf.read()).decode()
    return f"data:image/png;base64,{b64}"


def _make_autopct(values: list[float]):
    """Create autopct function that shows both % and absolute values."""
    total = sum(values)
    def autopct(pct):
        val = pct / 100.0 * total
        return f"{pct:.1f}%\n({_fmt_rub(val)})"
    return autopct


# ════════════════════════════════════════════════════════════════
# Per-block charts for a SINGLE scenario
# ════════════════════════════════════════════════════════════════

def chart_mortgage_costs(scenario: ScenarioResult, title_suffix: str = "") -> str:
    """
    Pie chart: структура расходов по ипотеке.
    
    Сегменты: Тело кредита | Переплата (проценты) | Упущенная выгода ПВ
    """
    m = scenario.mortgage
    labels = [
        "Тело кредита",
        "Переплата\n(проценты)",
        "Упущенная выгода ПВ",
    ]
    values = [m.loan_amount, m.total_interest, m.opportunity_cost_dp]
    colors = [C_GREEN_DARK, C_RED, C_ORANGE]

    fig, ax = plt.subplots(figsize=(5, 4))
    wedges, texts, autotexts = ax.pie(
        values, labels=labels, colors=colors,
        autopct=_make_autopct(values),
        startangle=90, pctdistance=0.65,
        textprops={"fontsize": 9},
    )
    for at in autotexts:
        at.set_fontsize(8)
    
    title = f"Ипотека: структура затрат"
    if title_suffix:
        title += f"\n({title_suffix})"
    ax.set_title(title, fontsize=12, fontweight="bold", color=C_GREEN_DARK, pad=15)

    return _fig_to_base64(fig)


def chart_cash_breakdown(scenario: ScenarioResult, title_suffix: str = "") -> str:
    """
    Pie chart: структура расходов при покупке за наличные.
    
    Сегменты: Цена со скидкой | Скидка (экономия) | Упущенная выгода
    """
    c = scenario.cash
    labels = [
        "Цена со скидкой",
        "Скидка (экономия)",
        "Упущенная выгода",
    ]
    values = [c.price_with_discount, c.discount_amount, c.opportunity_cost]
    colors = [C_GREEN_DARK, C_GREEN_LIGHT, C_ORANGE]

    fig, ax = plt.subplots(figsize=(5, 4))
    wedges, texts, autotexts = ax.pie(
        values, labels=labels, colors=colors,
        autopct=_make_autopct(values),
        startangle=90, pctdistance=0.65,
        textprops={"fontsize": 9},
    )
    for at in autotexts:
        at.set_fontsize(8)

    title = f"Cash: структура затрат"
    if title_suffix:
        title += f"\n({title_suffix})"
    ax.set_title(title, fontsize=12, fontweight="bold", color=C_GREEN_DARK, pad=15)

    return _fig_to_base64(fig)


def chart_deposit_balance(scenario: ScenarioResult, title_suffix: str = "") -> str:
    """
    Pie chart: баланс позиции при стратегии «Депозит».
    
    Сегменты: Капитал на депозите vs (Будущая цена + Затраты на аренду)
    """
    d = scenario.deposit
    labels = [
        "Капитал на\nдепозите",
        "Будущая цена\nквартиры",
        "Затраты на\nаренду",
    ]
    values = [d.capital_after_horizon, d.projected_price, d.total_rent_cost]
    colors = [C_GREEN_LIGHT, C_RED, C_ORANGE]

    fig, ax = plt.subplots(figsize=(5, 4))
    wedges, texts, autotexts = ax.pie(
        values, labels=labels, colors=colors,
        autopct=_make_autopct(values),
        startangle=90, pctdistance=0.65,
        textprops={"fontsize": 9},
    )
    for at in autotexts:
        at.set_fontsize(8)

    title = f"Депозит: баланс позиции"
    if title_suffix:
        title += f"\n({title_suffix})"
    ax.set_title(title, fontsize=12, fontweight="bold", color=C_GREEN_DARK, pad=15)

    # Add net position annotation
    sign = "+" if d.net_position > 0 else ""
    net_text = f"Чистая позиция: {sign}{_fmt_rub(d.net_position)}"
    net_color = C_GREEN_DARK if d.net_position > 0 else C_RED
    ax.annotate(net_text, xy=(0, -1.3), fontsize=10, ha="center",
                fontweight="bold", color=net_color)

    return _fig_to_base64(fig)


# ════════════════════════════════════════════════════════════════
# Summary / comparison charts
# ════════════════════════════════════════════════════════════════

def chart_ei_comparison(result: AuditResult) -> str:
    """
    Bar chart: сравнение EI по 3 стратегиям × 3 сценария.
    
    Grouped bar chart showing EI for Mortgage, Cash, Deposit across scenarios.
    """
    import numpy as np

    scenario_names = [s.scenario_name for s in result.scenarios]
    ei_mortgage = [s.mortgage.ei for s in result.scenarios]
    ei_cash = [s.cash.ei for s in result.scenarios]
    ei_deposit = [s.deposit.ei for s in result.scenarios]

    x = np.arange(len(scenario_names))
    width = 0.25

    fig, ax = plt.subplots(figsize=(7, 4.5))
    bars1 = ax.bar(x - width, ei_mortgage, width, label="Ипотека",
                   color=C_GREEN_DARK, edgecolor="white", linewidth=0.5)
    bars2 = ax.bar(x, ei_cash, width, label="Cash",
                   color=C_BLUE_LIGHT, edgecolor="white", linewidth=0.5)
    bars3 = ax.bar(x + width, ei_deposit, width, label="Депозит",
                   color=C_ORANGE, edgecolor="white", linewidth=0.5)

    # Add value labels
    for bars in [bars1, bars2, bars3]:
        for bar in bars:
            h = bar.get_height()
            ax.annotate(f"{h:.2f}", xy=(bar.get_x() + bar.get_width() / 2, h),
                       xytext=(0, 4), textcoords="offset points",
                       ha="center", va="bottom", fontsize=8, fontweight="bold")

    # Threshold lines
    ax.axhline(y=1.2, color=C_GREEN_LIGHT, linestyle="--", linewidth=1, alpha=0.7,
               label="EI = 1.2 (покупка оправдана)")
    ax.axhline(y=0.8, color=C_RED, linestyle="--", linewidth=1, alpha=0.7,
               label="EI = 0.8 (невыгодно)")

    ax.set_xlabel("Сценарий", fontsize=10)
    ax.set_ylabel("EI (Индекс Целесообразности)", fontsize=10)
    ax.set_title("Сравнение EI по стратегиям и сценариям",
                fontsize=12, fontweight="bold", color=C_GREEN_DARK)
    ax.set_xticks(x)
    ax.set_xticklabels(scenario_names, fontsize=9)
    ax.legend(loc="upper left", fontsize=8, framealpha=0.9)
    ax.grid(axis="y", alpha=0.3)

    fig.tight_layout()
    return _fig_to_base64(fig)


def chart_strategy_pie(result: AuditResult) -> str:
    """
    Pie chart: доля «лучшей стратегии» по сценариям (итоговая диаграмма).
    
    Показывает, какая стратегия побеждает чаще всего.
    """
    from collections import Counter
    strategies = [s.best_strategy for s in result.scenarios]
    counts = Counter(strategies)
    
    labels = list(counts.keys())
    values = list(counts.values())
    
    color_map = {
        "Cash": C_GREEN_DARK,
        "Deposit": C_ORANGE,
        "Mortgage": C_BLUE_LIGHT,
    }
    colors = [color_map.get(l, C_GREY_LIGHT) for l in labels]

    fig, ax = plt.subplots(figsize=(5, 4))
    wedges, texts, autotexts = ax.pie(
        values, labels=labels, colors=colors,
        autopct="%1.0f%%", startangle=90,
        textprops={"fontsize": 10},
    )
    for at in autotexts:
        at.set_fontsize(11)
        at.set_fontweight("bold")

    ax.set_title("Лучшая стратегия\n(по результатам 3 сценариев)",
                fontsize=12, fontweight="bold", color=C_GREEN_DARK, pad=15)

    # Add verdict text
    verdict_text = {
        "BUY": "✅ Покупка оправдана",
        "WAIT": "❌ Рекомендуется ожидание",
        "NEUTRAL": "⚖️ Нейтрально",
    }
    vt = verdict_text.get(result.verdict.value, result.verdict.value)
    ax.annotate(f"Вердикт: {vt}", xy=(0, -1.3), fontsize=10,
                ha="center", fontweight="bold", color=C_GREEN_DARK)

    return _fig_to_base64(fig)


# ════════════════════════════════════════════════════════════════
# Retro-specific chart
# ════════════════════════════════════════════════════════════════

def chart_retro_wealth_comparison(
    wealth_ipoteka: float,
    wealth_arenda: float,
    label_ipoteka: str = "Ипотека (28%)",
    label_arenda: str = "Аренда + Депозит",
) -> str:
    """
    Bar chart: сравнение изменения богатства (ΔW) для ретроспективного аудита.
    """
    fig, ax = plt.subplots(figsize=(5, 4))
    
    labels = [label_ipoteka, label_arenda]
    values = [wealth_ipoteka, wealth_arenda]
    colors = [C_RED if wealth_ipoteka < 0 else C_GREEN_DARK,
              C_GREEN_DARK if wealth_arenda > 0 else C_RED]
    
    bars = ax.bar(labels, values, color=colors, edgecolor="white", linewidth=0.5, width=0.5)
    
    for bar, val in zip(bars, values):
        sign = "+" if val > 0 else ""
        ax.annotate(f"{sign}{_fmt_rub(val)}", xy=(bar.get_x() + bar.get_width() / 2, val),
                   xytext=(0, 8 if val >= 0 else -16),
                   textcoords="offset points",
                   ha="center", va="bottom" if val >= 0 else "top",
                   fontsize=10, fontweight="bold",
                   color=C_GREEN_DARK if val >= 0 else C_RED)
    
    ax.axhline(y=0, color="black", linewidth=0.5)
    ax.set_ylabel("Изменение богатства (₽)", fontsize=10)
    ax.set_title("Сравнение стратегий: dW за 6 месяцев",
                fontsize=12, fontweight="bold", color=C_GREEN_DARK)
    ax.grid(axis="y", alpha=0.3)
    
    fig.tight_layout()
    return _fig_to_base64(fig)


def chart_retro_rate_sensitivity(
    rates: list[float],
    ei_values: list[float],
    breakeven_rate: float | None = None,
) -> str:
    """
    Line chart: чувствительность EI к ипотечной ставке.
    """
    fig, ax = plt.subplots(figsize=(6, 4))
    
    # Color segments: green where EI < 0 (buy is better), red where EI > 0
    ax.plot(rates, ei_values, color=C_GREEN_DARK, linewidth=2, marker="o", markersize=4)
    ax.fill_between(rates, ei_values, 0,
                    where=[v <= 0 for v in ei_values],
                    alpha=0.15, color=C_GREEN_LIGHT, label="Покупка выгоднее")
    ax.fill_between(rates, ei_values, 0,
                    where=[v > 0 for v in ei_values],
                    alpha=0.15, color=C_RED, label="Аренда выгоднее")
    
    ax.axhline(y=0, color="black", linewidth=1)
    
    if breakeven_rate:
        ax.axvline(x=breakeven_rate, color=C_ORANGE, linestyle="--", linewidth=1.5)
        ax.annotate(f"Безубыточность\n{breakeven_rate}%",
                   xy=(breakeven_rate, 0), xytext=(15, 30),
                   textcoords="offset points",
                   fontsize=9, fontweight="bold", color=C_ORANGE,
                   arrowprops=dict(arrowstyle="->", color=C_ORANGE))
    
    ax.set_xlabel("Ставка ипотеки (%)", fontsize=10)
    ax.set_ylabel("EI (₽): + аренда лучше, − покупка лучше", fontsize=9)
    ax.set_title("Чувствительность к ипотечной ставке",
                fontsize=12, fontweight="bold", color=C_GREEN_DARK)
    ax.legend(fontsize=8, loc="upper left")
    ax.grid(alpha=0.3)
    
    fig.tight_layout()
    return _fig_to_base64(fig)


def chart_retro_subsidy_comparison(
    programs: list[dict],
) -> str:
    """
    Horizontal bar chart: сравнение программ ипотеки по EI.
    
    programs: list of {"name": str, "rate": float, "payment": float, "ei": float, "verdict": str}
    """
    fig, ax = plt.subplots(figsize=(6, max(3, len(programs) * 0.7 + 1)))
    
    names = [f"{p['name']} ({p['rate']}%)" for p in programs]
    ei_vals = [p["ei"] for p in programs]
    colors = [C_GREEN_DARK if p.get("verdict") == "✅" else C_RED for p in programs]
    
    bars = ax.barh(names, ei_vals, color=colors, edgecolor="white", height=0.5)
    
    for bar, val in zip(bars, ei_vals):
        sign = "+" if val > 0 else ""
        ax.annotate(f"{sign}{_fmt_rub(val)}",
                   xy=(val, bar.get_y() + bar.get_height() / 2),
                   xytext=(8 if val >= 0 else -8, 0),
                   textcoords="offset points",
                   ha="left" if val >= 0 else "right", va="center",
                   fontsize=9, fontweight="bold")
    
    ax.axvline(x=0, color="black", linewidth=0.5)
    ax.set_xlabel("EI (₽): − покупка выгоднее, + аренда выгоднее", fontsize=9)
    ax.set_title("Сравнение ипотечных программ",
                fontsize=12, fontweight="bold", color=C_GREEN_DARK)
    ax.grid(axis="x", alpha=0.3)
    
    fig.tight_layout()
    return _fig_to_base64(fig)


# ════════════════════════════════════════════════════════════════
# All-in-one generator
# ════════════════════════════════════════════════════════════════

def generate_all_charts(result: AuditResult) -> dict[str, str]:
    """
    Сгенерировать ВСЕ диаграммы для аудита.
    
    Returns:
        Dict mapping chart_id → base64 data URI.
        Keys:
        - mortgage_{scenario_name}
        - cash_{scenario_name}
        - deposit_{scenario_name}
        - ei_comparison (grouped bar)
        - strategy_pie (итоговая)
    """
    charts = {}
    
    for s in result.scenarios:
        suffix = s.scenario_name
        key_suffix = s.scenario_name.lower().replace(" ", "_")
        
        charts[f"mortgage_{key_suffix}"] = chart_mortgage_costs(s, suffix)
        charts[f"cash_{key_suffix}"] = chart_cash_breakdown(s, suffix)
        charts[f"deposit_{key_suffix}"] = chart_deposit_balance(s, suffix)
    
    charts["ei_comparison"] = chart_ei_comparison(result)
    charts["strategy_pie"] = chart_strategy_pie(result)
    
    return charts
