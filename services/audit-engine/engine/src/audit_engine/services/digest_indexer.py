"""D4 — Vector-индекс по `digest_archive`.

Embedder: Gemini `gemini-embedding-001` (768-dim, изолированный ключ
`GEMINI_EMBEDDING_API_KEY`). Запись в pgvector колонку `embedding`.

Поиск: cosine-distance через оператор `<=>` pgvector. Возвращает top-K
с similarity = 1 - distance.

Конфиг:
- `GEMINI_EMBEDDING_API_KEY`  — обязательный. Если не задан, embed_text/embed_row
  возвращают None, search возвращает 503 (см. router).
- `GEMINI_EMBEDDING_MODEL`    — по умолчанию `gemini-embedding-001` (768-dim).
- `EMBEDDING_DIM`             — 768 (соответствует миграции h6c4e9f2b8a1).
"""
from __future__ import annotations

import logging
import os
from typing import Any

import httpx
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

GEMINI_API_KEY = os.environ.get("GEMINI_EMBEDDING_API_KEY") or os.environ.get("GEMINI_API_KEY", "")
GEMINI_EMBEDDING_MODEL = os.environ.get("GEMINI_EMBEDDING_MODEL", "gemini-embedding-001")
EMBEDDING_DIM = 768

GEMINI_URL = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    "{model}:embedContent?key={key}"
)


async def embed_text(text_value: str) -> list[float] | None:
    """Получить 768-мерный embedding текста через Gemini.

    None при отсутствии ключа или сетевой ошибке.
    """
    if not GEMINI_API_KEY:
        logger.info("GEMINI_EMBEDDING_API_KEY не задан — embed пропускаем")
        return None
    if not text_value or not text_value.strip():
        return None

    url = GEMINI_URL.format(model=GEMINI_EMBEDDING_MODEL, key=GEMINI_API_KEY)
    payload = {
        "model": f"models/{GEMINI_EMBEDDING_MODEL}",
        "content": {"parts": [{"text": text_value[:8000]}]},  # ограничение Gemini ~ 2048 токенов
        "outputDimensionality": EMBEDDING_DIM,
    }

    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            resp = await client.post(url, json=payload)
            resp.raise_for_status()
            data = resp.json()
            values = data.get("embedding", {}).get("values", [])
            if len(values) != EMBEDDING_DIM:
                logger.warning("embed returned %d dims, expected %d", len(values), EMBEDDING_DIM)
                return None
            return values
        except Exception as exc:
            logger.warning("embed_text failed: %s", exc)
            return None


def _vector_literal(vec: list[float]) -> str:
    """pgvector принимает строку '[v1,v2,...]' для CAST к vector(N)."""
    return "[" + ",".join(f"{v:.6f}" for v in vec) + "]"


async def index_digest(
    db: AsyncSession,
    digest_id: int,
    title: str,
    content_md: str,
) -> bool:
    """Считаем embedding и записываем в `embedding` колонку digest_archive.

    Возвращает True если запись произошла, False иначе.
    """
    # Embed-источник = title + первый параграф content_md (≤ 1500 chars).
    embed_input = f"{title}\n\n{content_md[:1500]}" if content_md else title
    vec = await embed_text(embed_input)
    if vec is None:
        return False

    await db.execute(
        text(
            "UPDATE digest_archive SET embedding = CAST(:vec AS vector) "
            "WHERE id = :id"
        ),
        {"vec": _vector_literal(vec), "id": digest_id},
    )
    await db.commit()
    return True


async def index_missing(db: AsyncSession, limit: int = 100) -> int:
    """Бэкфилл: проиндексировать digest_archive строки с NULL embedding."""
    result = await db.execute(
        text(
            "SELECT id, title, content_md FROM digest_archive "
            "WHERE embedding IS NULL LIMIT :lim"
        ),
        {"lim": limit},
    )
    rows = result.fetchall()
    indexed = 0
    for row in rows:
        ok = await index_digest(db, row[0], row[1] or "", row[2] or "")
        if ok:
            indexed += 1
    return indexed


async def search_similar(
    db: AsyncSession, query: str, top_k: int = 10, min_similarity: float = 0.0,
) -> list[dict[str, Any]]:
    """Top-K похожих digest по cosine similarity к `query`.

    Возвращает [{id, title, similarity, filepath, created_at}], отсортировано
    по убыванию similarity.
    """
    qvec = await embed_text(query)
    if qvec is None:
        return []

    qlit = _vector_literal(qvec)
    result = await db.execute(
        text(
            "SELECT id, title, filepath, created_at, "
            "1 - (embedding <=> CAST(:qvec AS vector)) AS similarity "
            "FROM digest_archive "
            "WHERE embedding IS NOT NULL "
            "ORDER BY embedding <=> CAST(:qvec AS vector) "
            "LIMIT :k"
        ),
        {"qvec": qlit, "k": top_k},
    )
    rows = result.fetchall()
    out = []
    for r in rows:
        sim = float(r[4])
        if sim < min_similarity:
            continue
        out.append({
            "id": r[0],
            "title": r[1],
            "filepath": r[2],
            "created_at": r[3].isoformat() if r[3] else None,
            "similarity": round(sim, 4),
        })
    return out
