"""Health check endpoint."""

from fastapi import APIRouter
from audit_engine.db import check_db_health
from audit_engine.models import HealthResponse
from audit_engine import __version__

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse)
async def health_check():
    """Check API and database health."""
    db_health = await check_db_health()
    return HealthResponse(
        status="ok" if db_health["status"] == "healthy" else "degraded",
        version=__version__,
        db_status=db_health["status"],
        tables_count=db_health.get("tables_count", 0),
    )
