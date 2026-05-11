"""E4 — Health-check планировщика, эскалация сбоев в Telegram через `posts_queue`.

Логика:
1. Для каждого job-а из `audit_engine.jobs.scheduler.JOBS` смотрим в `cron_runs`:
   - последний успешный запуск (status='success')
   - последний по времени запуск (любой статус)
2. Job считаем «больным», если:
   - последний run — failed (любой), ИЛИ
   - last success age > expected_interval × 2 (тишина дольше двойного интервала).
3. Если хотя бы один job болен — пишем запись в `posts_queue`
   (status='ALERT', requester='audit-watchdog'), которую штатный
   `content-publisher` обработает по своему whitelist-у.

Запуск:
    python -m scripts.check_cron_health          # online
    python -m scripts.check_cron_health --dry-run  # без записи

Зарегистрирован в scheduler как `check_cron_health` (hourly).
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import text

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")
logger = logging.getLogger(__name__)


# Ожидаемые интервалы между запусками (в часах). Если success-а нет дольше
# `interval × 2` — это alert.
EXPECTED_INTERVAL_HOURS: dict[str, int] = {
    "fetch_macro_cbr": 24,
    "fetch_inflation_cbr": 24 * 32,        # раз в месяц + слаг
    "fetch_bank_offers": 48,               # Mon/Wed/Fri ≈ 2 дня
    "competitor_refresh": 24,
    "backtest_monthly": 24 * 32,
}


async def collect_unhealthy_jobs() -> list[dict[str, Any]]:
    """Возвращает список «больных» job-ов с описанием проблемы."""
    from audit_engine.db import get_session
    from audit_engine.jobs.scheduler import JOBS

    unhealthy: list[dict[str, Any]] = []
    now = datetime.now(timezone.utc)

    async with get_session() as session:
        for spec in JOBS:
            # Last success
            r = await session.execute(
                text(
                    "SELECT finished_at FROM cron_runs "
                    "WHERE job_name = :name AND status = 'success' "
                    "ORDER BY started_at DESC LIMIT 1"
                ),
                {"name": spec.name},
            )
            last_success = r.scalar()

            # Last run (any status)
            r = await session.execute(
                text(
                    "SELECT status, error, started_at FROM cron_runs "
                    "WHERE job_name = :name "
                    "ORDER BY started_at DESC LIMIT 1"
                ),
                {"name": spec.name},
            )
            row = r.first()

            interval_h = EXPECTED_INTERVAL_HOURS.get(spec.name, 24)

            if row is None:
                # Никогда не запускался — это OK для свежей миграции,
                # но если scheduler работает > 2× interval — это alert.
                continue

            status, error, started_at = row[0], row[1], row[2]

            # Каска 1: последний run failed
            if status == "failed":
                unhealthy.append({
                    "job_name": spec.name,
                    "reason": "last_run_failed",
                    "started_at": started_at.isoformat() if started_at else None,
                    "error": (error or "")[:300],
                })
                continue

            # Каска 2: тишина дольше 2× interval
            if last_success is None:
                age_h = (now - started_at).total_seconds() / 3600 if started_at else 9999
            else:
                age_h = (now - last_success).total_seconds() / 3600

            if age_h > interval_h * 2:
                unhealthy.append({
                    "job_name": spec.name,
                    "reason": "silence_too_long",
                    "last_success_age_hours": round(age_h, 1),
                    "expected_interval_hours": interval_h,
                })

    return unhealthy


def format_alert_message(unhealthy: list[dict[str, Any]]) -> str:
    """Markdown-сообщение для posts_queue.request_text."""
    if not unhealthy:
        return ""
    lines = [
        "🚨 *audit-watchdog: проблемы с cron-job-ами*",
        f"Обнаружено {len(unhealthy)} проблемных job-а(ов):",
        "",
    ]
    for u in unhealthy:
        if u["reason"] == "last_run_failed":
            lines.append(f"❌ `{u['job_name']}`: последний run *failed*")
            if u.get("error"):
                lines.append(f"   _{u['error']}_")
            if u.get("started_at"):
                lines.append(f"   started_at: {u['started_at']}")
        elif u["reason"] == "silence_too_long":
            lines.append(
                f"⏰ `{u['job_name']}`: молчит {u['last_success_age_hours']}ч "
                f"(ожидание {u['expected_interval_hours']}ч × 2)"
            )
        lines.append("")
    lines.append(f"_Проверка: {datetime.now(timezone.utc).isoformat()}_")
    return "\n".join(lines)


async def enqueue_alert(message: str, dry_run: bool = False) -> int | None:
    """Кладём alert в `posts_queue`. Возвращает id или None."""
    if dry_run:
        print(message)
        return None

    from audit_engine.db import get_session

    async with get_session() as session:
        r = await session.execute(
            text(
                "INSERT INTO posts_queue "
                "(project_name, content_type, requester, request_text, "
                "is_urgent, status, requested_at) "
                "VALUES ('audit-watchdog', 'alert', 'audit-watchdog', :msg, "
                "true, 'ALERT', now()) RETURNING id"
            ),
            {"msg": message},
        )
        post_id = r.scalar()
        await session.commit()
    return post_id


async def run(dry_run: bool = False) -> int:
    unhealthy = await collect_unhealthy_jobs()
    if not unhealthy:
        logger.info("✅ Все job-ы здоровы")
        return 0

    logger.info("⚠️  %d job-ов проблемных", len(unhealthy))
    message = format_alert_message(unhealthy)
    post_id = await enqueue_alert(message, dry_run=dry_run)
    if post_id:
        logger.info("📬 Alert в posts_queue (id=%d)", post_id)
    return len(unhealthy)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="Не писать в posts_queue, только print")
    args = ap.parse_args()
    return asyncio.run(run(dry_run=args.dry_run))


if __name__ == "__main__":
    sys.exit(main())
