"""D3 — Comparison: side-by-side сравнение 2-3 сохранённых аудитов.

Принимает список audit_id из `audit_archive`, грузит ключевые поля,
формирует таблицу сравнения и (опционально) Markdown-отчёт через Jinja2.

Контракт:
- Сравниваем 2..MAX_COMPARE аудитов (по умолчанию 3) — больше плохо
  читается на A4-странице.
- Сохранённые аудиты могут быть разного property_type — это нормально,
  выводим N/A для неприменимых полей.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

MAX_COMPARE = 3


@dataclass
class ComparisonRow:
    audit_id: str
    object_address: str | None
    apartment_type: str | None
    area_sqm: float | None
    audit_date: str | None
    price_total: float | None
    price_per_sqm: float | None
    ei_cash: float | None
    ei_mortgage: float | None
    ei_deposit: float | None
    best_strategy: str  # cash | mortgage | deposit
    best_ei: float
    verdict: str | None
    monte_carlo_buy_prob: float | None
    monte_carlo_mean_ei: float | None
    property_type: str
    risks_count: int


def _best_strategy(ei_cash: float | None, ei_mortgage: float | None, ei_deposit: float | None) -> tuple[str, float]:
    values = {
        "cash": ei_cash or 0.0,
        "mortgage": ei_mortgage or 0.0,
        "deposit": ei_deposit or 0.0,
    }
    best_name, best_val = max(values.items(), key=lambda kv: kv[1])
    return best_name, best_val


def _coerce_float(v: Any) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _coerce_risks(v: Any) -> int:
    if v is None:
        return 0
    if isinstance(v, str):
        try:
            v = json.loads(v)
        except json.JSONDecodeError:
            return 0
    if isinstance(v, list):
        return len(v)
    return 0


async def load_audits(db: AsyncSession, audit_ids: list[str]) -> list[ComparisonRow]:
    """Грузим аудиты из БД, сохраняя порядок входного списка."""
    if not audit_ids:
        return []
    result = await db.execute(
        text(
            "SELECT id, object_address, apartment_type, area_sqm, audit_date, "
            "price_total, price_per_sqm, ei_cash, ei_mortgage, ei_deposit, "
            "verdict, monte_carlo_buy_prob, monte_carlo_mean_ei, property_type, risks "
            "FROM audit_archive WHERE id::text = ANY(:ids)"
        ),
        {"ids": audit_ids},
    )
    rows = {str(r._mapping["id"]): r._mapping for r in result.fetchall()}

    out: list[ComparisonRow] = []
    for aid in audit_ids:
        m = rows.get(aid)
        if not m:
            continue
        ei_cash = _coerce_float(m["ei_cash"])
        ei_mortgage = _coerce_float(m["ei_mortgage"])
        ei_deposit = _coerce_float(m["ei_deposit"])
        best_name, best_val = _best_strategy(ei_cash, ei_mortgage, ei_deposit)
        out.append(ComparisonRow(
            audit_id=str(m["id"]),
            object_address=m["object_address"],
            apartment_type=m["apartment_type"],
            area_sqm=_coerce_float(m["area_sqm"]),
            audit_date=str(m["audit_date"]) if m["audit_date"] else None,
            price_total=_coerce_float(m["price_total"]),
            price_per_sqm=_coerce_float(m["price_per_sqm"]),
            ei_cash=ei_cash,
            ei_mortgage=ei_mortgage,
            ei_deposit=ei_deposit,
            best_strategy=best_name,
            best_ei=round(best_val, 4),
            verdict=m["verdict"],
            monte_carlo_buy_prob=_coerce_float(m["monte_carlo_buy_prob"]),
            monte_carlo_mean_ei=_coerce_float(m["monte_carlo_mean_ei"]),
            property_type=m["property_type"] or "APARTMENT",
            risks_count=_coerce_risks(m["risks"]),
        ))
    return out


def rank_by_best_ei(rows: list[ComparisonRow]) -> list[ComparisonRow]:
    """Сортируем по best_ei DESC для UI «лучший сверху»."""
    return sorted(rows, key=lambda r: r.best_ei, reverse=True)


def winning_audit(rows: list[ComparisonRow]) -> ComparisonRow | None:
    """Лучший аудит по best_ei (или None если список пуст)."""
    if not rows:
        return None
    return max(rows, key=lambda r: r.best_ei)
