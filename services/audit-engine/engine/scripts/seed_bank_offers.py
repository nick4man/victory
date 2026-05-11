"""Seed-скрипт для `bank_offers` — первичное наполнение реестра.

Запуск:
    python -m scripts.seed_bank_offers

Идемпотентен: повторный запуск обновляет/активирует существующие записи
(`bank_name + product_name` как натуральный ключ), не плодит дубли.

Данные собраны из публичных источников (официальные сайты банков, Дом.РФ,
Банки.ру) на 2026-04-18. Ставки — ориентировочные, требуют регулярной
актуализации (см. `jobs/bank_offers_refresh.py`).
"""
from __future__ import annotations

import asyncio
import json
from datetime import date
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from audit_engine.config import settings
from audit_engine.models import BankProductType


# ---------------------------------------------------------------------------
# Справочник офферов (bank_name, product_type, product_name уникальны).
# Формат: dict, все NUMERIC/INT — в натуральных единицах (% годовых,
# миллионы руб. в max_loan_amount — нет, здесь — рублях).
# ---------------------------------------------------------------------------
OFFERS: list[dict[str, Any]] = [
    # --- Сбер ---
    {
        "bank_name": "Сбер",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 18.4,
        "rate_max": 22.9,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 100_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://domclick.ru/ipoteka/gotovoe-zhile",
    },
    {
        "bank_name": "Сбер",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на новостройку",
        "rate_min": 17.9,
        "rate_max": 22.4,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 100_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://domclick.ru/ipoteka/novostroyka",
    },
    {
        "bank_name": "Сбер",
        "product_type": BankProductType.FAMILY_MORTGAGE,
        "product_name": "Семейная ипотека",
        "rate_min": 6.0,
        "rate_max": 6.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 12_000_000,
        "requirements": {"has_children_under_18": True},
        "source": "dom_rf",
        "source_url": "https://спроси.дом.рф/instructions/family-mortgage/",
    },
    {
        "bank_name": "Сбер",
        "product_type": BankProductType.IT_MORTGAGE,
        "product_name": "IT-ипотека",
        "rate_min": 5.0,
        "rate_max": 6.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 18_000_000,
        "requirements": {"is_it_specialist": True, "income_min": 150_000},
        "source": "dom_rf",
        "source_url": "https://спроси.дом.рф/instructions/it-mortgage/",
    },

    # --- ВТБ ---
    {
        "bank_name": "ВТБ",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 18.5,
        "rate_max": 23.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 120_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://www.vtb.ru/personal/ipoteka/vtorichnoe-zhilyo/",
    },
    {
        "bank_name": "ВТБ",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на новостройку",
        "rate_min": 18.0,
        "rate_max": 22.5,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 120_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://www.vtb.ru/personal/ipoteka/novostrojka/",
    },
    {
        "bank_name": "ВТБ",
        "product_type": BankProductType.FAMILY_MORTGAGE,
        "product_name": "Семейная ипотека",
        "rate_min": 6.0,
        "rate_max": 6.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 20.1,
        "max_loan_amount": 12_000_000,
        "requirements": {"has_children_under_18": True},
        "source": "dom_rf",
        "source_url": "https://www.vtb.ru/personal/ipoteka/semeinaya-ipoteka/",
    },

    # --- Т-Банк (Тинькофф) ---
    {
        "bank_name": "Т-Банк",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 19.0,
        "rate_max": 24.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 100_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://www.tbank.ru/loans/mortgage/",
    },
    {
        "bank_name": "Т-Банк",
        "product_type": BankProductType.CONSUMER_LOAN,
        "product_name": "Потребительский кредит",
        "rate_min": 21.9,
        "rate_max": 34.9,
        "term_years_min": 1,
        "term_years_max": 5,
        "down_payment_min_pct": None,
        "max_loan_amount": 5_000_000,
        "requirements": {"income_min": 30_000},
        "source": "official_site",
        "source_url": "https://www.tbank.ru/loans/cash/",
    },

    # --- Альфа-Банк ---
    {
        "bank_name": "Альфа-Банк",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 18.7,
        "rate_max": 23.5,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 70_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://alfabank.ru/get-money/mortgage/",
    },
    {
        "bank_name": "Альфа-Банк",
        "product_type": BankProductType.IT_MORTGAGE,
        "product_name": "IT-ипотека",
        "rate_min": 5.0,
        "rate_max": 6.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 18_000_000,
        "requirements": {"is_it_specialist": True, "income_min": 150_000},
        "source": "dom_rf",
        "source_url": "https://alfabank.ru/get-money/mortgage/it-ipoteka/",
    },

    # --- Дом.РФ ---
    {
        "bank_name": "Банк Дом.РФ",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на новостройку",
        "rate_min": 17.5,
        "rate_max": 22.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 60_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://domrfbank.ru/mortgage/novostrojka/",
    },
    {
        "bank_name": "Банк Дом.РФ",
        "product_type": BankProductType.SUBSIDIZED,
        "product_name": "Дальневосточная ипотека",
        "rate_min": 2.0,
        "rate_max": 2.0,
        "term_years_min": 1,
        "term_years_max": 20,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 9_000_000,
        "requirements": {"region": "far_east", "age_max": 35},
        "source": "dom_rf",
        "source_url": "https://спроси.дом.рф/instructions/dalnevostochnaya-ipoteka/",
    },
    {
        "bank_name": "Банк Дом.РФ",
        "product_type": BankProductType.SUBSIDIZED,
        "product_name": "Сельская ипотека",
        "rate_min": 3.0,
        "rate_max": 3.0,
        "term_years_min": 1,
        "term_years_max": 25,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 6_000_000,
        "requirements": {"location": "rural"},
        "source": "dom_rf",
        "source_url": "https://спроси.дом.рф/instructions/selskaya-ipoteka/",
    },

    # --- Газпромбанк ---
    {
        "bank_name": "Газпромбанк",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 18.6,
        "rate_max": 22.5,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 60_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://www.gazprombank.ru/personal/take_credit/mortgage/",
    },
    {
        "bank_name": "Газпромбанк",
        "product_type": BankProductType.FAMILY_MORTGAGE,
        "product_name": "Семейная ипотека",
        "rate_min": 6.0,
        "rate_max": 6.0,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 12_000_000,
        "requirements": {"has_children_under_18": True},
        "source": "dom_rf",
        "source_url": "https://www.gazprombank.ru/personal/take_credit/mortgage/family/",
    },

    # --- Росбанк ---
    {
        "bank_name": "Росбанк",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 19.1,
        "rate_max": 23.8,
        "term_years_min": 3,
        "term_years_max": 25,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 50_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://www.rosbank.ru/mortgage/",
    },
    {
        "bank_name": "Росбанк",
        "product_type": BankProductType.REFINANCE,
        "product_name": "Рефинансирование ипотеки",
        "rate_min": 18.0,
        "rate_max": 22.0,
        "term_years_min": 3,
        "term_years_max": 30,
        "down_payment_min_pct": None,
        "max_loan_amount": 50_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://www.rosbank.ru/mortgage/refinance/",
    },

    # --- Россельхозбанк ---
    {
        "bank_name": "Россельхозбанк",
        "product_type": BankProductType.SUBSIDIZED,
        "product_name": "Сельская ипотека",
        "rate_min": 3.0,
        "rate_max": 3.0,
        "term_years_min": 1,
        "term_years_max": 25,
        "down_payment_min_pct": 20.0,
        "max_loan_amount": 6_000_000,
        "requirements": {"location": "rural"},
        "source": "dom_rf",
        "source_url": "https://www.rshb.ru/natural/loans/mortgage/selskaya-ipoteka/",
    },
    {
        "bank_name": "Россельхозбанк",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 18.9,
        "rate_max": 23.5,
        "term_years_min": 1,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 60_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://www.rshb.ru/natural/loans/mortgage/",
    },

    # --- Совкомбанк ---
    {
        "bank_name": "Совкомбанк",
        "product_type": BankProductType.MORTGAGE,
        "product_name": "Ипотека на готовое жильё",
        "rate_min": 19.2,
        "rate_max": 24.5,
        "term_years_min": 3,
        "term_years_max": 30,
        "down_payment_min_pct": 15.0,
        "max_loan_amount": 40_000_000,
        "requirements": {},
        "source": "official_site",
        "source_url": "https://sovcombank.ru/apply/mortgage/",
    },
    {
        "bank_name": "Совкомбанк",
        "product_type": BankProductType.CONSUMER_LOAN,
        "product_name": "Кредит наличными",
        "rate_min": 19.9,
        "rate_max": 33.9,
        "term_years_min": 1,
        "term_years_max": 5,
        "down_payment_min_pct": None,
        "max_loan_amount": 5_000_000,
        "requirements": {"income_min": 25_000},
        "source": "official_site",
        "source_url": "https://sovcombank.ru/apply/credit/nalichnymi/",
    },
]


async def seed_offers() -> None:
    """Залить / обновить все офферы из `OFFERS` идемпотентно."""
    async_url = settings.database_url.replace("postgresql://", "postgresql+asyncpg://")
    engine = create_async_engine(async_url, echo=False)
    Session = async_sessionmaker(engine, expire_on_commit=False)

    today = date.today()
    inserted = 0
    updated = 0

    async with Session() as db:
        async with db.begin():
            for raw in OFFERS:
                # upsert по natural key (bank_name, product_name)
                existing = await db.execute(
                    text(
                        "SELECT id FROM bank_offers "
                        "WHERE bank_name = :bn AND product_name = :pn"
                    ),
                    {"bn": raw["bank_name"], "pn": raw["product_name"]},
                )
                row = existing.first()
                params = {
                    "bn": raw["bank_name"],
                    "pt": raw["product_type"].value,
                    "pn": raw["product_name"],
                    "rmin": raw["rate_min"],
                    "rmax": raw.get("rate_max"),
                    "tmin": raw.get("term_years_min"),
                    "tmax": raw.get("term_years_max"),
                    "dpmin": raw.get("down_payment_min_pct"),
                    "mla": raw.get("max_loan_amount"),
                    "req": json.dumps(raw.get("requirements") or {}),
                    "vf": today,
                    "vt": None,
                    "src": raw.get("source", "manual"),
                    "surl": raw.get("source_url"),
                }
                if row:
                    params["id"] = str(row._mapping["id"])
                    await db.execute(
                        text(
                            "UPDATE bank_offers SET "
                            " product_type=:pt, rate_min=:rmin, rate_max=:rmax, "
                            " term_years_min=:tmin, term_years_max=:tmax, "
                            " down_payment_min_pct=:dpmin, max_loan_amount=:mla, "
                            " requirements=CAST(:req AS jsonb), valid_from=:vf, "
                            " valid_to=:vt, source=:src, source_url=:surl, "
                            " is_active=true "
                            "WHERE id = CAST(:id AS uuid)"
                        ),
                        params,
                    )
                    updated += 1
                else:
                    await db.execute(
                        text(
                            "INSERT INTO bank_offers "
                            "(bank_name, product_type, product_name, rate_min, "
                            " rate_max, term_years_min, term_years_max, "
                            " down_payment_min_pct, max_loan_amount, "
                            " requirements, valid_from, valid_to, source, "
                            " source_url, is_active) "
                            "VALUES (:bn, :pt, :pn, :rmin, :rmax, :tmin, :tmax, "
                            " :dpmin, :mla, CAST(:req AS jsonb), :vf, :vt, "
                            " :src, :surl, true)"
                        ),
                        params,
                    )
                    inserted += 1

    await engine.dispose()
    print(f"Seeded bank_offers: +{inserted} new, ~{updated} updated "
          f"(total rows processed: {len(OFFERS)})")


if __name__ == "__main__":
    asyncio.run(seed_offers())
