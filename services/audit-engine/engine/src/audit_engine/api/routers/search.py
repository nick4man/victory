"""D4 — REST поиск по архиву аудитов / дайджестов через pgvector.

Эндпоинты:
- `POST /audit/search` — semantic search по `digest_archive` через cosine.
- `POST /audit/search/reindex` — бэкфилл embeddings для строк с NULL.

Если `GEMINI_EMBEDDING_API_KEY` не задан → 503.
"""
from __future__ import annotations

import os
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.api.deps import get_db
from audit_engine.services.digest_indexer import (
    GEMINI_API_KEY,
    index_missing,
    search_similar,
)

router = APIRouter(prefix="/audit/search", tags=["search"])


class SearchRequest(BaseModel):
    q: str = Field(min_length=2, max_length=2000)
    top_k: int = Field(default=10, ge=1, le=50)
    min_similarity: float = Field(default=0.0, ge=0.0, le=1.0)


def _ensure_embedder() -> None:
    if not GEMINI_API_KEY:
        raise HTTPException(
            status_code=503,
            detail=(
                "GEMINI_EMBEDDING_API_KEY (или GEMINI_API_KEY) не задан — "
                "embedding-сервис недоступен. Search невозможен."
            ),
        )


@router.post("")
async def search_audits(
    spec: SearchRequest,
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    _ensure_embedder()
    hits = await search_similar(
        db, spec.q, top_k=spec.top_k, min_similarity=spec.min_similarity
    )
    return {"query": spec.q, "count": len(hits), "hits": hits}


@router.post("/reindex")
async def search_reindex(
    limit: int = 100,
    db: AsyncSession = Depends(get_db),
) -> dict[str, Any]:
    """Backfill embeddings: пробегает digest_archive WHERE embedding IS NULL."""
    _ensure_embedder()
    if limit < 1 or limit > 1000:
        raise HTTPException(400, detail="limit must be 1..1000")
    indexed = await index_missing(db, limit=limit)
    return {"indexed": indexed, "limit": limit}
