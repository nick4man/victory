"""Storage layer for Monte-Carlo runs.

Схема `monte_carlo_runs`: одна строка на стратегию (cash / mortgage / deposit).
Т.е. одна MC-симуляция = 3 строки с общим `audit_id`.

Кеш идемпотентности: Redis LRU с TTL — при повторе с тем же ключом возвращаем
ранее посчитанный `MonteCarloSummary` без обращения к БД и без перезапуска симулятора.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from collections import OrderedDict
from typing import Optional
from uuid import UUID

import redis.asyncio as redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.config import settings
from audit_engine.models import (
    AuditInput,
    MonteCarloResult,
    MonteCarloSummary,
    MultiOfferMCResult,
)


logger = logging.getLogger(__name__)

# In-memory fallback caches (used when Redis is unavailable)
_MC_CACHE: OrderedDict[str, MonteCarloSummary] = OrderedDict()
_MC_CACHE_MAX = 256
_MULTI_OFFER_LATEST: OrderedDict[str, MultiOfferMCResult] = OrderedDict()
_MULTI_OFFER_LATEST_MAX = 256

# Redis client singleton
_redis_client: Optional[redis.Redis] = None
_REDIS_CONNECT_LOCK = asyncio.Lock()
_REDIS_AVAILABLE = True  # optimistic

# Key prefixes and TTLs
_MC_CACHE_PREFIX = "mc:cache:"
_MC_CACHE_TTL = 3600  # 1 hour
_MULTI_OFFER_PREFIX = "mc:multi_offer:"
_MULTI_OFFER_TTL = 1800  # 30 minutes


async def get_redis() -> Optional[redis.Redis]:
    """Get Redis client, connecting lazily."""
    global _redis_client, _REDIS_AVAILABLE
    if _redis_client is not None:
        return _redis_client
    async with _REDIS_CONNECT_LOCK:
        if _redis_client is not None:  # double-check
            return _redis_client
        try:
            _redis_client = redis.Redis.from_url(
                settings.redis_url, decode_responses=False
            )
            # Test connection
            await _redis_client.ping()
            logger.info("Redis cache connected")
            _REDIS_AVAILABLE = True
        except Exception as e:
            logger.warning(f"Redis cache unavailable: {e}, using in‑memory fallback")
            _REDIS_AVAILABLE = False
            _redis_client = None
    return _redis_client


def mc_cache_key(
    audit_id: UUID | str,
    num_simulations: int,
    seed: int | None,
    correlation: float,
) -> str:
    """Stable idempotency key: same inputs → same hash."""
    raw = f"{audit_id}|{num_simulations}|{seed}|{correlation:.6f}"
    return hashlib.sha256(raw.encode()).hexdigest()


async def mc_cache_get(key: str) -> Optional[MonteCarloSummary]:
    """Get MonteCarloSummary from cache (Redis primary, in‑memory fallback)."""
    global _REDIS_AVAILABLE
    # Try Redis first
    client = await get_redis()
    if client and _REDIS_AVAILABLE:
        try:
            data = await client.get(_MC_CACHE_PREFIX + key)
            if data:
                summary_dict = json.loads(data)
                # Convert dict to MonteCarloSummary
                # MonteCarloSummary expects three MonteCarloResult objects
                cash = MonteCarloResult(**summary_dict["cash"])
                mortgage = MonteCarloResult(**summary_dict["mortgage"])
                deposit = MonteCarloResult(**summary_dict["deposit"])
                return MonteCarloSummary(
                    cash=cash,
                    mortgage=mortgage,
                    deposit=deposit,
                    recommended_strategy=summary_dict["recommended_strategy"],
                    confidence_level=summary_dict["confidence_level"],
                )
        except Exception as e:
            logger.warning(f"Redis get failed: {e}, falling back to memory")
            _REDIS_AVAILABLE = False
    # Fallback to in‑memory cache
    value = _MC_CACHE.get(key)
    if value is not None:
        _MC_CACHE.move_to_end(key)
    return value


async def mc_cache_put(key: str, summary: MonteCarloSummary) -> None:
    """Store MonteCarloSummary in cache (Redis primary, in‑memory fallback)."""
    global _REDIS_AVAILABLE
    # Try Redis first
    client = await get_redis()
    if client and _REDIS_AVAILABLE:
        try:
            summary_dict = {
                "cash": summary.cash.model_dump(),
                "mortgage": summary.mortgage.model_dump(),
                "deposit": summary.deposit.model_dump(),
                "recommended_strategy": summary.recommended_strategy,
                "confidence_level": summary.confidence_level,
            }
            await client.setex(
                _MC_CACHE_PREFIX + key,
                _MC_CACHE_TTL,
                json.dumps(summary_dict),
            )
            # Success, also keep in‑memory cache for fast access within process
            _MC_CACHE[key] = summary
            _MC_CACHE.move_to_end(key)
            while len(_MC_CACHE) > _MC_CACHE_MAX:
                _MC_CACHE.popitem(last=False)
            return
        except Exception as e:
            logger.warning(f"Redis set failed: {e}, falling back to memory")
            _REDIS_AVAILABLE = False
    # Fallback to in‑memory only
    _MC_CACHE[key] = summary
    _MC_CACHE.move_to_end(key)
    while len(_MC_CACHE) > _MC_CACHE_MAX:
        _MC_CACHE.popitem(last=False)


def mc_cache_clear() -> None:
    """Clear the idempotency cache (used by tests)."""
    _MC_CACHE.clear()
    _MULTI_OFFER_LATEST.clear()
    # Also clear Redis keys with our prefixes (best effort, synchronous via asyncio)
    async def _clear_redis():
        client = await get_redis()
        if client and _REDIS_AVAILABLE:
            try:
                # Use scan_iter to delete keys by prefix
                keys = []
                async for k in client.scan_iter(match=_MC_CACHE_PREFIX + "*"):
                    keys.append(k)
                async for k in client.scan_iter(match=_MULTI_OFFER_PREFIX + "*"):
                    keys.append(k)
                if keys:
                    await client.delete(*keys)
            except Exception as e:
                logger.warning(f"Redis clear failed: {e}")
    try:
        loop = asyncio.get_event_loop()
        if loop.is_running():
            # Schedule but don't block
            asyncio.create_task(_clear_redis())
        else:
            loop.run_until_complete(_clear_redis())
    except RuntimeError:
        # No event loop, ignore
        pass


async def save_multi_offer_run(
    db: AsyncSession,  # noqa: ARG001 — reserved for JSONB persistence
    audit_id: UUID | str,
    result: MultiOfferMCResult,
) -> None:
    """Сохранить последний multi-offer MC-прогон для аудита.

    Redis primary with TTL, in‑memory fallback.
    """
    global _REDIS_AVAILABLE
    key = str(audit_id)
    # Try Redis
    client = await get_redis()
    if client and _REDIS_AVAILABLE:
        try:
            await client.setex(
                _MULTI_OFFER_PREFIX + key,
                _MULTI_OFFER_TTL,
                json.dumps(result.model_dump()),
            )
            # Keep in‑memory fallback
            _MULTI_OFFER_LATEST[key] = result
            _MULTI_OFFER_LATEST.move_to_end(key)
            while len(_MULTI_OFFER_LATEST) > _MULTI_OFFER_LATEST_MAX:
                _MULTI_OFFER_LATEST.popitem(last=False)
            return
        except Exception as e:
            logger.warning(f"Redis save multi-offer failed: {e}")
            _REDIS_AVAILABLE = False
    # Fallback to in‑memory only
    _MULTI_OFFER_LATEST[key] = result
    _MULTI_OFFER_LATEST.move_to_end(key)
    while len(_MULTI_OFFER_LATEST) > _MULTI_OFFER_LATEST_MAX:
        _MULTI_OFFER_LATEST.popitem(last=False)


async def get_multi_offer_latest(
    db: AsyncSession,  # noqa: ARG001 — reserved for JSONB persistence
    audit_id: UUID | str,
) -> Optional[MultiOfferMCResult]:
    """Получить последний multi-offer MC-прогон для аудита (или None)."""
    global _REDIS_AVAILABLE
    key = str(audit_id)
    # Try Redis
    client = await get_redis()
    if client and _REDIS_AVAILABLE:
        try:
            data = await client.get(_MULTI_OFFER_PREFIX + key)
            if data:
                result_dict = json.loads(data)
                # Update in‑memory cache for fast access
                result = MultiOfferMCResult(**result_dict)
                _MULTI_OFFER_LATEST[key] = result
                _MULTI_OFFER_LATEST.move_to_end(key)
                while len(_MULTI_OFFER_LATEST) > _MULTI_OFFER_LATEST_MAX:
                    _MULTI_OFFER_LATEST.popitem(last=False)
                return result
        except Exception as e:
            logger.warning(f"Redis get multi-offer failed: {e}")
            _REDIS_AVAILABLE = False
    # Fallback to in‑memory cache
    value = _MULTI_OFFER_LATEST.get(key)
    if value is not None:
        _MULTI_OFFER_LATEST.move_to_end(key)
    return value


async def save_monte_carlo_run(
    db: AsyncSession,
    audit_id: UUID | str,
    mc_summary: MonteCarloSummary,
    params: AuditInput | dict | None = None,
) -> list[UUID]:
    """Сохранить результаты MC для всех 3 стратегий в `monte_carlo_runs`.

    Returns: список UUID вставленных записей (в порядке cash, mortgage, deposit).
    """
    params_json = None
    if params is not None:
        params_json = json.dumps(
            params.model_dump() if hasattr(params, "model_dump") else params
        )

    inserted: list[UUID] = []
    for strategy_name in ("cash", "mortgage", "deposit"):
        mc: MonteCarloResult = getattr(mc_summary, strategy_name)
        result = await db.execute(
            text(
                "INSERT INTO monte_carlo_runs "
                "(audit_id, num_simulations, ei_mean, ei_median, "
                " ei_p5, ei_p25, ei_p75, ei_p95, ei_std, buy_probability, "
                " distribution_data, params, strategy) "
                "VALUES (:aid, :ns, :mean, :med, "
                " :p5, :p25, :p75, :p95, :std, :bp, "
                " CAST(:dd AS jsonb), CAST(:p AS jsonb), :s) "
                "RETURNING id"
            ),
            {
                "aid": str(audit_id),
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
                "p": params_json,
                "s": strategy_name,
            },
        )
        inserted.append(result.scalar())
    return inserted


async def get_monte_carlo_history(
    db: AsyncSession,
    audit_id: UUID | str,
) -> list[dict]:
    """Получить все MC-запуски для аудита (все стратегии, по убыванию даты)."""
    result = await db.execute(
        text(
            "SELECT id, strategy, num_simulations, ei_mean, ei_median, "
            " ei_p5, ei_p25, ei_p75, ei_p95, ei_std, buy_probability, "
            " distribution_data, created_at "
            "FROM monte_carlo_runs "
            "WHERE audit_id = CAST(:aid AS uuid) "
            "ORDER BY created_at DESC, strategy"
        ),
        {"aid": str(audit_id)},
    )
    return [dict(row._mapping) for row in result.fetchall()]


async def get_latest_monte_carlo(
    db: AsyncSession,
    audit_id: UUID | str,
) -> dict | None:
    """Собрать последнюю MC-симуляцию в форму, близкую к `MonteCarloSummary`.

    Возвращает dict вида `{cash: {...}, mortgage: {...}, deposit: {...}, created_at}`.
    Если записей нет — None.
    """
    result = await db.execute(
        text(
            "SELECT DISTINCT ON (strategy) "
            " strategy, num_simulations, ei_mean, ei_median, "
            " ei_p5, ei_p25, ei_p75, ei_p95, ei_std, buy_probability, "
            " distribution_data, created_at "
            "FROM monte_carlo_runs "
            "WHERE audit_id = CAST(:aid AS uuid) "
            "ORDER BY strategy, created_at DESC"
        ),
        {"aid": str(audit_id)},
    )
    rows = [dict(r._mapping) for r in result.fetchall()]
    if not rows:
        return None

    by_strategy = {r["strategy"]: r for r in rows}
    if not {"cash", "mortgage", "deposit"}.issubset(by_strategy):
        return None

    latest_created_at = max(r["created_at"] for r in rows)
    return {
        "cash": by_strategy["cash"],
        "mortgage": by_strategy["mortgage"],
        "deposit": by_strategy["deposit"],
        "created_at": latest_created_at,
    }