"""Monte-Carlo прогон аудита по всем актуальным банковским офферам.

Для каждого eligible-оффера запускается независимый MC-прогон с подмененной
ставкой (offer.rate_min либо середина диапазона) — остальная стохастика
(price_growth, deposit_rate) шарится через общий seed, чтобы сравнение
офферов было честным (один и тот же «сценарий мира» раскручен по всем).

На выходе — `MultiOfferMCResult` с per-offer метриками и рекомендованным
по `ei_mortgage_median`.
"""
from __future__ import annotations

import asyncio
from typing import Optional
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.bank_offers import list_active_offers
from audit_engine.config import settings
from audit_engine.models import (
    AuditInput,
    BankOffer,
    BankProductType,
    MultiOfferMCResult,
    OfferMCSummary,
)
from audit_engine.monte_carlo_fast import MonteCarloSimulatorFast
from audit_engine.offer_selector import (
    effective_rate,
    eligible_offers,
)


# Чтобы не жечь CPU при 100+ офферах в БД — ограничиваем сверху.
# Оставшиеся офферы (самые дорогие по rate_min) можно увидеть через
# отдельный /compare-offers endpoint с пагинацией.
_MAX_OFFERS_PER_RUN = 20


def _offer_term_override(offer: BankOffer, base_term: int) -> int:
    """Подобрать срок, совместимый с оффером.

    Если базовый срок клиента укладывается в [term_years_min, term_years_max] —
    используем его. Иначе подтягиваем к ближайшей границе.
    """
    term = base_term
    if offer.term_years_min is not None and term < offer.term_years_min:
        term = offer.term_years_min
    if offer.term_years_max is not None and term > offer.term_years_max:
        term = offer.term_years_max
    return term


def _run_one_offer(
    audit_input: AuditInput,
    offer: BankOffer,
    num_simulations: int,
    seed: Optional[int],
) -> OfferMCSummary:
    """Синхронный прогон MC для одного оффера (вызывается через to_thread)."""
    rate = effective_rate(offer)
    term = _offer_term_override(offer, audit_input.mortgage_term_years)
    sim = MonteCarloSimulatorFast(
        base_input=audit_input,
        num_simulations=num_simulations,
        seed=seed,
    )
    summary = sim.run_for_offer(mortgage_rate=rate, term_years=term)
    mc = summary.mortgage
    return OfferMCSummary(
        offer=offer,
        effective_rate=rate,
        monte_carlo=summary,
        ei_mortgage_median=mc.ei_median,
        ei_mortgage_mean=mc.ei_mean,
        ei_mortgage_p5=mc.ei_p5,
        ei_mortgage_p95=mc.ei_p95,
        buy_probability=mc.buy_probability,
    )


async def run_monte_carlo_all_offers(
    db: AsyncSession,
    audit_input: AuditInput,
    audit_id: Optional[UUID | str] = None,
    num_simulations: Optional[int] = None,
    seed: Optional[int] = None,
    product_type: Optional[BankProductType] = None,
    limit: int = _MAX_OFFERS_PER_RUN,
) -> MultiOfferMCResult:
    """Прогнать MC по всем подходящим офферам из `bank_offers`.

    Args:
        db: async-сессия Postgres.
        audit_input: входные параметры клиента.
        audit_id: опционально — id записи аудита (для линковки кеша).
        num_simulations: размер симуляции. Default из `settings.mc_default_simulations`.
        seed: seed для воспроизводимости.
        product_type: фильтр по типу продукта (по умолчанию — все ипотечные).
        limit: максимум офферов за один прогон (top-N по минимальной ставке).

    Returns:
        `MultiOfferMCResult` с per-offer summary и рекомендованным.
    """
    n = num_simulations or settings.mc_default_simulations

    all_offers = await list_active_offers(db, product_type=product_type)
    eligible = eligible_offers(audit_input, all_offers)
    skipped = len(all_offers) - len(eligible)

    # Top-N по минимальной ставке (офферы уже отсортированы в SQL).
    selected = eligible[:limit]

    if not selected:
        return MultiOfferMCResult(
            audit_id=str(audit_id) if audit_id is not None else None,
            num_simulations=n,
            num_offers=0,
            per_offer=[],
            recommended_offer_id=None,
            recommended_bank=None,
            recommended_product=None,
            skipped_ineligible=skipped,
        )

    # Параллельный offload в threadpool: каждая симуляция — numpy-работа,
    # GIL освобождается внутри BLAS-операций, поэтому threads дают реальный
    # параллелизм. Ограничиваем шириной семафора на уровне API.
    tasks = [
        asyncio.to_thread(_run_one_offer, audit_input, offer, n, seed)
        for offer in selected
    ]
    per_offer = await asyncio.gather(*tasks)

    best = max(per_offer, key=lambda s: s.ei_mortgage_median)

    return MultiOfferMCResult(
        audit_id=str(audit_id) if audit_id is not None else None,
        num_simulations=n,
        num_offers=len(per_offer),
        per_offer=list(per_offer),
        recommended_offer_id=best.offer.id,
        recommended_bank=best.offer.bank_name,
        recommended_product=best.offer.product_name,
        skipped_ineligible=skipped,
    )
