"""baseline

Revision ID: e88a8d3263c9
Revises: 
Create Date: 2026-04-14 14:22:36.019516

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e88a8d3263c9'
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Create all base tables for Audit Engine v2.0."""

    # Developers
    op.create_table(
        'developers',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column('name', sa.String(length=256), nullable=False, unique=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
    )

    # Complexes
    op.create_table(
        'complexes',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column('developer_id', sa.Integer(), sa.ForeignKey('developers.id')),
        sa.Column('name', sa.String(length=256), nullable=False),
        sa.Column('location', sa.String(length=512)),
        sa.Column('status', sa.String(length=50), server_default='active'),
        sa.Column('delivery_date', sa.Date()),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
    )

    # Apartments
    op.create_table(
        'apartments',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column('complex_id', sa.Integer(), sa.ForeignKey('complexes.id'), nullable=False),
        sa.Column('apartment_type', sa.String(length=50), nullable=False),
        sa.Column('area', sa.Numeric(precision=8, scale=2)),
        sa.Column('price_total', sa.Numeric(precision=14, scale=2)),
        sa.Column('price_per_sqm', sa.Numeric(precision=10, scale=2)),
        sa.Column('floor', sa.Integer()),
        sa.Column('rooms', sa.Integer()),
        sa.Column('is_available', sa.Boolean(), server_default='true'),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
    )

    # Macro economics
    op.create_table(
        'macro_economics',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column('date', sa.Date(), nullable=False, unique=True),
        sa.Column('cbr_key_rate', sa.Numeric(precision=6, scale=2)),
        sa.Column('inflation_annual', sa.Numeric(precision=6, scale=2)),
        sa.Column('inflation_monthly', sa.Numeric(precision=6, scale=3)),
        sa.Column('avg_deposit_rate', sa.Numeric(precision=6, scale=2)),
        sa.Column('avg_mortgage_rate', sa.Numeric(precision=6, scale=2)),
        sa.Column('ofz_yield_1y', sa.Numeric(precision=6, scale=2)),
        sa.Column('ofz_yield_3y', sa.Numeric(precision=6, scale=2)),
        sa.Column('ofz_yield_5y', sa.Numeric(precision=6, scale=2)),
        sa.Column('source', sa.String(length=256)),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
    )

    # Historical prices
    op.create_table(
        'historical_prices',
        sa.Column('id', sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column('complex_id', sa.Integer(), sa.ForeignKey('complexes.id')),
        sa.Column('apartment_type', sa.String(length=50)),
        sa.Column('area', sa.Numeric(precision=8, scale=2)),
        sa.Column('price_total', sa.Numeric(precision=14, scale=2)),
        sa.Column('price_per_sqm', sa.Numeric(precision=10, scale=2)),
        sa.Column('source_url', sa.String(length=1024)),
        sa.Column('snapshot_date', sa.Date(), server_default=sa.text('CURRENT_DATE')),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
    )

    # Audit archive
    op.create_table(
        'audit_archive',
        sa.Column('id', sa.UUID(), primary_key=True, server_default=sa.text('gen_random_uuid()')),
        sa.Column('object_address', sa.String(length=512)),
        sa.Column('apartment_type', sa.String(length=50)),
        sa.Column('area_sqm', sa.Numeric(precision=8, scale=2)),
        sa.Column('audit_date', sa.Date()),
        sa.Column('price_total', sa.Numeric(precision=14, scale=2)),
        sa.Column('price_per_sqm', sa.Numeric(precision=10, scale=2)),
        sa.Column('mortgage_rate', sa.Numeric(precision=6, scale=2)),
        sa.Column('deposit_rate', sa.Numeric(precision=6, scale=2)),
        sa.Column('down_payment_pct', sa.Numeric(precision=5, scale=2)),
        sa.Column('mortgage_term_years', sa.Integer()),
        sa.Column('monthly_rent', sa.Numeric(precision=10, scale=2)),
        sa.Column('price_growth_annual', sa.Numeric(precision=6, scale=2)),
        sa.Column('horizon_years', sa.Integer()),
        sa.Column('cash_discount_pct', sa.Numeric(precision=5, scale=2)),
        sa.Column('input_params', sa.JSON()),
        sa.Column('ei_cash', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_deposit', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_mortgage', sa.Numeric(precision=8, scale=4)),
        sa.Column('engine_version', sa.String(length=20)),
        sa.Column('verdict', sa.String(length=20)),
        sa.Column('verdict_explanation', sa.Text()),
        sa.Column('risks', sa.JSON()),
        sa.Column('assumptions', sa.JSON()),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()')),
    )

    # Indexes
    op.create_index('idx_macro_date', 'macro_economics', ['date'])
    op.create_index('idx_audit_date', 'audit_archive', ['audit_date'])
    op.create_index('idx_hist_complex', 'historical_prices', ['complex_id', 'snapshot_date'])


def downgrade() -> None:
    """Drop all base tables."""
    op.drop_index('idx_hist_complex', table_name='historical_prices')
    op.drop_index('idx_audit_date', table_name='audit_archive')
    op.drop_index('idx_macro_date', table_name='macro_economics')
    op.drop_table('audit_archive')
    op.drop_table('historical_prices')
    op.drop_table('macro_economics')
    op.drop_table('apartments')
    op.drop_table('complexes')
    op.drop_table('developers')
