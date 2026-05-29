"""cron_runs — журнал запусков планировщика

Revision ID: i7e8d4f3a9c1
Revises: h6c4e9f2b8a1
Create Date: 2026-05-10 22:30:00.000000

Таблица хранит историю запусков всех job-ов APScheduler-а
(`audit_engine.jobs.scheduler`). По ней эндпоинт `/api/v2/jobs/status`
строит ответ о здоровье крона, а watchdog `check_cron_health.py`
эскалирует тишину в Telegram-алерт.

Структура:
- `job_name` — стабильный идентификатор job-а (см. scheduler.JOBS).
- `started_at` / `finished_at` — UTC timestamps.
- `status` — 'success' | 'failed' | 'running'.
- `rows_affected` — число строк, обновлённых job-ом (для парсеров).
- `error` — текст исключения, если status='failed'.

Downgrade — дроп таблицы.
"""
from typing import Sequence, Union

from alembic import op


revision: str = "i7e8d4f3a9c1"
down_revision: Union[str, Sequence[str], None] = "h6c4e9f2b8a1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS cron_runs (
            id            BIGSERIAL PRIMARY KEY,
            job_name      TEXT NOT NULL,
            started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
            finished_at   TIMESTAMPTZ,
            status        TEXT NOT NULL CHECK (status IN ('success', 'failed', 'running')),
            rows_affected INTEGER,
            error         TEXT
        )
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS ix_cron_runs_job_started ON cron_runs(job_name, started_at DESC)")


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_cron_runs_job_started")
    op.execute("DROP TABLE IF EXISTS cron_runs")
