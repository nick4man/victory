"""Ежедневное обновление таблицы `competitors` из CIAN/Avito.

Фаза E, cron-стаб. Фактический скрапинг делают
`data-collector/price_parsers/{cian,avito}_parser.py`; тут — только
координатор: какие ЖК обновляем (список тянем из audit_inputs), как
часто (1 раз в сутки), куда пишем (`store_competitor_snapshot`).

Интеграция со scheduler-ом (APScheduler/cron-контейнер) — следующий шаг.
Сейчас функцию можно звать вручную: `python -m audit_engine.jobs.competitor_refresh`.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import date

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.competitor_collector import store_competitor_snapshot
from audit_engine.models import Competitor

logger = logging.getLogger(__name__)


async def list_complex_names_to_refresh(db: AsyncSession) -> list[str]:
    """Уникальные имена ЖК из активных аудитов (флаги/архив — позже)."""
    sql = text(
        "SELECT DISTINCT complex_name FROM audit_inputs WHERE complex_name IS NOT NULL"
    )
    result = await db.execute(sql)
    return [r[0] for r in result.fetchall()]


async def refresh_for_complex(
    db: AsyncSession,
    complex_name: str,
    scraper,
) -> int:
    """Забрать компы одним scraper-ом и записать в БД. Возвращает число вставленных.

    `scraper` — callable `(complex_name) -> list[Competitor]`. Контракт
    позволяет подсунуть mock в тестах и реальный CIAN/Avito в проде.
    """
    try:
        competitors = await asyncio.to_thread(scraper, complex_name)
    except Exception as exc:
        logger.warning("scraper failed for %s: %s", complex_name, exc)
        return 0

    today = date.today()
    inserted = 0
    for comp in competitors:
        try:
            if comp.snapshot_date is None:
                comp.snapshot_date = today
            await store_competitor_snapshot(db, comp)
            inserted += 1
        except Exception as exc:
            logger.warning("store failed for %s: %s", comp.competitor_name, exc)
    return inserted


async def run(db: AsyncSession, scraper) -> dict[str, int]:
    """Полный цикл: список ЖК → scraper → insert. Возвращает отчёт."""
    names = await list_complex_names_to_refresh(db)
    report: dict[str, int] = {}
    for name in names:
        report[name] = await refresh_for_complex(db, name, scraper)
    logger.info("competitor refresh done: %s", report)
    return report
