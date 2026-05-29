"""add_points_of_interest

Revision ID: e3b1f0a9c210
Revises: d2a9b1c4e501
Create Date: 2026-04-19 11:00:00.000000

Фаза D: подключение локационного scoring-а. Таблица POI (метро, школы,
больницы, парки, ТРЦ) — источник данных для расчёта близости и
инфраструктурной насыщенности вокруг объекта.

Индексы: по (poi_type, latitude, longitude) для быстрого bounding-box
префильтра перед haversine-фильтрацией. PostGIS не используем на этом
шаге — haversine над bbox-префильтром укладывается в миллисекунды на
10к POI.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = 'e3b1f0a9c210'
down_revision: Union[str, None] = 'd2a9b1c4e501'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'points_of_interest',
        sa.Column('id', sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column('name', sa.String(length=255), nullable=False),
        sa.Column(
            'poi_type',
            sa.String(length=64),
            nullable=False,
            comment='metro | school | hospital | park | mall | kindergarten | university',
        ),
        sa.Column('latitude', sa.Numeric(precision=10, scale=7), nullable=False),
        sa.Column('longitude', sa.Numeric(precision=10, scale=7), nullable=False),
        sa.Column('address', sa.String(length=512)),
        sa.Column('city', sa.String(length=100)),
        sa.Column('district', sa.String(length=100)),
        sa.Column('attributes', postgresql.JSONB(astext_type=sa.Text()), server_default=sa.text("'{}'::jsonb")),
        sa.Column('source', sa.String(length=100), server_default=sa.text("'manual'")),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
    )
    op.create_index(
        'idx_poi_type_location',
        'points_of_interest',
        ['poi_type', 'latitude', 'longitude'],
    )
    op.create_index(
        'idx_poi_city_type',
        'points_of_interest',
        ['city', 'poi_type'],
    )


def downgrade() -> None:
    op.drop_index('idx_poi_city_type', table_name='points_of_interest')
    op.drop_index('idx_poi_type_location', table_name='points_of_interest')
    op.drop_table('points_of_interest')
