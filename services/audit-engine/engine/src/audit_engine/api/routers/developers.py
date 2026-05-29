"""`/api/v2/developers/...` — реестр застройщиков и риск-индекс.

- `GET  /developers/{inn}` — карточка по ИНН (из БД).
- `POST /developers/refresh/{inn}` — принудительный re-fetch через
  Федресурс + апсёрт.
- `GET  /developers/list?limit=50` — список с риск-индексом, сортировка
  по risk_multiplier ASC (самые рискованные сверху).
"""
from __future__ import annotations

import re
from typing import Any

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import text

from audit_engine.db import get_session
from audit_engine.parsers.developer_risk import refresh_developer_by_inn

router = APIRouter(prefix="/developers", tags=["developers"])

_INN_RE = re.compile(r"^\d{10}$|^\d{12}$")  # 10 — юр.лицо, 12 — ИП


def _validate_inn(inn: str) -> str:
    inn = inn.strip()
    if not _INN_RE.match(inn):
        raise HTTPException(400, detail=f"INN должен быть 10 или 12 цифр, получили: {inn!r}")
    return inn


@router.get("/{inn}")
async def get_developer(inn: str) -> dict[str, Any]:
    inn = _validate_inn(inn)
    async with get_session() as session:
        result = await session.execute(
            text(
                "SELECT id, name, inn, federresurs_status, lawsuits_count, "
                "risk_multiplier, last_check_at, notes "
                "FROM developers WHERE inn = :inn"
            ),
            {"inn": inn},
        )
        row = result.first()
    if not row:
        raise HTTPException(404, detail=f"Developer with INN={inn} not found. POST /developers/refresh/{inn} чтобы создать.")
    return {
        "id": row[0],
        "name": row[1],
        "inn": row[2],
        "federresurs_status": row[3],
        "lawsuits_count": row[4],
        "risk_multiplier": float(row[5]) if row[5] is not None else None,
        "last_check_at": row[6].isoformat() if row[6] else None,
        "notes": row[7],
    }


@router.post("/refresh/{inn}")
async def refresh_developer(inn: str) -> dict[str, Any]:
    inn = _validate_inn(inn)
    snap = await refresh_developer_by_inn(inn)
    return {
        "inn": snap.inn,
        "name": snap.name,
        "federresurs_status": snap.federresurs_status,
        "lawsuits_count": snap.lawsuits_count,
        "risk_multiplier": snap.risk_multiplier,
        "notes": snap.notes,
    }


@router.get("/")
async def list_developers(
    limit: int = Query(50, ge=1, le=500),
    min_risk: float | None = Query(None, ge=0.0, le=1.0,
                                   description="Только с risk_multiplier ≤ этого значения"),
) -> dict[str, Any]:
    async with get_session() as session:
        if min_risk is not None:
            result = await session.execute(
                text(
                    "SELECT id, name, inn, federresurs_status, lawsuits_count, "
                    "risk_multiplier, last_check_at "
                    "FROM developers WHERE risk_multiplier <= :mr "
                    "ORDER BY risk_multiplier ASC, lawsuits_count DESC LIMIT :lim"
                ),
                {"mr": min_risk, "lim": limit},
            )
        else:
            result = await session.execute(
                text(
                    "SELECT id, name, inn, federresurs_status, lawsuits_count, "
                    "risk_multiplier, last_check_at "
                    "FROM developers "
                    "ORDER BY risk_multiplier ASC NULLS LAST, name LIMIT :lim"
                ),
                {"lim": limit},
            )
        rows = [
            {
                "id": r[0],
                "name": r[1],
                "inn": r[2],
                "federresurs_status": r[3],
                "lawsuits_count": r[4],
                "risk_multiplier": float(r[5]) if r[5] is not None else None,
                "last_check_at": r[6].isoformat() if r[6] else None,
            }
            for r in result.fetchall()
        ]
    return {"count": len(rows), "developers": rows}
