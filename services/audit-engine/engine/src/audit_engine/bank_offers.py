"""DB-access layer for `bank_offers`.

CRUD + выборка активных офферов. Используется `offer_selector` (фильтрация
по eligibility) и `multi_offer_mc` (MC по каждому подходящему офферу).
"""
from __future__ import annotations

import json
import logging
from datetime import date
from typing import Optional
from uuid import UUID

logger = logging.getLogger(__name__)

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.models import (
    BankOffer,
    BankOfferCreate,
    BankOfferPatch,
    BankProductType,
)


_COLS = (
    "id, bank_name, product_type, product_name, "
    "rate_min, rate_max, term_years_min, term_years_max, "
    "down_payment_min_pct, max_loan_amount, requirements, "
    "valid_from, valid_to, source, source_url, is_active"
)


def _row_to_offer(row_mapping):
    """Перевести строку Postgres в BankOffer (dict или RowMapping).

    Returns BankOffer or None — None means "skip this row" (unknown
    product_type that isn't yet in the enum). The caller filters Nones
    so one bad row doesn't 500 the whole list endpoint.
    """
    m = dict(row_mapping)
    # requirements из JSONB приходит как dict — ок; на всякий случай поддерживаем str
    req = m.get("requirements")
    if isinstance(req, str):
        req = json.loads(req or "{}")
    try:
        product_type = BankProductType(m["product_type"])
    except ValueError:
        logger.warning(
            "skipping bank_offer id=%s with unknown product_type=%r — "
            "add the value to BankProductType enum if it should be visible",
            m.get("id"), m.get("product_type"),
        )
        return None
    return BankOffer(
        id=str(m["id"]) if m.get("id") is not None else None,
        bank_name=m["bank_name"],
        product_type=product_type,
        product_name=m["product_name"],
        rate_min=float(m["rate_min"]),
        rate_max=float(m["rate_max"]) if m.get("rate_max") is not None else None,
        term_years_min=m.get("term_years_min"),
        term_years_max=m.get("term_years_max"),
        down_payment_min_pct=float(m["down_payment_min_pct"]) if m.get("down_payment_min_pct") is not None else None,
        max_loan_amount=float(m["max_loan_amount"]) if m.get("max_loan_amount") is not None else None,
        requirements=req or {},
        valid_from=m["valid_from"],
        valid_to=m.get("valid_to"),
        source=m["source"],
        source_url=m.get("source_url"),
        is_active=bool(m["is_active"]),
    )


async def list_active_offers(
    db: AsyncSession,
    product_type: Optional[BankProductType] = None,
    today: Optional[date] = None,
) -> list[BankOffer]:
    """Актуальные офферы на дату `today` (по умолчанию — сегодня).

    Возвращаются только `is_active=true` и попадающие в окно
    `[valid_from, COALESCE(valid_to, '9999-01-01')]`. Сортировка —
    по `rate_min` (дешёвые сверху), затем по названию банка.
    """
    d = today or date.today()
    params: dict[str, object] = {"today": d}
    where = ["is_active = true", "valid_from <= :today", "(valid_to IS NULL OR valid_to >= :today)"]
    if product_type is not None:
        where.append("product_type = :pt")
        params["pt"] = product_type.value
    sql = (
        f"SELECT {_COLS} FROM bank_offers "
        f"WHERE {' AND '.join(where)} "
        f"ORDER BY rate_min ASC, bank_name ASC"
    )
    result = await db.execute(text(sql), params)
    return [o for o in (_row_to_offer(r._mapping) for r in result.fetchall()) if o is not None]


async def list_all_offers(
    db: AsyncSession,
    include_inactive: bool = False,
) -> list[BankOffer]:
    """Вся история офферов (для CRUD UI)."""
    sql = f"SELECT {_COLS} FROM bank_offers"
    if not include_inactive:
        sql += " WHERE is_active = true"
    sql += " ORDER BY bank_name, product_name"
    result = await db.execute(text(sql))
    return [o for o in (_row_to_offer(r._mapping) for r in result.fetchall()) if o is not None]


async def get_offer(db: AsyncSession, offer_id: UUID | str) -> Optional[BankOffer]:
    result = await db.execute(
        text(f"SELECT {_COLS} FROM bank_offers WHERE id = CAST(:id AS uuid)"),
        {"id": str(offer_id)},
    )
    row = result.first()
    return _row_to_offer(row._mapping) if row else None


async def create_offer(db: AsyncSession, payload: BankOfferCreate) -> BankOffer:
    result = await db.execute(
        text(
            "INSERT INTO bank_offers "
            "(bank_name, product_type, product_name, rate_min, rate_max, "
            " term_years_min, term_years_max, down_payment_min_pct, "
            " max_loan_amount, requirements, valid_from, valid_to, "
            " source, source_url, is_active) "
            "VALUES (:bn, :pt, :pn, :rmin, :rmax, "
            " :tmin, :tmax, :dpmin, "
            " :mla, CAST(:req AS jsonb), :vf, :vt, "
            " :src, :surl, :act) "
            f"RETURNING {_COLS}"
        ),
        {
            "bn": payload.bank_name,
            "pt": payload.product_type.value,
            "pn": payload.product_name,
            "rmin": payload.rate_min,
            "rmax": payload.rate_max,
            "tmin": payload.term_years_min,
            "tmax": payload.term_years_max,
            "dpmin": payload.down_payment_min_pct,
            "mla": payload.max_loan_amount,
            "req": json.dumps(payload.requirements or {}),
            "vf": payload.valid_from,
            "vt": payload.valid_to,
            "src": payload.source,
            "surl": payload.source_url,
            "act": payload.is_active,
        },
    )
    row = result.first()
    return _row_to_offer(row._mapping)


async def patch_offer(
    db: AsyncSession,
    offer_id: UUID | str,
    patch: BankOfferPatch,
) -> Optional[BankOffer]:
    """Частичное обновление. None — если оффер не найден."""
    fields = patch.model_dump(exclude_none=True)
    if not fields:
        return await get_offer(db, offer_id)

    set_chunks: list[str] = []
    params: dict[str, object] = {"id": str(offer_id)}
    for key, value in fields.items():
        if key == "requirements":
            set_chunks.append("requirements = CAST(:requirements AS jsonb)")
            params["requirements"] = json.dumps(value)
        else:
            set_chunks.append(f"{key} = :{key}")
            params[key] = value

    sql = (
        f"UPDATE bank_offers SET {', '.join(set_chunks)} "
        f"WHERE id = CAST(:id AS uuid) RETURNING {_COLS}"
    )
    result = await db.execute(text(sql), params)
    row = result.first()
    return _row_to_offer(row._mapping) if row else None


async def deactivate_offer(db: AsyncSession, offer_id: UUID | str) -> bool:
    """Soft-delete: is_active=false. True — если запись изменена."""
    result = await db.execute(
        text(
            "UPDATE bank_offers SET is_active = false "
            "WHERE id = CAST(:id AS uuid) AND is_active = true"
        ),
        {"id": str(offer_id)},
    )
    return (result.rowcount or 0) > 0
