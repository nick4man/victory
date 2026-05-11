"""add_property_type

Revision ID: d2a9b1c4e501
Revises: c9f3b4e5d678
Create Date: 2026-04-19 10:00:00.000000

Фаза C: поддержка HOUSE / LAND / BUSINESS в аудите. Расширяем
`audit_archive` полиморфными колонками без обязательной миграции данных —
существующие строки автоматически остаются APARTMENT через DEFAULT.

* `property_type` — дискриминатор (APARTMENT default для back-compat).
* HOUSE-специфика: `land_area_sotka`, `annual_utilities_cost`.
* LAND-специфика: `zoning`, `annual_tax`.
* BUSINESS-специфика: `annual_revenue`, `ebitda`, `discount_rate`.
* Геоданные (фаза D заделка): `lat`, `lon`, `cadastral_number`.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = 'd2a9b1c4e501'
down_revision: Union[str, None] = 'c9f3b4e5d678'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'audit_archive',
        sa.Column(
            'property_type',
            sa.String(length=32),
            nullable=False,
            server_default=sa.text("'APARTMENT'"),
        ),
    )
    # House / Land
    op.add_column('audit_archive', sa.Column('land_area_sotka', sa.Numeric(precision=12, scale=3)))
    op.add_column('audit_archive', sa.Column('annual_utilities_cost', sa.Numeric(precision=15, scale=2)))
    op.add_column('audit_archive', sa.Column('zoning', sa.String(length=64)))
    op.add_column('audit_archive', sa.Column('annual_tax', sa.Numeric(precision=15, scale=2)))

    # Business
    op.add_column('audit_archive', sa.Column('annual_revenue', sa.Numeric(precision=18, scale=2)))
    op.add_column('audit_archive', sa.Column('ebitda', sa.Numeric(precision=18, scale=2)))
    op.add_column('audit_archive', sa.Column('discount_rate', sa.Numeric(precision=6, scale=3)))

    # Геоданные (заделка под фазу D — location scoring).
    op.add_column('audit_archive', sa.Column('lat', sa.Numeric(precision=10, scale=7)))
    op.add_column('audit_archive', sa.Column('lon', sa.Numeric(precision=10, scale=7)))
    op.add_column('audit_archive', sa.Column('cadastral_number', sa.String(length=64)))

    op.create_index(
        'idx_audit_archive_property_type',
        'audit_archive',
        ['property_type', 'audit_date'],
    )


def downgrade() -> None:
    op.drop_index('idx_audit_archive_property_type', table_name='audit_archive')
    for col in (
        'cadastral_number', 'lon', 'lat',
        'discount_rate', 'ebitda', 'annual_revenue',
        'annual_tax', 'zoning',
        'annual_utilities_cost', 'land_area_sotka',
        'property_type',
    ):
        op.drop_column('audit_archive', col)
