"""
Database layer for Audit Engine.

Provides async connection pool and CRUD operations.
"""

from __future__ import annotations
import os
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy import text

from audit_engine.config import settings


# Convert sync URL to async (postgresql:// → postgresql+asyncpg://)
_db_url = settings.database_url.replace(
    "postgresql://", "postgresql+asyncpg://"
)

engine = create_async_engine(_db_url, echo=False, pool_size=5, max_overflow=10)
async_session_factory = async_sessionmaker(engine, expire_on_commit=False)


@asynccontextmanager
async def get_session() -> AsyncGenerator[AsyncSession, None]:
    """Provide a transactional scope around a series of operations."""
    async with async_session_factory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


async def check_db_health() -> dict:
    """Check database connectivity and return status."""
    try:
        async with get_session() as session:
            result = await session.execute(text("SELECT 1"))
            row = result.scalar()
            
            # Count tables
            tables_result = await session.execute(text(
                "SELECT count(*) FROM information_schema.tables "
                "WHERE table_schema = 'public'"
            ))
            table_count = tables_result.scalar()
            
            return {
                "status": "healthy",
                "connection": "ok",
                "tables_count": table_count,
            }
    except Exception as e:
        return {
            "status": "unhealthy",
            "connection": "failed",
            "error": str(e),
        }


# ========================
# CRUD Operations
# ========================

async def insert_complex(name: str, developer_name: str, location: str = None) -> int:
    """Insert a new complex and return its id."""
    async with get_session() as session:
        # Ensure developer exists
        dev_result = await session.execute(
            text("SELECT id FROM developers WHERE name = :name"),
            {"name": developer_name},
        )
        dev_row = dev_result.first()
        if dev_row:
            dev_id = dev_row[0]
        else:
            result = await session.execute(
                text("INSERT INTO developers (name) VALUES (:name) RETURNING id"),
                {"name": developer_name},
            )
            dev_id = result.scalar()

        result = await session.execute(
            text(
                "INSERT INTO complexes (developer_id, name, location) "
                "VALUES (:dev_id, :name, :location) RETURNING id"
            ),
            {"dev_id": dev_id, "name": name, "location": location},
        )
        return result.scalar()


async def insert_price_snapshot(
    complex_id: int, apartment_type: str, area: float,
    price_total: float, price_per_sqm: float, source_url: str = None,
) -> int:
    """Insert a historical price record."""
    async with get_session() as session:
        result = await session.execute(
            text(
                "INSERT INTO historical_prices "
                "(complex_id, apartment_type, area, price_total, price_per_sqm, source_url) "
                "VALUES (:cid, :apt, :area, :pt, :ppsm, :url) RETURNING id"
            ),
            {
                "cid": complex_id, "apt": apartment_type, "area": area,
                "pt": price_total, "ppsm": price_per_sqm, "url": source_url,
            },
        )
        return result.scalar()


async def insert_macro(
    date_str: str, cbr_key_rate: float = None,
    inflation_annual: float = None, avg_deposit_rate: float = None,
    avg_mortgage_rate: float = None, source: str = None,
) -> int:
    """Insert macro economics data point."""
    async with get_session() as session:
        result = await session.execute(
            text(
                "INSERT INTO macro_economics "
                "(date, cbr_key_rate, inflation_annual, avg_deposit_rate, avg_mortgage_rate, source) "
                "VALUES (:d, :cbr, :inf, :dep, :mort, :src) "
                "ON CONFLICT (date) DO UPDATE SET "
                "cbr_key_rate = EXCLUDED.cbr_key_rate, "
                "inflation_annual = EXCLUDED.inflation_annual, "
                "avg_deposit_rate = EXCLUDED.avg_deposit_rate, "
                "avg_mortgage_rate = EXCLUDED.avg_mortgage_rate "
                "RETURNING id"
            ),
            {
                "d": date_str, "cbr": cbr_key_rate, "inf": inflation_annual,
                "dep": avg_deposit_rate, "mort": avg_mortgage_rate, "src": source,
            },
        )
        return result.scalar()


async def get_complexes() -> list[dict]:
    """Get all complexes."""
    async with get_session() as session:
        result = await session.execute(text(
            "SELECT c.id, c.name, d.name as developer, c.location, c.status "
            "FROM complexes c LEFT JOIN developers d ON c.developer_id = d.id "
            "ORDER BY c.id"
        ))
        return [dict(row._mapping) for row in result.fetchall()]


async def save_audit_result(
    complex_id: int, audit_date: str, apartment_type: str,
    target_area: float, target_price: float,
    ei_cash: float, ei_deposit: float, ei_mortgage: float,
    ei_optimistic: float, ei_realistic: float, ei_pessimistic: float,
    verdict: str, verdict_text: str, params: dict,
) -> int:
    """Save audit result to DB."""
    import json
    async with get_session() as session:
        result = await session.execute(
            text(
                "INSERT INTO audits "
                "(complex_id, audit_date, apartment_type, target_area, target_price, "
                "ei_cash, ei_deposit, ei_mortgage, "
                "ei_optimistic, ei_realistic, ei_pessimistic, "
                "verdict, verdict_text, params) "
                "VALUES (:cid, :ad, :apt, :ta, :tp, "
                ":ec, :ed, :em, :eo, :er, :ep, :v, :vt, CAST(:p AS jsonb)) "
                "RETURNING id"
            ),
            {
                "cid": complex_id, "ad": audit_date, "apt": apartment_type,
                "ta": target_area, "tp": target_price,
                "ec": ei_cash, "ed": ei_deposit, "em": ei_mortgage,
                "eo": ei_optimistic, "er": ei_realistic, "ep": ei_pessimistic,
                "v": verdict, "vt": verdict_text, "p": json.dumps(params),
            },
        )
        return result.scalar()
