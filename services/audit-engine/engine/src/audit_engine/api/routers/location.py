"""Плоский endpoint локационного скоринга по произвольным координатам.

Нужен для превью в UI: пользователь двигает точку на карте — мгновенно
видит скор, не создавая аудит.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.api.deps import get_db
from audit_engine.location_scorer import score_location
from audit_engine.models import LocationScore

router = APIRouter(prefix="/location", tags=["location"])


@router.get("/score", response_model=LocationScore)
async def location_score(
    lat: float = Query(..., ge=-90.0, le=90.0),
    lon: float = Query(..., ge=-180.0, le=180.0),
    radius_km: float = Query(2.0, gt=0.0, le=20.0),
    db: AsyncSession = Depends(get_db),
):
    """Скор для произвольной точки (без привязки к аудиту)."""
    if radius_km <= 0:
        raise HTTPException(status_code=400, detail="radius_km must be positive")
    return await score_location(db, lat, lon, radius_km=radius_km)
