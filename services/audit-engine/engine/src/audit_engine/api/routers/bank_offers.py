"""CRUD endpoints для `bank_offers`.

Чтение — публичное (`GET /bank-offers`), изменение (POST/PATCH/DELETE) —
предполагается gate на уровне reverse-proxy или позже API-key middleware.
Здесь пока только валидация ввода + нормальные HTTP-коды.
"""
from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.api.deps import get_db
from audit_engine.bank_offers import (
    create_offer,
    deactivate_offer,
    get_offer,
    list_active_offers,
    list_all_offers,
    patch_offer,
)
from audit_engine.models import (
    BankOffer,
    BankOfferCreate,
    BankOfferPatch,
    BankProductType,
)

router = APIRouter(prefix="/bank-offers", tags=["bank-offers"])


@router.get("/", response_model=list[BankOffer])
async def get_bank_offers(
    product_type: Optional[BankProductType] = None,
    active: bool = True,
    db: AsyncSession = Depends(get_db),
):
    """Список офферов.

    * `active=true` (по умолчанию) — только актуальные на сегодня и `is_active=true`.
    * `active=false` — вся история (включая деактивированные).
    * `product_type` — фильтр по типу продукта.
    """
    if active:
        return await list_active_offers(db, product_type=product_type)
    return await list_all_offers(db, include_inactive=True)


@router.get("/{offer_id}", response_model=BankOffer)
async def get_bank_offer(
    offer_id: str,
    db: AsyncSession = Depends(get_db),
):
    offer = await get_offer(db, offer_id)
    if offer is None:
        raise HTTPException(status_code=404, detail="Bank offer not found")
    return offer


@router.post("/", response_model=BankOffer, status_code=201)
async def create_bank_offer(
    payload: BankOfferCreate,
    db: AsyncSession = Depends(get_db),
):
    """Создать новый оффер. Возвращает созданную запись с `id`."""
    return await create_offer(db, payload)


@router.patch("/{offer_id}", response_model=BankOffer)
async def patch_bank_offer(
    offer_id: str,
    payload: BankOfferPatch,
    db: AsyncSession = Depends(get_db),
):
    """Частичное обновление оффера (ставка, срок действия, деактивация)."""
    offer = await patch_offer(db, offer_id, payload)
    if offer is None:
        raise HTTPException(status_code=404, detail="Bank offer not found")
    return offer


@router.delete("/{offer_id}", status_code=204)
async def deactivate_bank_offer(
    offer_id: str,
    db: AsyncSession = Depends(get_db),
):
    """Soft-delete: помечает `is_active=false`.

    Исторические прогоны MC по деактивированным офферам сохраняются для
    аудит-трассы.
    """
    ok = await deactivate_offer(db, offer_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Bank offer not found or already inactive")
    return None
