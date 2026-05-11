"""Рендерер Markdown-отчёта через Jinja2 + опциональный LLM-нарратив.

Заменяет inline-логику в `report_generator.generate_audit_report`. Сам файл
шаблона: `templates/audit_report.md.j2` (в корне проекта).

Использование:
    from audit_engine.services.report_renderer import render_audit_report

    md = await render_audit_report(
        result=audit_result,
        retro=retro_result,
        financial_context={"Ставка ЦБ": "14.5%"},
        monte_carlo=mc_summary_dict,
        narrative_enabled=True,
    )

Если `narrative_enabled=False` или OMNIROUTE_API_KEY не задан — LLM не
вызывается, шаблон рендерится только из числовых данных. Это позволяет
тестировать рендеринг без сети.
"""
from __future__ import annotations

from datetime import date
from pathlib import Path
from typing import Any

from jinja2 import Environment, FileSystemLoader, select_autoescape

from audit_engine.models import Verdict
from audit_engine.services.narrative_llm import generate_narrative

_PROJECT_ROOT = Path(__file__).resolve().parents[3]
_TEMPLATES_DIR = _PROJECT_ROOT / "templates"

_env = Environment(
    loader=FileSystemLoader(str(_TEMPLATES_DIR)),
    autoescape=select_autoescape(disabled_extensions=("md", "j2"), default=False),
    trim_blocks=False,
    lstrip_blocks=False,
    keep_trailing_newline=True,
)


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


_env.globals["verdict_emoji"] = _verdict_emoji
_env.globals["verdict_label"] = _verdict_label


_RU_MONTHS = {
    1: "января", 2: "февраля", 3: "марта", 4: "апреля",
    5: "мая", 6: "июня", 7: "июля", 8: "августа",
    9: "сентября", 10: "октября", 11: "ноября", 12: "декабря",
}


def _format_report_date(d: date | None = None) -> str:
    d = d or date.today()
    return f"{d.day} {_RU_MONTHS[d.month]} {d.year} г."


async def render_audit_report(
    result: Any,
    retro: Any | None = None,
    financial_context: dict[str, Any] | None = None,
    monte_carlo: dict[str, Any] | None = None,
    narrative_enabled: bool = True,
    template_name: str = "audit_report.md.j2",
) -> str:
    """Рендерим отчёт. Возвращаем Markdown-строку.

    Если `narrative_enabled=True` — async-вызовом дёргаем Omniroute и
    подмешиваем `summary` / `why_so` / `final_recommendation`. При ошибке —
    шаблон рендерится без этих секций.
    """
    narrative = await generate_narrative(result) if narrative_enabled else None

    template = _env.get_template(template_name)
    return template.render(
        result=result,
        retro=retro,
        financial_context=financial_context,
        monte_carlo=monte_carlo,
        narrative=narrative,
        report_date=_format_report_date(),
    )


def render_audit_report_sync(
    result: Any,
    retro: Any | None = None,
    financial_context: dict[str, Any] | None = None,
    monte_carlo: dict[str, Any] | None = None,
    narrative: dict[str, str] | None = None,
    template_name: str = "audit_report.md.j2",
) -> str:
    """Sync-вариант: вызывающий сам решает, делать LLM или нет.

    Удобно для тестов и для PDF-pipeline-а, где async-контекст не нужен.
    """
    template = _env.get_template(template_name)
    return template.render(
        result=result,
        retro=retro,
        financial_context=financial_context,
        monte_carlo=monte_carlo,
        narrative=narrative,
        report_date=_format_report_date(),
    )
