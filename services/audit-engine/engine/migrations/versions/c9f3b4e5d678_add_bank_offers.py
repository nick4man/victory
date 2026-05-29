"""add_bank_offers

Revision ID: c9f3b4e5d678
Revises: b7d1a2c3d4e5
Create Date: 2026-04-18 12:00:00.000000

Реестр актуальных банковских продуктов (ипотека, потребительские кредиты,
субсидированные / льготные программы). Monte-Carlo аудит по умолчанию
прогоняет симуляцию по каждому подходящему офферу и возвращает
рекомендованный по EI_median.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'c9f3b4e5d678'
down_revision: Union[str, None] = 'b7d1a2c3d4e5'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'bank_offers',
        sa.Column('id', sa.UUID(), primary_key=True, server_default=sa.text('gen_random_uuid()')),
        sa.Column('bank_name', sa.String(length=128), nullable=False),
        sa.Column('product_type', sa.String(length=64), nullable=False),
        sa.Column('product_name', sa.String(length=255), nullable=False),
        sa.Column('rate_min', sa.Numeric(precision=6, scale=3), nullable=False),
        sa.Column('rate_max', sa.Numeric(precision=6, scale=3)),
        sa.Column('term_years_min', sa.Integer()),
        sa.Column('term_years_max', sa.Integer()),
        sa.Column('down_payment_min_pct', sa.Numeric(precision=5, scale=2)),
        sa.Column('max_loan_amount', sa.Numeric(precision=15, scale=2)),
        sa.Column('requirements', postgresql.JSONB(astext_type=sa.Text()), server_default=sa.text("'{}'::jsonb")),
        sa.Column('valid_from', sa.Date(), nullable=False),
        sa.Column('valid_to', sa.Date()),
        sa.Column('source', sa.String(length=64), nullable=False),
        sa.Column('source_url', sa.String(length=1024)),
        sa.Column('scraped_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('is_active', sa.Boolean(), nullable=False, server_default=sa.text('true')),
    )
    op.create_index(
        'idx_bank_offers_active',
        'bank_offers',
        ['is_active', 'product_type', 'rate_min'],
    )
    op.create_index(
        'idx_bank_offers_bank_product',
        'bank_offers',
        ['bank_name', 'product_type'],
    )


def downgrade() -> None:
    op.drop_index('idx_bank_offers_bank_product', table_name='bank_offers')
    op.drop_index('idx_bank_offers_active', table_name='bank_offers')
    op.drop_table('bank_offers')
