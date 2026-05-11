#!/usr/bin/env python3
"""
Monte-Carlo Worker — GPU‑ускоренный воркер для фоновых симуляций.

Слушает Redis канал 'mc_tasks', получает параметры аудита (audit_id),
запускает Monte‑Carlo симуляцию (на GPU, если доступно, иначе на CPU),
сохраняет результат в БД (monte_carlo_runs).

Автодетект GPU: пытается импортировать cupy, падает на numpy.
Переменная окружения MC_USE_GPU=true/false принудительно выбирает режим.
"""

from __future__ import annotations
import asyncio
import json
import logging
import os
import sys
from typing import Optional

import redis.asyncio as redis
from sqlalchemy import text

from audit_engine.db import get_session
from audit_engine.models import AuditInput, MonteCarloSummary
from audit_engine.config import settings

# Определяем, использовать ли GPU
MC_USE_GPU = os.getenv("MC_USE_GPU", "true").lower() == "true"
try:
    if MC_USE_GPU:
        import cupy as np
        GPU_AVAILABLE = True
        logging.info("Using CuPy for GPU acceleration")
    else:
        raise ImportError("MC_USE_GPU is false, forcing CPU")
except ImportError:
    import numpy as np
    GPU_AVAILABLE = False
    logging.info("CuPy not available, using NumPy (CPU)")

# Импортируем симулятор
from audit_engine.monte_carlo_fast import MonteCarloSimulatorFast


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger("mc-worker")


async def get_audit_input(audit_id: int) -> Optional[AuditInput]:
    """Получить параметры аудита из БД по audit_id."""
    async with get_session() as session:
        result = await session.execute(
            text("""
                SELECT price_total, area_sqm, monthly_rent, horizon_years,
                       cash_discount_pct, down_payment_pct, mortgage_term_years,
                       inflation_assumption, price_growth_base, mortgage_rate_base,
                       deposit_rate_base, mc_price_growth_std, mc_mortgage_rate_std,
                       mc_deposit_rate_std, mc_correlation_price_mortgage,
                       mc_correlation_price_deposit, mc_correlation_mortgage_deposit,
                       ei_threshold
                FROM audits WHERE id = :audit_id
            """),
            {"audit_id": audit_id}
        )
        row = result.fetchone()
        if not row:
            logger.error(f"Audit {audit_id} not found")
            return None
        return AuditInput(**dict(row._mapping))


async def run_monte_carlo(audit_id: int) -> Optional[MonteCarloSummary]:
    """Запустить Monte-Carlo симуляцию для заданного аудита."""
    logger.info(f"Starting Monte-Carlo simulation for audit {audit_id}")
    audit_input = await get_audit_input(audit_id)
    if not audit_input:
        return None

    # Создаём симулятор
    simulator = MonteCarloSimulatorFast(
        base_input=audit_input,
        num_simulations=settings.mc_default_simulations,
        seed=None,
        ei_threshold=settings.ei_buy_threshold,
    )

    # Запускаем симуляцию (используем векторную версию)
    try:
        summary = simulator.run_vectorized()
        best_prob = max(
            summary.cash.buy_probability,
            summary.mortgage.buy_probability,
            summary.deposit.buy_probability,
        )
        logger.info(
            f"Simulation completed for audit {audit_id}: "
            f"best_strategy={summary.recommended_strategy} "
            f"buy_probability={best_prob:.2f}%"
        )
        return summary
    except Exception as e:
        logger.exception(f"Monte-Carlo simulation failed for audit {audit_id}: {e}")
        return None


async def save_result(audit_id: int, summary: MonteCarloSummary) -> list:
    """Сохранить результат симуляции в БД."""
    from audit_engine.mc_storage import save_monte_carlo_run
    async with get_session() as session:
        inserted = await save_monte_carlo_run(session, audit_id, summary)
        await session.commit()
    logger.info(f"Saved Monte-Carlo runs {inserted} for audit {audit_id}")
    return inserted


async def process_task(audit_id: int, redis_client: redis.Redis) -> None:
    """Обработать одну задачу."""
    logger.info(f"Processing task for audit {audit_id}")
    summary = await run_monte_carlo(audit_id)
    if summary:
        await save_result(audit_id, summary)
        # Опубликовать уведомление о завершении (опционально)
        await redis_client.publish(f"mc_done_{audit_id}", json.dumps({"status": "success", "audit_id": audit_id}))
    else:
        logger.error(f"Task failed for audit {audit_id}")
        await redis_client.publish(f"mc_done_{audit_id}", json.dumps({"status": "error", "audit_id": audit_id}))


async def listen_for_tasks() -> None:
    """Основной цикл: подписка на канал 'mc_tasks'."""
    redis_client = redis.Redis.from_url(settings.redis_url)
    pubsub = redis_client.pubsub()
    await pubsub.subscribe("mc_tasks")
    logger.info("Subscribed to 'mc_tasks' channel, waiting for messages...")

    async for message in pubsub.listen():
        if message["type"] != "message":
            continue
        try:
            data = json.loads(message["data"])
            audit_id = data.get("audit_id")
            if not audit_id:
                logger.warning("Invalid task message: missing audit_id")
                continue
            # Запускаем обработку задачи в фоне
            asyncio.create_task(process_task(int(audit_id), redis_client))
        except json.JSONDecodeError:
            logger.warning(f"Malformed JSON: {message['data']}")
        except Exception as e:
            logger.exception(f"Error processing message: {e}")


async def main() -> None:
    """Точка входа."""
    logger.info(f"Monte-Carlo Worker started (GPU: {GPU_AVAILABLE})")
    try:
        await listen_for_tasks()
    except KeyboardInterrupt:
        logger.info("Worker stopped by signal")
    except Exception as e:
        logger.exception(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())