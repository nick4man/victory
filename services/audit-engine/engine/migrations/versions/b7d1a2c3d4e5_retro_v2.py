"""retro_v2

Revision ID: b7d1a2c3d4e5
Revises: 1638584a66fa
Create Date: 2026-04-14 19:15:00.000000

"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = 'b7d1a2c3d4e5'
down_revision: Union[str, None] = '1638584a66fa'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

def upgrade() -> None:
    op.create_table(
        'price_history',
        sa.Column('id', sa.UUID(), primary_key=True, server_default=sa.text('gen_random_uuid()')),
        sa.Column('complex_name', sa.String(length=255), nullable=False),
        sa.Column('apartment_type', sa.String(length=50), nullable=False),
        sa.Column('area_sqm', sa.Numeric(precision=10, scale=2), nullable=False),
        sa.Column('price_per_sqm', sa.Numeric(precision=12, scale=2), nullable=False),
        sa.Column('price_total', sa.Numeric(precision=15, scale=2), nullable=False),
        sa.Column('source', sa.String(length=100)),
        sa.Column('snapshot_date', sa.Date(), nullable=False),
        sa.Column('macro_snapshot', postgresql.JSONB(astext_type=sa.Text())),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'))
    )
    op.create_index('idx_price_hist_complex_type', 'price_history', ['complex_name', 'apartment_type', 'snapshot_date'])

def downgrade() -> None:
    op.drop_index('idx_price_hist_complex_type', table_name='price_history')
    op.drop_table('price_history')
