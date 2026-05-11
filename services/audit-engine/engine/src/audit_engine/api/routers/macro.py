"""Macro economics endpoints."""

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

from audit_engine.api.deps import get_db
from audit_engine.models import MacroData

router = APIRouter(prefix="/macro", tags=["macro"])


@router.get("/latest", response_model=MacroData | None)
async def get_latest_macro(db: AsyncSession = Depends(get_db)):
    """Get latest macro economics data from DB."""
    result = await db.execute(
        text(
            "SELECT date, cbr_key_rate, inflation_annual, inflation_monthly, "
            "avg_deposit_rate, avg_mortgage_rate, ofz_yield_1y, ofz_yield_3y, "
            "ofz_yield_5y, source "
            "FROM macro_economics ORDER BY date DESC LIMIT 1"
        )
    )
    row = result.first()
    if not row:
        return None
    m = row._mapping
    return MacroData(
        date=str(m["date"]),
        cbr_key_rate=float(m["cbr_key_rate"]) if m["cbr_key_rate"] else None,
        inflation_annual=float(m["inflation_annual"]) if m["inflation_annual"] else None,
        inflation_monthly=float(m["inflation_monthly"]) if m["inflation_monthly"] else None,
        avg_deposit_rate=float(m["avg_deposit_rate"]) if m["avg_deposit_rate"] else None,
        avg_mortgage_rate=float(m["avg_mortgage_rate"]) if m["avg_mortgage_rate"] else None,
        ofz_yield_1y=float(m["ofz_yield_1y"]) if m["ofz_yield_1y"] else None,
        ofz_yield_3y=float(m["ofz_yield_3y"]) if m["ofz_yield_3y"] else None,
        ofz_yield_5y=float(m["ofz_yield_5y"]) if m["ofz_yield_5y"] else None,
        source=m["source"],
    )


@router.get("/history", response_model=list[MacroData])
async def get_macro_history(
    limit: int = 30,
    db: AsyncSession = Depends(get_db),
):
    """Get macro economics history."""
    result = await db.execute(
        text(
            "SELECT date, cbr_key_rate, inflation_annual, inflation_monthly, "
            "avg_deposit_rate, avg_mortgage_rate, ofz_yield_1y, ofz_yield_3y, "
            "ofz_yield_5y, source "
            "FROM macro_economics ORDER BY date DESC LIMIT :lim"
        ),
        {"lim": limit},
    )
    rows = result.fetchall()
    items = []
    for row in rows:
        m = row._mapping
        items.append(MacroData(
            date=str(m["date"]),
            cbr_key_rate=float(m["cbr_key_rate"]) if m["cbr_key_rate"] else None,
            inflation_annual=float(m["inflation_annual"]) if m["inflation_annual"] else None,
            inflation_monthly=float(m["inflation_monthly"]) if m["inflation_monthly"] else None,
            avg_deposit_rate=float(m["avg_deposit_rate"]) if m["avg_deposit_rate"] else None,
            avg_mortgage_rate=float(m["avg_mortgage_rate"]) if m["avg_mortgage_rate"] else None,
            ofz_yield_1y=float(m["ofz_yield_1y"]) if m["ofz_yield_1y"] else None,
            ofz_yield_3y=float(m["ofz_yield_3y"]) if m["ofz_yield_3y"] else None,
            ofz_yield_5y=float(m["ofz_yield_5y"]) if m["ofz_yield_5y"] else None,
            source=m["source"],
        ))
    return items
