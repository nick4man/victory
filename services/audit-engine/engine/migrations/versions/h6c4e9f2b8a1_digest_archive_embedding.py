"""Ensure digest_archive has embedding vector(768) + canonical schema

Revision ID: h6c4e9f2b8a1
Revises: g5b3d8f1a932
Create Date: 2026-05-07 09:30:00.000000

`workspace-conveyor/vector_search_service.py` ожидает
`digest_archive(id, title, content_md, embedding vector)` с pgvector cosine
distance (`embedding <=> %s::vector`). `gemini_embedding_writer.py` создаёт
таблицу с `embedding vector(768)` (Gemini gemini-embedding-001).

В рабочей БД таблица существует со схемой `(id, title, content_md, filepath)`
без `embedding` — vector_search ломается. Эта миграция:
- идемпотентно создаёт таблицу при отсутствии,
- добавляет `embedding vector(768)` если его нет,
- ставит ivfflat-индекс по cosine distance для быстрого ANN-поиска.

Downgrade — снимает индекс и столбец, таблицу не дропаем (там данные).
"""
from typing import Sequence, Union

from alembic import op


revision: str = "h6c4e9f2b8a1"
down_revision: Union[str, Sequence[str], None] = "g5b3d8f1a932"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS digest_archive (
            id          SERIAL PRIMARY KEY,
            title       TEXT NOT NULL,
            content_md  TEXT NOT NULL,
            filepath    TEXT,
            embedding   vector(768),
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )
    op.execute("ALTER TABLE digest_archive ADD COLUMN IF NOT EXISTS embedding vector(768)")
    op.execute(
        "ALTER TABLE digest_archive "
        "ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now()"
    )
    # ivfflat по cosine: для < 1000 строк хватит и seq-scan, но индекс
    # не повредит и сразу заработает на росте.
    op.execute(
        "CREATE INDEX IF NOT EXISTS idx_digest_archive_embedding "
        "ON digest_archive USING ivfflat (embedding vector_cosine_ops) "
        "WITH (lists = 100)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS idx_digest_archive_embedding")
    op.execute("ALTER TABLE digest_archive DROP COLUMN IF EXISTS embedding")
