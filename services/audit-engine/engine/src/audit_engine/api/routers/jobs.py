"""`/api/v2/jobs/...` — мониторинг и ручной запуск планировщика.

Эндпоинты:
- `GET /jobs/status` — список всех зарегистрированных job-ов + last run.
- `GET /jobs/history?job=...&limit=20` — последние N запусков.
- `POST /jobs/run/{job_name}` — синхронный запуск job-а (для отладки).

Стабильности ради read-only ручки не требуют авторизации. `run` идёт под
тем же auth-слоем, что и `audit/create` (см. E2 — пока stub).
"""
from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException, Query
from sqlalchemy import text

from audit_engine.db import get_session
from audit_engine.jobs.scheduler import JOBS, get_scheduler, run_job_now

router = APIRouter(prefix="/jobs", tags=["jobs"])


@router.get("/status")
async def jobs_status() -> dict[str, Any]:
    """Список job-ов с last_run_at / status / next_run_at."""
    scheduler = get_scheduler()
    next_runs: dict[str, str | None] = {}
    if scheduler is not None:
        for j in scheduler.get_jobs():
            next_runs[j.id] = j.next_run_time.isoformat() if j.next_run_time else None

    async with get_session() as session:
        result = await session.execute(
            text(
                "SELECT DISTINCT ON (job_name) job_name, started_at, finished_at, "
                "status, rows_affected, error "
                "FROM cron_runs "
                "ORDER BY job_name, started_at DESC"
            )
        )
        last_runs = {row[0]: dict(zip(
            ("job_name", "started_at", "finished_at", "status", "rows_affected", "error"),
            row,
        )) for row in result.fetchall()}

    jobs_out: list[dict[str, Any]] = []
    for spec in JOBS:
        last = last_runs.get(spec.name, {})
        jobs_out.append({
            "name": spec.name,
            "description": spec.description,
            "next_run_at": next_runs.get(spec.name),
            "last_run": {
                "started_at": (last.get("started_at").isoformat()
                               if last.get("started_at") else None),
                "finished_at": (last.get("finished_at").isoformat()
                                if last.get("finished_at") else None),
                "status": last.get("status"),
                "rows_affected": last.get("rows_affected"),
                "error": last.get("error"),
            } if last else None,
        })

    return {
        "scheduler_running": scheduler is not None and scheduler.running,
        "jobs": jobs_out,
    }


@router.get("/history")
async def jobs_history(
    job: str | None = Query(None, description="Фильтр по имени job-а"),
    limit: int = Query(20, ge=1, le=200),
) -> dict[str, Any]:
    """Последние N запусков (все job-ы или один)."""
    async with get_session() as session:
        if job:
            result = await session.execute(
                text(
                    "SELECT job_name, started_at, finished_at, status, "
                    "rows_affected, error FROM cron_runs "
                    "WHERE job_name = :job ORDER BY started_at DESC LIMIT :lim"
                ),
                {"job": job, "lim": limit},
            )
        else:
            result = await session.execute(
                text(
                    "SELECT job_name, started_at, finished_at, status, "
                    "rows_affected, error FROM cron_runs "
                    "ORDER BY started_at DESC LIMIT :lim"
                ),
                {"lim": limit},
            )
        rows = [
            {
                "job_name": r[0],
                "started_at": r[1].isoformat() if r[1] else None,
                "finished_at": r[2].isoformat() if r[2] else None,
                "status": r[3],
                "rows_affected": r[4],
                "error": r[5],
            }
            for r in result.fetchall()
        ]
    return {"count": len(rows), "runs": rows}


@router.post("/run/{job_name}")
async def jobs_run(job_name: str) -> dict[str, Any]:
    """Ручной синхронный запуск job-а. Удобно для тестов/смок-чеков."""
    valid = {j.name for j in JOBS}
    if job_name not in valid:
        raise HTTPException(404, detail=f"Unknown job: {job_name}. Valid: {sorted(valid)}")
    return await run_job_now(job_name)
