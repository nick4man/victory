"""Price history endpoints — исторические цены по ЖК."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.api.deps import get_db

router = APIRouter(prefix="/price-history", tags=["price-history"])


@router.get("/{complex_name}")
async def get_price_history(
    complex_name: str,
    apartment_type: str | None = None,
    limit: int = 500,
    db: AsyncSession = Depends(get_db),
):
    """История цен по ЖК (с опциональным фильтром по типу квартиры)."""
    if limit <= 0 or limit > 5000:
        raise HTTPException(
            status_code=400,
            detail="limit must be in (0, 5000]",
        )

    query = (
        "SELECT id, complex_name, apartment_type, area_sqm, "
        "       price_per_sqm, price_total, source, snapshot_date, "
        "       macro_snapshot, created_at "
        "FROM price_history "
        "WHERE complex_name = :cn "
    )
    params: dict[str, object] = {"cn": complex_name, "lim": limit}
    if apartment_type:
        query += " AND apartment_type = :at"
        params["at"] = apartment_type
    query += " ORDER BY snapshot_date ASC LIMIT :lim"

    result = await db.execute(text(query), params)
    rows = result.fetchall()
    if not rows:
        raise HTTPException(
            status_code=404,
            detail=f"No price history for complex '{complex_name}'",
        )
    return [dict(r._mapping) for r in rows]
