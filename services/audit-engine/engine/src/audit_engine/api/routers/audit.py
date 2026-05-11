"""Audit endpoints — main business logic."""

from __future__ import annotations
import asyncio
import json
import logging
import time
import uuid
from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException

logger = logging.getLogger(__name__)

# Fallback macro values used when `macro_economics` table is empty.
# These are deliberately conservative; surfaced in `audit.assumptions`
# so callers can see when a fallback was used instead of fresh data.
_FALLBACK_KEY_RATE = 15.0
_FALLBACK_INFLATION = 5.9
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text

from audit_engine.api.deps import get_db
from audit_engine.config import settings
from audit_engine.metrics import (
    MC_CACHE_HITS,
    MC_DURATION,
    MC_SIMS_TOTAL,
    size_bucket,
)
from audit_engine.competitor_analyzer import analyze as analyze_competitors
from audit_engine.competitor_collector import (
    fetch_competitors_by_complex,
    fetch_competitors_by_radius,
)
from audit_engine.location_scorer import score_location
from audit_engine.models import (
    AuditInput,
    AuditRequest,
    AuditResult,
    CompetitorAnalysis,
    LocationScore,
    MonteCarloSummary,
    MultiOfferMCResult,
    RetroResult,
    WhatIfResult,
)
from audit_engine.multi_offer_mc import run_monte_carlo_all_offers
from audit_engine.scenario_builder import run_full_audit
from audit_engine.monte_carlo import run_monte_carlo
from audit_engine.monte_carlo_fast import MonteCarloSimulatorFast
from audit_engine.mc_storage import (
    save_monte_carlo_run,
    save_multi_offer_run,
    get_monte_carlo_history,
    get_latest_monte_carlo,
    get_multi_offer_latest,
    mc_cache_get,
    mc_cache_key,
    mc_cache_put,
)
from audit_engine.retro_analyzer import RetroAnalyzerV2
from audit_engine.services.sensitivity import (
    by_mortgage_rate as sens_by_mortgage_rate,
    by_price_growth as sens_by_price_growth,
    find_breakeven_rate,
    grid_2d as sens_grid_2d,
)
from audit_engine.services.comparison import (
    MAX_COMPARE,
    load_audits as load_comparison_audits,
    rank_by_best_ei,
    winning_audit,
)
from dataclasses import asdict
from pydantic import BaseModel, Field

router = APIRouter(prefix="/audit", tags=["audit"])

# Bounded concurrency for off-loaded MC runs — prevents threadpool starvation
# if many clients request N > mc_async_threshold in parallel.
_MC_OFFLOAD_SEM = asyncio.Semaphore(settings.mc_async_concurrency)


def _build_audit_input(req: AuditRequest, macro: dict | None = None) -> AuditInput:
    """Build AuditInput from request + optional macro fallback."""
    m = macro or {}
    key_rate = float(m.get("cbr_key_rate", _FALLBACK_KEY_RATE) or _FALLBACK_KEY_RATE)
    inflation = float(m.get("inflation_annual", _FALLBACK_INFLATION) or _FALLBACK_INFLATION)

    return AuditInput(
        complex_name=req.complex_name,
        apartment_type=req.apartment_type,
        area_sqm=req.area_sqm,
        price_total=req.price_total,
        monthly_rent=req.monthly_rent,
        mortgage_rate=req.mortgage_rate or (key_rate + 2.0),
        mortgage_term_years=req.mortgage_term_years,
        down_payment_pct=req.down_payment_pct,
        deposit_rate=req.deposit_rate or (key_rate - 1.0),
        price_growth_annual=req.price_growth_annual or (inflation + 2.0),
        horizon_years=req.horizon_years,
        cash_discount_pct=req.cash_discount_pct,
    )


async def _get_latest_macro(db: AsyncSession) -> dict | None:
    """Fetch latest macro data from DB."""
    result = await db.execute(
        text(
            "SELECT cbr_key_rate, inflation_annual FROM macro_economics "
            "ORDER BY date DESC LIMIT 1"
        )
    )
    row = result.first()
    if row:
        return dict(row._mapping)
    return None


@router.post("/", response_model=AuditResult)
async def run_audit(req: AuditRequest, db: AsyncSession = Depends(get_db)):
    """
    Run a full audit: 3×3 scenario matrix + optional Monte-Carlo simulation.

    If mortgage_rate/deposit_rate/price_growth are not provided,
    they are derived from the latest macro data in the database.
    """
    # Get macro for defaults
    macro = await _get_latest_macro(db)
    if macro is None:
        logger.warning(
            "macro_economics table empty — using fallback (key_rate=%.1f%%, "
            "inflation=%.1f%%). Results may be off by ±15%%. Ask financial-scout "
            "to POST fresh data.",
            _FALLBACK_KEY_RATE, _FALLBACK_INFLATION,
        )
    input_data = _build_audit_input(req, macro)

    # Run deterministic 3×3 audit
    inflation = (macro or {}).get("inflation_annual", 8.0) or 8.0
    audit_result = run_full_audit(input_data, inflation=float(inflation))

    # Surface fallback usage in the response so consumers (re-analyst,
    # audit-reporter) can flag the audit as tentative.
    if macro is None:
        audit_result.assumptions = (audit_result.assumptions or []) + [
            f"Макро-данные отсутствуют; использованы fallback-значения "
            f"(ЦБ={_FALLBACK_KEY_RATE}%, инфляция={_FALLBACK_INFLATION}%). "
            f"Точность ±15%; обновите macro_economics для более надёжных цифр."
        ]

    # Run Monte-Carlo if requested
    if req.run_monte_carlo:
        mc_result = run_monte_carlo(
            input_data,
            num_simulations=req.mc_simulations,
        )
        audit_result.monte_carlo = mc_result

    # Persist id so clients can reference this audit later, even if DB save
    # fails (the record just won't be retrievable — but the UUID is stable).
    audit_id = str(uuid.uuid4())
    audit_result.id = audit_id

    # Save to database
    try:
        mc_buy_prob = None
        mc_mean_ei = None
        if audit_result.monte_carlo:
            best_strategy = audit_result.monte_carlo.recommended_strategy
            mc_obj = getattr(audit_result.monte_carlo, best_strategy)
            mc_buy_prob = mc_obj.buy_probability
            mc_mean_ei = mc_obj.ei_mean

        await db.execute(
            text(
                "INSERT INTO audit_archive "
                "(id, object_address, apartment_type, area_sqm, audit_date, "
                "price_total, price_per_sqm, mortgage_rate, deposit_rate, "
                "down_payment_pct, mortgage_term_years, monthly_rent, "
                "price_growth_annual, horizon_years, cash_discount_pct, "
                "input_params, ei_cash, ei_deposit, ei_mortgage, "
                "engine_version, verdict, verdict_explanation, "
                "risks, assumptions, monte_carlo_buy_prob, monte_carlo_mean_ei) "
                "VALUES (:id, :addr, :apt, :area, :ad, "
                ":pt, :ppsm, :mr, :dr, :dpp, :mty, :rent, "
                ":pga, :hy, :cdp, "
                "CAST(:params AS jsonb), :ec, :ed, :em, "
                ":ev, :v, :ve, :risks, :assumptions, :mcbp, :mcme)"
            ),
            {
                "id": audit_id,
                "addr": input_data.complex_name,
                "apt": input_data.apartment_type,
                "area": input_data.area_sqm,
                "ad": date.today(),
                "pt": input_data.price_total,
                "ppsm": round(input_data.price_total / input_data.area_sqm, 2),
                "mr": input_data.mortgage_rate,
                "dr": input_data.deposit_rate,
                "dpp": input_data.down_payment_pct,
                "mty": input_data.mortgage_term_years,
                "rent": input_data.monthly_rent,
                "pga": input_data.price_growth_annual,
                "hy": input_data.horizon_years,
                "cdp": input_data.cash_discount_pct,
                "params": json.dumps(input_data.model_dump()),
                "ec": audit_result.ei_cash,
                "ed": audit_result.ei_deposit,
                "em": audit_result.ei_mortgage,
                "ev": "2.0.0",
                "v": audit_result.verdict.value,
                "ve": audit_result.verdict_explanation,
                "risks": json.dumps(audit_result.risks),
                "assumptions": json.dumps(audit_result.assumptions),
                "mcbp": mc_buy_prob,
                "mcme": mc_mean_ei,
            },
        )

        # Save MC runs
        if audit_result.monte_carlo:
            for strategy_name in ["cash", "mortgage", "deposit"]:
                mc = getattr(audit_result.monte_carlo, strategy_name)
                await db.execute(
                    text(
                        "INSERT INTO monte_carlo_runs "
                        "(audit_id, num_simulations, ei_mean, ei_median, "
                        "ei_p5, ei_p25, ei_p75, ei_p95, ei_std, "
                        "buy_probability, distribution_data, params, strategy) "
                        "VALUES (:aid, :ns, :mean, :med, "
                        ":p5, :p25, :p75, :p95, :std, "
                        ":bp, CAST(:dd AS jsonb), CAST(:p AS jsonb), :s)"
                    ),
                    {
                        "aid": audit_id,
                        "ns": mc.num_simulations,
                        "mean": mc.ei_mean,
                        "med": mc.ei_median,
                        "p5": mc.ei_p5,
                        "p25": mc.ei_p25,
                        "p75": mc.ei_p75,
                        "p95": mc.ei_p95,
                        "std": mc.ei_std,
                        "bp": mc.buy_probability,
                        "dd": json.dumps(mc.distribution_data),
                        "p": json.dumps(input_data.model_dump()),
                        "s": strategy_name,
                    },
                )
    except Exception as e:
        # Log but don't fail the request — audit result is already computed
        import logging
        logging.warning(f"Failed to save audit to DB: {e}")

    audit_result.id = audit_id
    return audit_result


@router.get("/{audit_id}")
async def get_audit(audit_id: str, db: AsyncSession = Depends(get_db)):
    """Get a previously saved audit by ID."""
    result = await db.execute(
        text("SELECT * FROM audit_archive WHERE id = CAST(:aid AS uuid)"),
        {"aid": audit_id},
    )
    row = result.first()
    if not row:
        raise HTTPException(status_code=404, detail="Audit not found")
    return dict(row._mapping)


@router.get("/")
async def list_audits(
    skip: int = 0,
    limit: int = 20,
    db: AsyncSession = Depends(get_db),
):
    """List audits with pagination."""
    result = await db.execute(
        text(
            "SELECT id, object_address, apartment_type, area_sqm, audit_date, "
            "price_total, ei_cash, ei_deposit, ei_mortgage, verdict, engine_version, "
            "monte_carlo_buy_prob, monte_carlo_mean_ei "
            "FROM audit_archive ORDER BY created_at DESC "
            "LIMIT :lim OFFSET :off"
        ),
        {"lim": limit, "off": skip},
    )
    rows = result.fetchall()
    return [dict(r._mapping) for r in rows]


# ==================================================================
# Monte-Carlo endpoints
# ==================================================================

async def _load_audit_input(db: AsyncSession, audit_id: str) -> AuditInput:
    """Восстановить AuditInput из сохранённого аудита."""
    result = await db.execute(
        text(
            "SELECT input_params FROM audit_archive "
            "WHERE id = CAST(:aid AS uuid)"
        ),
        {"aid": audit_id},
    )
    row = result.first()
    if not row:
        raise HTTPException(status_code=404, detail="Audit not found")
    params = row._mapping["input_params"]
    if isinstance(params, str):
        params = json.loads(params)
    return AuditInput(**params)


@router.post("/{audit_id}/monte-carlo", response_model=MonteCarloSummary)
async def run_monte_carlo_for_audit(
    audit_id: str,
    num_simulations: int = settings.mc_default_simulations,
    seed: Optional[int] = None,
    db: AsyncSession = Depends(get_db),
):
    """Запустить vectorized MC-симуляцию для существующего аудита.

    * Дефолт — `settings.mc_default_simulations` (100k).
    * Потолок — `settings.mc_max_simulations` (413 при превышении).
    * При `N > mc_async_threshold` (200k) расчёт уезжает в threadpool
      под семафором, чтобы не блокировать event-loop.
    * Повторный вызов с тем же `(audit_id, N, seed)` — кеш-хит, без повторного
      прогона.
    """
    if num_simulations > settings.mc_max_simulations:
        raise HTTPException(
            status_code=413,
            detail=(
                f"num_simulations={num_simulations} exceeds ceiling "
                f"{settings.mc_max_simulations}"
            ),
        )

    input_data = await _load_audit_input(db, audit_id)

    rho = float(settings.mc_correlation_mortgage_deposit)
    cache_key = mc_cache_key(audit_id, num_simulations, seed, rho)
    cached = await mc_cache_get(cache_key)
    if cached is not None:
        MC_CACHE_HITS.inc()
        return cached

    sim = MonteCarloSimulatorFast(input_data, num_simulations, seed)

    bucket = size_bucket(num_simulations)
    start = time.perf_counter()
    if num_simulations > settings.mc_async_threshold:
        async with _MC_OFFLOAD_SEM:
            summary = await asyncio.to_thread(sim.run_vectorized)
    else:
        summary = sim.run_vectorized()
    elapsed = time.perf_counter() - start

    for strategy_name in ("cash", "mortgage", "deposit"):
        MC_DURATION.labels(strategy=strategy_name, size_bucket=bucket).observe(elapsed)
        MC_SIMS_TOTAL.labels(strategy=strategy_name).inc(num_simulations)

    await mc_cache_put(cache_key, summary)

    try:
        await save_monte_carlo_run(db, audit_id, summary, params=input_data)
    except Exception as e:
        import logging
        logging.warning(f"Failed to persist MC run for {audit_id}: {e}")

    return summary


@router.post(
    "/{audit_id}/compare-offers",
    response_model=MultiOfferMCResult,
)
async def compare_offers_for_audit(
    audit_id: str,
    num_simulations: int = settings.mc_default_simulations,
    seed: Optional[int] = None,
    limit: int = 20,
    db: AsyncSession = Depends(get_db),
):
    """Multi-offer MC: прогоняет MC по каждому подходящему банковскому офферу.

    Параметры:
    * `num_simulations` — число симуляций на оффер (default 100k, ceiling 1M).
    * `seed` — общий seed для воспроизводимости; один и тот же «мир» раскручен
      для всех офферов, чтобы сравнение было корректным.
    * `limit` — top-N офферов по минимальной ставке (default 20).

    Результат содержит `per_offer` — метрики по каждому, `recommended_*` —
    лучший по `ei_mortgage_median`, и `skipped_ineligible` — сколько офферов
    не прошли eligibility-фильтр.
    """
    if num_simulations > settings.mc_max_simulations:
        raise HTTPException(
            status_code=413,
            detail=(
                f"num_simulations={num_simulations} exceeds ceiling "
                f"{settings.mc_max_simulations}"
            ),
        )

    input_data = await _load_audit_input(db, audit_id)

    bucket = size_bucket(num_simulations)
    start = time.perf_counter()
    async with _MC_OFFLOAD_SEM:
        result = await run_monte_carlo_all_offers(
            db,
            input_data,
            audit_id=audit_id,
            num_simulations=num_simulations,
            seed=seed,
            limit=limit,
        )
    elapsed = time.perf_counter() - start

    # Учитываем совокупную длительность (все офферы * все стратегии) —
    # метрика агрегированная, а не per-offer.
    if result.num_offers > 0:
        MC_DURATION.labels(strategy="multi_offer", size_bucket=bucket).observe(elapsed)
        MC_SIMS_TOTAL.labels(strategy="multi_offer").inc(
            num_simulations * result.num_offers
        )

    try:
        await save_multi_offer_run(db, audit_id, result)
    except Exception as e:
        import logging
        logging.warning(f"Failed to persist multi-offer MC for {audit_id}: {e}")

    return result


@router.get(
    "/{audit_id}/compare-offers",
    response_model=MultiOfferMCResult,
)
async def get_latest_compare_offers(
    audit_id: str,
    db: AsyncSession = Depends(get_db),
):
    """Последний сохранённый multi-offer MC для аудита (если был)."""
    latest = await get_multi_offer_latest(db, audit_id)
    if latest is None:
        raise HTTPException(
            status_code=404,
            detail="No multi-offer MC runs found for this audit",
        )
    return latest


@router.get("/{audit_id}/monte-carlo")
async def get_monte_carlo_results(
    audit_id: str,
    history: bool = False,
    db: AsyncSession = Depends(get_db),
):
    """Получить результаты MC для аудита.

    `history=false` (по умолчанию) — последний запуск (3 стратегии).
    `history=true` — полная история всех запусков.
    """
    if history:
        return await get_monte_carlo_history(db, audit_id)

    latest = await get_latest_monte_carlo(db, audit_id)
    if latest is None:
        raise HTTPException(
            status_code=404,
            detail="No Monte-Carlo runs found for this audit",
        )
    return latest


# ==================================================================
# Location scoring (Phase D)
# ==================================================================

@router.get(
    "/{audit_id}/location-score",
    response_model=LocationScore,
)
async def get_audit_location_score(
    audit_id: str,
    radius_km: float = 2.0,
    db: AsyncSession = Depends(get_db),
):
    """Локационный скор для координат аудита.

    Читает `lat/lon` из `audit_archive.input_params`. Возвращает
    ближайшие POI по типам + общую оценку ∈ [0, 1].
    """
    input_data = await _load_audit_input(db, audit_id)
    if input_data.lat is None or input_data.lon is None:
        raise HTTPException(
            status_code=400,
            detail="Audit has no lat/lon; cannot compute location score",
        )
    return await score_location(db, input_data.lat, input_data.lon, radius_km=radius_km)


# ==================================================================
# Competitor analysis (Phase E)
# ==================================================================

@router.get(
    "/{audit_id}/competitors",
    response_model=CompetitorAnalysis,
)
async def get_audit_competitors(
    audit_id: str,
    radius_m: int = 2000,
    days_back: int = 90,
    db: AsyncSession = Depends(get_db),
):
    """Конкурентный анализ аудита.

    Если у аудита есть lat/lon — ищем компы в радиусе `radius_m` метров;
    иначе — по названию ЖК за последние `days_back` дней. Возвращаем
    перцентиль цены, сигнал (OVERPAY/FAIR/UNDERPAY/INSUFFICIENT) и top-5
    ближайших по цене объявлений.
    """
    if radius_m <= 0 or radius_m > 50_000:
        raise HTTPException(status_code=400, detail="radius_m out of range (1..50000)")
    if days_back <= 0 or days_back > 365:
        raise HTTPException(status_code=400, detail="days_back out of range (1..365)")

    input_data = await _load_audit_input(db, audit_id)
    audit_price_per_sqm = input_data.price_total / input_data.area_sqm

    if input_data.lat is not None and input_data.lon is not None:
        competitors = await fetch_competitors_by_radius(
            db, input_data.lat, input_data.lon,
            radius_m=radius_m, days_back=days_back,
        )
    else:
        competitors = await fetch_competitors_by_complex(
            db, input_data.complex_name, days_back=days_back,
        )

    from audit_engine.hedonic import apartment_type_to_rooms

    return analyze_competitors(
        audit_price_per_sqm=audit_price_per_sqm,
        competitors=competitors,
        radius_m=radius_m,
        target_rooms=apartment_type_to_rooms(input_data.apartment_type),
        target_area_sqm=input_data.area_sqm,
    )


# ==================================================================
# Retro / What-If endpoints
# ==================================================================

@router.get("/{audit_id}/retro", response_model=RetroResult)
async def get_retro_analysis(
    audit_id: str,
    db: AsyncSession = Depends(get_db),
):
    """Ретроспективный анализ для аудита (подгружает историю цен из БД)."""
    input_data = await _load_audit_input(db, audit_id)
    analyzer = RetroAnalyzerV2(db)
    return await analyzer.analyze_with_db(input_data)


@router.get("/{audit_id}/what-if", response_model=list[WhatIfResult])
async def what_if(
    audit_id: str,
    years_back: str = "1,2,3,5",
    db: AsyncSession = Depends(get_db),
):
    """«Что, если бы купили N лет назад» для каждого N из `years_back`."""
    try:
        years_list = [int(y.strip()) for y in years_back.split(",") if y.strip()]
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail="years_back must be comma-separated integers, e.g. '1,2,3,5'",
        )
    if not years_list:
        raise HTTPException(status_code=400, detail="years_back is empty")

    input_data = await _load_audit_input(db, audit_id)
    analyzer = RetroAnalyzerV2(db)
    return await analyzer.what_if_analysis(input_data, years_list)


# ==================================================================
# Sensitivity endpoints (D2 — Полу-v2.1)
# ==================================================================


class SensitivityRequest(BaseModel):
    """Параметры для анализа чувствительности.

    Хотя бы одно из `mortgage_rates` / `price_growth_rates` должно быть задано.
    Если оба — рендерится 2D-сетка для heatmap.
    """
    mortgage_rates: list[float] | None = Field(
        default=None,
        description="Список ставок ипотеки в %/год, например [4, 6, 8, 10, 12, 14, 16, 18, 20]",
    )
    price_growth_rates: list[float] | None = Field(
        default=None,
        description="Список годового роста цен в %, например [3, 5, 7, 10, 12]",
    )
    include_breakeven: bool = Field(
        default=True,
        description="Добавить ли в ответ ставку безубыточности (EI=1.0)",
    )


@router.post("/sensitivity")
async def audit_sensitivity_ad_hoc(
    payload: AuditInput,
    spec: SensitivityRequest,
):
    """Ad-hoc sensitivity: принимает свежий AuditInput, не требует сохранённого id.

    Удобно для UI-калькулятора, где пользователь вертит ставки до сохранения аудита.
    """
    return _build_sensitivity_response(payload, spec)


@router.post("/{audit_id}/sensitivity")
async def audit_sensitivity_by_id(
    audit_id: str,
    spec: SensitivityRequest,
    db: AsyncSession = Depends(get_db),
):
    """Sensitivity-таблицы для уже сохранённого аудита."""
    input_data = await _load_audit_input(db, audit_id)
    return _build_sensitivity_response(input_data, spec)


# ==================================================================
# Comparison endpoint (D3 — Полу-v2.1)
# ==================================================================


class CompareRequest(BaseModel):
    ids: list[str] = Field(
        min_length=2,
        max_length=MAX_COMPARE,
        description=f"2..{MAX_COMPARE} audit_id для сравнения",
    )
    format: str = Field(default="json", description="json | markdown")


@router.post("/compare")
async def audit_compare(
    spec: CompareRequest,
    db: AsyncSession = Depends(get_db),
):
    """Сравнение 2-3 сохранённых аудитов.

    `format=json` → таблица + winner + ранжирование.
    `format=markdown` → ещё и Markdown-отчёт (готов к pdf_branded).
    """
    rows = await load_comparison_audits(db, spec.ids)
    if len(rows) < 2:
        raise HTTPException(
            status_code=404,
            detail=f"Найдено {len(rows)} из {len(spec.ids)} аудитов — нужно минимум 2",
        )

    ranked = rank_by_best_ei(rows)
    winner = winning_audit(rows)

    response: dict = {
        "count": len(rows),
        "rows": [asdict(r) for r in rows],
        "ranked": [asdict(r) for r in ranked],
        "winner_id": winner.audit_id if winner else None,
    }

    if spec.format == "markdown":
        from datetime import date

        from jinja2 import Environment, FileSystemLoader
        from pathlib import Path

        templates_dir = Path(__file__).resolve().parents[3] / "templates"
        env = Environment(
            loader=FileSystemLoader(str(templates_dir)),
            trim_blocks=False,
            lstrip_blocks=False,
        )
        tpl = env.get_template("comparison.md.j2")
        response["markdown"] = tpl.render(
            rows=ranked,
            winner=winner,
            report_date=date.today().isoformat(),
        )

    return response


def _build_sensitivity_response(input_data: AuditInput, spec: SensitivityRequest) -> dict:
    if not spec.mortgage_rates and not spec.price_growth_rates:
        raise HTTPException(
            status_code=400,
            detail="Хотя бы одно из mortgage_rates/price_growth_rates обязательно",
        )
    out: dict = {
        "base": {
            "mortgage_rate": input_data.mortgage_rate,
            "price_growth_annual": input_data.price_growth_annual,
            "horizon_years": input_data.horizon_years,
        }
    }
    if spec.mortgage_rates and spec.price_growth_rates:
        grid = sens_grid_2d(input_data, spec.mortgage_rates, spec.price_growth_rates)
        out["grid_2d"] = {
            "axis_mortgage_rate": list(spec.mortgage_rates),
            "axis_price_growth": list(spec.price_growth_rates),
            "cells": [[asdict(c) for c in row] for row in grid],
        }
    elif spec.mortgage_rates:
        cells = sens_by_mortgage_rate(input_data, spec.mortgage_rates)
        out["by_mortgage_rate"] = [asdict(c) for c in cells]
    else:
        cells = sens_by_price_growth(input_data, spec.price_growth_rates)
        out["by_price_growth"] = [asdict(c) for c in cells]

    if spec.include_breakeven:
        out["breakeven_mortgage_rate"] = find_breakeven_rate(input_data)

    return out
