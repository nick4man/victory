"""v2_monte_carlo

Revision ID: 1638584a66fa
Revises: e88a8d3263c9
Create Date: 2026-04-14 14:21:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '1638584a66fa'
down_revision: Union[str, None] = 'e88a8d3263c9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1. Create monte_carlo_runs table
    op.create_table(
        'monte_carlo_runs',
        sa.Column('id', sa.UUID(), primary_key=True, server_default=sa.text('gen_random_uuid()')),
        sa.Column('audit_id', sa.UUID(), sa.ForeignKey('audit_archive.id')),
        sa.Column('num_simulations', sa.Integer(), nullable=False, server_default='10000'),
        sa.Column('ei_mean', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_median', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_p5', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_p25', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_p75', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_p95', sa.Numeric(precision=8, scale=4)),
        sa.Column('ei_std', sa.Numeric(precision=8, scale=4)),
        sa.Column('buy_probability', sa.Numeric(precision=5, scale=2)),
        sa.Column('distribution_data', sa.JSON()),
        sa.Column('params', sa.JSON()),
        sa.Column('strategy', sa.String(length=20), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'))
    )
    
    # 2. Create index
    op.create_index('idx_mc_audit_strategy', 'monte_carlo_runs', ['audit_id', 'strategy'])
    
    # 3. Add columns to audit_archive
    op.add_column('audit_archive', sa.Column('monte_carlo_buy_prob', sa.Numeric(precision=5, scale=2)))
    op.add_column('audit_archive', sa.Column('monte_carlo_mean_ei', sa.Numeric(precision=8, scale=4)))


def downgrade() -> None:
    op.drop_column('audit_archive', 'monte_carlo_mean_ei')
    op.drop_column('audit_archive', 'monte_carlo_buy_prob')
    op.drop_index('idx_mc_audit_strategy', table_name='monte_carlo_runs')
    op.drop_table('monte_carlo_runs')
