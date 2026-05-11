"""APScheduler-обёртка для парсеров и периодических job-ов audit-engine-v2.

Запускается из `api/app.py` через `startup`/`shutdown` хуки.
Каждый job-объект:
- описан в `JOBS` (имя → cron-расписание + async-функция),
- пишет запись в `cron_runs` (started_at → finished_at, status, rows_affected, error),
- ловит любое исключение, чтобы планировщик не падал из-за одного парсера.

Время в `CronTrigger` указано в UTC. МСК = UTC+3 (без перехода).
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from sqlalchemy import text

from audit_engine.db import get_session

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class JobSpec:
    name: str
    trigger: CronTrigger
    runner: Callable[[], Awaitable[int]]
    description: str


# --- Job runners ---------------------------------------------------------


async def _run_fetch_macro_cbr() -> int:
    """Тянем ключевую ставку ЦБ. Возвращает число upsert-нутых записей."""
    import argparse

    from scripts.fetch_macro_cbr import _run as macro_run

    args = argparse.Namespace(dry_run=False, input=None)
    rc = await macro_run(args)
    return 1 if rc == 0 else 0


async def _run_fetch_inflation_cbr() -> int:
    """Месячная инфляция ЦБ. Один upsert или 0."""
    import argparse

    from scripts.fetch_inflation_cbr import _run as infl_run

    args = argparse.Namespace(dry_run=False, input=None)
    rc = await infl_run(args)
    return 1 if rc == 0 else 0


async def _run_fetch_bank_offers() -> int:
    """Парсим banki.ru + sravni + cbr-keyrate-derived. Возвращает число оферов."""
    import argparse

    from scripts.fetch_bank_offers import _run as bank_run

    total = 0
    for source in ("banki-ru", "sravni-bank", "cbr-keyrate-derived"):
        args = argparse.Namespace(
            dry_run=False, source=source, input=None, bank_slug="gazprombank"
        )
        try:
            rc = await bank_run(args)
            if rc == 0:
                total += 1
        except Exception as exc:
            logger.warning("fetch_bank_offers[%s] failed: %s", source, exc)
    return total


async def _run_competitor_refresh() -> int:
    """Обновляем competitors по всем ЖК из audit_inputs.

    Скрапер пока заглушка — реальные парсеры CIAN/Avito ставим в C2/C3.
    Job регистрируется уже сейчас, чтобы `cron_runs` начал собирать историю.
    """
    from audit_engine.jobs.competitor_refresh import list_complex_names_to_refresh

    async with get_session() as session:
        names = await list_complex_names_to_refresh(session)
    logger.info("competitor_refresh: %d complexes (scraper stub)", len(names))
    return 0


async def _run_cron_health_check() -> int:
    """Hourly health-check: ищет «больные» cron job-ы, эскалирует в TG.

    E4: вызывает `scripts.check_cron_health.run` — он сам пишет в
    `posts_queue`, откуда `content-publisher` отправит в TG (бот whitelist).
    """
    from scripts.check_cron_health import run as health_run

    unhealthy_count = await health_run(dry_run=False)
    return unhealthy_count


async def _run_backtest_monthly() -> int:
    """Back-test предыдущего месяца. Записывает в `backtest_runs`.

    E3 (Полу-v2.1): cron 5-го числа в 04:00 UTC (07:00 МСК) — после того
    как macro/bank_offers за месяц обновятся.
    """
    import argparse
    from datetime import date, timedelta

    from scripts.backtest import _run as backtest_run

    # Берём предыдущий полный месяц: 1-е → последний день.
    today = date.today()
    first_of_this_month = today.replace(day=1)
    last_of_prev_month = first_of_this_month - timedelta(days=1)
    first_of_prev_month = last_of_prev_month.replace(day=1)

    args = argparse.Namespace(
        month=None,
        input=None,
        since=first_of_prev_month.isoformat(),
        until=last_of_prev_month.isoformat(),
        output=None,
        dry_run=False,
        no_db=False,
    )
    rc = await backtest_run(args)
    # rc=3 значит MAPE>20% — это успех с warning, не failure
    return 1 if rc in (0, 3) else 0


# --- Job registry --------------------------------------------------------

# UTC расписания. МСК = UTC+3.
JOBS: tuple[JobSpec, ...] = (
    JobSpec(
        name="fetch_macro_cbr",
        trigger=CronTrigger(hour=3, minute=0, timezone="UTC"),  # 06:00 МСК
        runner=_run_fetch_macro_cbr,
        description="ЦБ key-rate (daily)",
    ),
    JobSpec(
        name="fetch_inflation_cbr",
        trigger=CronTrigger(day=1, hour=5, minute=0, timezone="UTC"),  # 08:00 МСК 1-го
        runner=_run_fetch_inflation_cbr,
        description="Инфляция YoY (monthly)",
    ),
    JobSpec(
        name="fetch_bank_offers",
        trigger=CronTrigger(day_of_week="mon,wed,fri", hour=4, minute=0, timezone="UTC"),
        runner=_run_fetch_bank_offers,
        description="Ипотечные ставки топ-банков (Mon/Wed/Fri)",
    ),
    JobSpec(
        name="competitor_refresh",
        trigger=CronTrigger(hour=0, minute=0, timezone="UTC"),  # 03:00 МСК
        runner=_run_competitor_refresh,
        description="Конкурентный анализ ЖК (daily)",
    ),
    JobSpec(
        name="backtest_monthly",
        trigger=CronTrigger(day=5, hour=4, minute=0, timezone="UTC"),  # 5-го 07:00 МСК
        runner=_run_backtest_monthly,
        description="Back-test точности прогнозов за прошлый месяц",
    ),
    JobSpec(
        name="cron_health_check",
        trigger=CronTrigger(minute=15, timezone="UTC"),  # каждый час в HH:15
        runner=_run_cron_health_check,
        description="Health-check cron-job-ов + alert в TG (hourly)",
    ),
)


# --- Cron-runs persistence -----------------------------------------------


async def _record_start(job_name: str) -> int:
    async with get_session() as session:
        result = await session.execute(
            text(
                "INSERT INTO cron_runs (job_name, status) "
                "VALUES (:job, 'running') RETURNING id"
            ),
            {"job": job_name},
        )
        return result.scalar()


async def _record_finish(
    run_id: int, status: str, rows_affected: int | None, error: str | None
) -> None:
    async with get_session() as session:
        await session.execute(
            text(
                "UPDATE cron_runs "
                "SET finished_at = now(), status = :st, "
                "rows_affected = :rows, error = :err "
                "WHERE id = :id"
            ),
            {"st": status, "rows": rows_affected, "err": error, "id": run_id},
        )


async def _execute_job(spec: JobSpec) -> None:
    """Оборачивает spec.runner записью в cron_runs."""
    run_id = await _record_start(spec.name)
    try:
        rows = await spec.runner()
        await _record_finish(run_id, "success", rows, None)
        logger.info("cron job %s OK (rows=%s)", spec.name, rows)
    except Exception as exc:
        logger.exception("cron job %s failed", spec.name)
        await _record_finish(run_id, "failed", None, str(exc)[:1000])


# --- Scheduler lifecycle -------------------------------------------------


_scheduler: AsyncIOScheduler | None = None


def get_scheduler() -> AsyncIOScheduler | None:
    return _scheduler


def start_scheduler() -> AsyncIOScheduler:
    """Запускает планировщик и регистрирует все JOBS."""
    global _scheduler
    if _scheduler is not None:
        return _scheduler

    if os.environ.get("AUDIT_SCHEDULER_DISABLED", "").lower() in ("1", "true", "yes"):
        logger.warning("AUDIT_SCHEDULER_DISABLED=1 → планировщик НЕ стартовал")
        return None  # type: ignore[return-value]

    scheduler = AsyncIOScheduler(timezone="UTC")
    for spec in JOBS:
        scheduler.add_job(
            _execute_job,
            trigger=spec.trigger,
            args=[spec],
            id=spec.name,
            name=spec.description,
            replace_existing=True,
            misfire_grace_time=3600,
            coalesce=True,
        )
    scheduler.start()
    _scheduler = scheduler
    logger.info("APScheduler started with %d jobs", len(JOBS))
    return scheduler


def shutdown_scheduler() -> None:
    global _scheduler
    if _scheduler is not None:
        _scheduler.shutdown(wait=False)
        _scheduler = None
        logger.info("APScheduler stopped")


# --- Public helper for manual trigger (tests/debug) ----------------------


async def run_job_now(job_name: str) -> dict[str, Any]:
    """Ручной запуск job-а по имени. Используется в тестах и из CLI."""
    spec = next((j for j in JOBS if j.name == job_name), None)
    if spec is None:
        return {"status": "not_found", "job_name": job_name}
    started = datetime.now(timezone.utc)
    await _execute_job(spec)
    return {
        "status": "executed",
        "job_name": job_name,
        "started_at": started.isoformat(),
    }
