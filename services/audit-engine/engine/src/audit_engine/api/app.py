"""
FastAPI Application — Audit Engine v2.0 API.

СОДИКС ИТ-Департамент
"""

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from audit_engine import __version__
from audit_engine.api.auth import AuthMiddleware, is_auth_enabled
from audit_engine.api.routers import (
    audit,
    bank_offers,
    complexes,
    developers,
    geo,
    health,
    jobs,
    location,
    macro,
    price_history,
    search,
)
from audit_engine.jobs.scheduler import shutdown_scheduler, start_scheduler

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: запускаем APScheduler. Shutdown: гасим его."""
    try:
        start_scheduler()
    except Exception:
        logger.exception("scheduler failed to start; API запустится без него")
    yield
    try:
        shutdown_scheduler()
    except Exception:
        logger.exception("scheduler shutdown error")


app = FastAPI(
    title="СОДИКС Audit Engine",
    description="Real Estate Efficiency Index (EI) Calculator with Monte-Carlo Simulation",
    version=__version__,
    docs_url="/api/v2/docs",
    openapi_url="/api/v2/openapi.json",
    lifespan=lifespan,
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# E2 — Bearer token auth + per-token rate limit
# Включается только если AUDIT_API_TOKENS задан в env. См. api/auth.py
app.add_middleware(AuthMiddleware)
if is_auth_enabled():
    logger.info("Auth ENABLED (X-Audit-Token / Bearer required)")
else:
    logger.info("Auth DISABLED (AUDIT_API_TOKENS пуст — backwards-compat режим)")

# Mount routers under /api/v2
app.include_router(health.router, prefix="/api/v2")
app.include_router(audit.router, prefix="/api/v2")
app.include_router(macro.router, prefix="/api/v2")
app.include_router(complexes.router, prefix="/api/v2")
app.include_router(price_history.router, prefix="/api/v2")
app.include_router(bank_offers.router, prefix="/api/v2")
app.include_router(location.router, prefix="/api/v2")
app.include_router(geo.router, prefix="/api/v2")
app.include_router(jobs.router, prefix="/api/v2")
app.include_router(developers.router, prefix="/api/v2")
app.include_router(search.router, prefix="/api/v2")


@app.get("/")
async def root():
    """Root endpoint with API info."""
    return {
        "name": "СОДИКС Audit Engine",
        "version": __version__,
        "docs": "/api/v2/docs",
        "health": "/api/v2/health",
    }
