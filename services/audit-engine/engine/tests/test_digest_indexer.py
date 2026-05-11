"""D4 unit-тесты — vector search над `digest_archive`.

Без сети — мокаем `embed_text`. Проверяем:
1. `_vector_literal` корректно форматирует.
2. `embed_text` возвращает None при отсутствии API-ключа.
3. `search_similar` строит ожидаемый SQL и сортирует по similarity DESC.
"""
from __future__ import annotations

import os
import sys
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from audit_engine.services import digest_indexer
from audit_engine.services.digest_indexer import _vector_literal, embed_text


# -----------------------------------------------------------------------
# _vector_literal
# -----------------------------------------------------------------------

def test_vector_literal_format():
    out = _vector_literal([1.0, -0.5, 0.123456789])
    assert out.startswith("[")
    assert out.endswith("]")
    parts = out[1:-1].split(",")
    assert len(parts) == 3
    assert parts[0] == "1.000000"
    assert parts[1] == "-0.500000"
    assert parts[2] == "0.123457"  # rounded to 6 decimals


def test_vector_literal_empty():
    assert _vector_literal([]) == "[]"


# -----------------------------------------------------------------------
# embed_text
# -----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_embed_text_returns_none_when_no_key():
    with patch.object(digest_indexer, "GEMINI_API_KEY", ""):
        result = await embed_text("test query")
    assert result is None


@pytest.mark.asyncio
async def test_embed_text_returns_none_for_empty_input():
    with patch.object(digest_indexer, "GEMINI_API_KEY", "fake-key"):
        result = await embed_text("")
    assert result is None
    result2 = await embed_text("   \n\t")
    assert result2 is None


@pytest.mark.asyncio
async def test_embed_text_parses_gemini_response():
    fake_vec = [0.1] * 768
    fake_resp = MagicMock()
    fake_resp.raise_for_status = MagicMock()
    fake_resp.json = MagicMock(return_value={"embedding": {"values": fake_vec}})

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=fake_resp)

    with patch.object(digest_indexer, "GEMINI_API_KEY", "fake-key"):
        with patch("audit_engine.services.digest_indexer.httpx.AsyncClient", return_value=mock_client):
            vec = await embed_text("test query")
    assert vec is not None
    assert len(vec) == 768


@pytest.mark.asyncio
async def test_embed_text_returns_none_on_dim_mismatch():
    fake_resp = MagicMock()
    fake_resp.raise_for_status = MagicMock()
    fake_resp.json = MagicMock(return_value={"embedding": {"values": [0.1] * 512}})

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock(return_value=fake_resp)

    with patch.object(digest_indexer, "GEMINI_API_KEY", "fake-key"):
        with patch("audit_engine.services.digest_indexer.httpx.AsyncClient", return_value=mock_client):
            vec = await embed_text("test query")
    assert vec is None  # wrong dim


# -----------------------------------------------------------------------
# search_similar (in-memory mock)
# -----------------------------------------------------------------------

@pytest.mark.asyncio
async def test_search_similar_returns_empty_when_embed_fails():
    from audit_engine.services.digest_indexer import search_similar

    fake_db = MagicMock()
    with patch.object(digest_indexer, "embed_text", AsyncMock(return_value=None)):
        result = await search_similar(fake_db, "test query")
    assert result == []


@pytest.mark.asyncio
async def test_search_similar_builds_sql_and_returns_hits():
    from datetime import datetime

    from audit_engine.services.digest_indexer import search_similar

    # Mock DB
    fake_rows = [
        (1, "Аудит ЖК Альфа", "/archive/a.md", datetime(2026, 1, 1), 0.92),
        (2, "Аудит ЖК Бета",  "/archive/b.md", datetime(2026, 2, 1), 0.78),
        (3, "Аудит ЖК Гамма", "/archive/g.md", datetime(2026, 3, 1), 0.45),
    ]
    fake_result = MagicMock()
    fake_result.fetchall = MagicMock(return_value=fake_rows)
    fake_db = MagicMock()
    fake_db.execute = AsyncMock(return_value=fake_result)

    with patch.object(digest_indexer, "embed_text", AsyncMock(return_value=[0.1] * 768)):
        hits = await search_similar(fake_db, "ЖК ЦАО ипотека", top_k=10)

    assert len(hits) == 3
    assert hits[0]["title"] == "Аудит ЖК Альфа"
    assert hits[0]["similarity"] == 0.92
    assert hits[2]["similarity"] == 0.45

    # Проверим SQL — должен содержать pgvector cosine оператор `<=>`
    args, _ = fake_db.execute.call_args
    sql_text = str(args[0])
    assert "embedding <=>" in sql_text
    assert "1 - (embedding <=>" in sql_text


@pytest.mark.asyncio
async def test_search_similar_min_similarity_filter():
    from datetime import datetime

    from audit_engine.services.digest_indexer import search_similar

    fake_rows = [
        (1, "X", "/x.md", datetime(2026, 1, 1), 0.90),
        (2, "Y", "/y.md", datetime(2026, 2, 1), 0.55),
        (3, "Z", "/z.md", datetime(2026, 3, 1), 0.20),
    ]
    fake_result = MagicMock()
    fake_result.fetchall = MagicMock(return_value=fake_rows)
    fake_db = MagicMock()
    fake_db.execute = AsyncMock(return_value=fake_result)

    with patch.object(digest_indexer, "embed_text", AsyncMock(return_value=[0.1] * 768)):
        hits = await search_similar(fake_db, "query", top_k=10, min_similarity=0.5)

    assert len(hits) == 2  # 0.20 отфильтрован
    assert all(h["similarity"] >= 0.5 for h in hits)
