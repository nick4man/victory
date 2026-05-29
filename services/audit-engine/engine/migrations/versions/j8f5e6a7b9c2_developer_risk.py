"""developer risk index — Федресурс / СПАРК

Revision ID: j8f5e6a7b9c2
Revises: i7e8d4f3a9c1
Create Date: 2026-05-10 22:30:00.000000

Расширяет существующую `developers` колонками для risk-индекса:
- `inn`                 — ИНН организации, UNIQUE
- `federresurs_status`  — 'active' | 'bankruptcy_initiated' | 'bankruptcy' | 'liquidated' | 'unknown'
- `lawsuits_count`      — число судебных дел (картотека арбитражных судов)
- `risk_multiplier`     — итоговый множитель к EI (0.85 = высокий риск, 1.0 = норма)
- `last_check_at`       — когда последний раз ходили на источники
- `notes`               — служебный текст (зачем понижали multiplier)

Логика:
- `risk_multiplier` = 1.0 если status=active И lawsuits<5
- 0.95 если 5 ≤ lawsuits < 20
- 0.90 если lawsuits ≥ 20 ИЛИ status=bankruptcy_initiated
- 0.85 если status in ('bankruptcy', 'liquidated')

EI калькулятор подтянет этот multiplier из БД по `complex.developer_id` →
`developers.risk_multiplier`. Не делает магии: просто умножает финальный
EI на этот коэффициент.
"""
from typing import Sequence, Union

from alembic import op


revision: str = "j8f5e6a7b9c2"
down_revision: Union[str, Sequence[str], None] = "i7e8d4f3a9c1"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        ALTER TABLE developers
            ADD COLUMN IF NOT EXISTS inn                  VARCHAR(20),
            ADD COLUMN IF NOT EXISTS federresurs_status   VARCHAR(32) DEFAULT 'unknown',
            ADD COLUMN IF NOT EXISTS lawsuits_count       INTEGER DEFAULT 0,
            ADD COLUMN IF NOT EXISTS risk_multiplier      NUMERIC(3,2) DEFAULT 1.00,
            ADD COLUMN IF NOT EXISTS last_check_at        TIMESTAMPTZ,
            ADD COLUMN IF NOT EXISTS notes                TEXT
        """
    )
    op.execute("CREATE UNIQUE INDEX IF NOT EXISTS ix_developers_inn ON developers(inn) WHERE inn IS NOT NULL")
    op.execute("CREATE INDEX IF NOT EXISTS ix_developers_last_check ON developers(last_check_at)")


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS ix_developers_last_check")
    op.execute("DROP INDEX IF EXISTS ix_developers_inn")
    op.execute(
        """
        ALTER TABLE developers
            DROP COLUMN IF EXISTS notes,
            DROP COLUMN IF EXISTS last_check_at,
            DROP COLUMN IF EXISTS risk_multiplier,
            DROP COLUMN IF EXISTS lawsuits_count,
            DROP COLUMN IF EXISTS federresurs_status,
            DROP COLUMN IF EXISTS inn
        """
    )
