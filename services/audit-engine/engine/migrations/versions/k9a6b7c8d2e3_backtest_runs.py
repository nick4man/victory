"""backtest_runs — журнал back-test прогонов прогнозной точности

Revision ID: k9a6b7c8d2e3
Revises: j8f5e6a7b9c2
Create Date: 2026-05-11 09:00:00.000000

Хранит результаты `scripts.backtest._run`:
- период за который сверяли (period_from / period_to)
- метрики (n_forecasts, mape, rmse, sign_accuracy)
- полный markdown-отчёт (для дальнейшего поиска и сравнения версий)
- временные метки (started_at / finished_at)

Используется:
- Эндпоинтом /api/v2/jobs/history?job=backtest (через cron_runs) + /backtest/latest.
- Watchdog-ом для эскалации Боссу при MAPE > 20% (см. E4).
"""
from typing import Sequence, Union

from alembic import op


revision: str = "k9a6b7c8d2e3"
down_revision: Union[str, Sequence[str], None] = "j8f5e6a7b9c2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS backtest_runs (
            id              BIGSERIAL PRIMARY KEY,
            started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            finished_at     TIMESTAMPTZ,
            period_from     DATE NOT NULL,
            period_to       DATE NOT NULL,
            n_forecasts     INTEGER NOT NULL DEFAULT 0,
            mape            NUMERIC(6,3),
            rmse            NUMERIC(14,2),
            sign_accuracy   NUMERIC(5,3),
            markdown_report TEXT,
            status          TEXT NOT NULL DEFAULT 'success' CHECK (status IN ('success', 'failed'))
        )
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS ix_backtest_runs_period ON backtest_runs(period_from DESC, period_to DESC)")


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_backtest_runs_period")
    op.execute("DROP TABLE IF EXISTS backtest_runs")
