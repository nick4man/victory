"""Complexes CRUD endpoints."""

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

from audit_engine.api.deps import get_db

router = APIRouter(prefix="/complexes", tags=["complexes"])


@router.get("/")
async def list_complexes(db: AsyncSession = Depends(get_db)):
    """List all residential complexes."""
    result = await db.execute(text(
        "SELECT c.id, c.name, d.name as developer, c.location, c.status, c.delivery_date "
        "FROM complexes c LEFT JOIN developers d ON c.developer_id = d.id "
        "ORDER BY c.id"
    ))
    rows = result.fetchall()
    return [dict(row._mapping) for row in rows]


@router.get("/{complex_id}")
async def get_complex(complex_id: int, db: AsyncSession = Depends(get_db)):
    """Get complex details with apartments."""
    # Complex info
    result = await db.execute(
        text(
            "SELECT c.id, c.name, d.name as developer, c.location, c.status, c.delivery_date "
            "FROM complexes c LEFT JOIN developers d ON c.developer_id = d.id "
            "WHERE c.id = :cid"
        ),
        {"cid": complex_id},
    )
    row = result.first()
    if not row:
        from fastapi import HTTPException
        raise HTTPException(status_code=404, detail="Complex not found")

    complex_data = dict(row._mapping)

    # Apartments
    apt_result = await db.execute(
        text(
            "SELECT apartment_type, area, price_total, price_per_sqm, floor, rooms, is_available "
            "FROM apartments WHERE complex_id = :cid ORDER BY apartment_type, area"
        ),
        {"cid": complex_id},
    )
    complex_data["apartments"] = [dict(r._mapping) for r in apt_result.fetchall()]

    return complex_data
