"""add_competitors

Revision ID: f4a2c7b9e821
Revises: e3b1f0a9c210
Create Date: 2026-04-19 12:00:00.000000

Фаза E: таблица ретроспективных конкурентных предложений (компов) —
снапшоты публичных объявлений CIAN/Avito по ЖК. Используется для
перцентильного позиционирования аудируемой цены внутри локального рынка.

Индексы: (complex_name, snapshot_date) для свежих снапшотов; (source, url)
для дедупликации. `scraped_at` — физическое время забора (может отличаться
от `snapshot_date` — календарного дня, которым снапшот датируется).
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'f4a2c7b9e821'
down_revision: Union[str, None] = 'e3b1f0a9c210'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'competitors',
        sa.Column('id', sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column('complex_name', sa.String(length=255), nullable=False),
        sa.Column('snapshot_date', sa.Date(), nullable=False),
        sa.Column('competitor_name', sa.String(length=255), nullable=False),
        sa.Column('latitude', sa.Numeric(precision=10, scale=7)),
        sa.Column('longitude', sa.Numeric(precision=10, scale=7)),
        sa.Column('distance_m', sa.Integer()),
        sa.Column('price_total', sa.Numeric(precision=18, scale=2)),
        sa.Column('price_per_sqm', sa.Numeric(precision=14, scale=2), nullable=False),
        sa.Column('area_sqm', sa.Numeric(precision=8, scale=2)),
        sa.Column('rooms', sa.Integer()),
        sa.Column('property_type', sa.String(length=32), server_default=sa.text("'APARTMENT'")),
        sa.Column('source', sa.String(length=64), nullable=False,
                  comment='cian | avito | dom_rf | manual'),
        sa.Column('url', sa.String(length=1024)),
        sa.Column('scraped_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    )
    op.create_index(
        'idx_competitors_complex_date',
        'competitors',
        ['complex_name', 'snapshot_date'],
    )
    op.create_index(
        'idx_competitors_source_url',
        'competitors',
        ['source', 'url'],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index('idx_competitors_source_url', table_name='competitors')
    op.drop_index('idx_competitors_complex_date', table_name='competitors')
    op.drop_table('competitors')
