"""Автоматическое обновление макроэкономических данных от ЦБ РФ.

Источники:
- CBR DailyInfo SOAP (https://www.cbr.ru/DailyInfoWebServ/DailyInfo.asmx) —
  официальный SOAP-сервис ЦБ, метод KeyRate. Возвращает историю ставок за
  диапазон дат. Берём самую свежую запись.
- cbr-xml-daily.ru daily_json.js — фолбэк для inflation_annual (если поле
  когда-нибудь там появится; в текущей структуре только курсы валют).
- Росстат — годовая инфляция (через парсинг RSS / HTML; для MVP не дёргаем,
  inflation_annual просто остаётся None и не апдейтится).

Что делает:
1. Тянет ключевую ставку и (если доступна) inflation_annual.
2. Идемпотентный upsert в `macro_economics` по `date` (PK).
3. При ошибках сети — exit-code 2, для cron-эскалации.

Запуск:
    python -m scripts.fetch_macro_cbr
    python -m scripts.fetch_macro_cbr --dry-run
    python -m scripts.fetch_macro_cbr --input fixture.json --dry-run

Cron (см. RUNBOOK):
    0 8 * * 1,4  cd /app && python -m scripts.fetch_macro_cbr
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger("fetch_macro_cbr")

CBR_DAILY_URL = "https://www.cbr-xml-daily.ru/daily_json.js"
CBR_KEYRATE_SOAP_URL = "https://www.cbr.ru/DailyInfoWebServ/DailyInfo.asmx"
CBR_KEYRATE_SOAPACTION = "http://web.cbr.ru/KeyRate"
HTTP_TIMEOUT = 15
MAX_RETRIES = 3
BACKOFF = 1.5


@dataclass
class MacroSnapshot:
    """Минимальный снапшот макро. None означает «не получено в этот раз»."""

    date: date
    cbr_key_rate: Optional[float] = None
    inflation_annual: Optional[float] = None
    source: str = "cbr.ru SOAP KeyRate"

    def to_db_payload(self) -> dict:
        return {
            "date": self.date,
            "cbr_key_rate": self.cbr_key_rate,
            "inflation_annual": self.inflation_annual,
            "source": self.source,
        }


# ---------------------------------------------------------------------------
# Pure-функции (тестируются без сети)
# ---------------------------------------------------------------------------


def parse_keyrate_payload(payload) -> Optional[float]:
    """Достать ключевую ставку из ответа.

    Поддерживаются два формата:
    1. Старый: list[{date, rate}], отсортирован по убыванию даты (cbr-xml-daily).
    2. Новый: list[{"DT": iso8601, "Rate": float}] из SOAP KeyRate ЦБ;
       не обязательно отсортирован — сортируем сами и берём свежее.

    Возвращает None, если payload не похож на ожидаемый.
    """
    if not isinstance(payload, list) or not payload:
        return None

    def _key(rec):
        return rec.get("DT") or rec.get("date") or ""

    sorted_payload = sorted(
        (r for r in payload if isinstance(r, dict)),
        key=_key,
        reverse=True,
    )
    if not sorted_payload:
        return None
    head = sorted_payload[0]
    rate = head.get("Rate") if "Rate" in head else head.get("rate")
    try:
        return float(rate)
    except (TypeError, ValueError):
        return None


def parse_daily_payload(payload: dict) -> Optional[float]:
    """Найти годовую инфляцию (если есть) в payload daily_json.

    Структура daily_json.js — это в основном курсы валют. Инфляции там обычно
    нет, но парсер будущепригоден: ищем поле `Inflation` / `inflation` /
    `previousURL` (заглушка для расширения).
    """
    if not isinstance(payload, dict):
        return None
    for key in ("Inflation", "inflation", "InflationAnnual"):
        if key in payload:
            try:
                return float(payload[key])
            except (TypeError, ValueError):
                continue
    return None


def merge_snapshots(
    keyrate_payload: list | None,
    daily_payload: dict | None,
    snapshot_date: date | None = None,
) -> MacroSnapshot:
    """Собрать единый MacroSnapshot из двух raw-ответов."""
    snapshot_date = snapshot_date or date.today()
    return MacroSnapshot(
        date=snapshot_date,
        cbr_key_rate=parse_keyrate_payload(keyrate_payload or []),
        inflation_annual=parse_daily_payload(daily_payload or {}),
    )


# ---------------------------------------------------------------------------
# IO-функции (HTTP / DB)
# ---------------------------------------------------------------------------


async def _fetch_json(url: str) -> dict | list | None:
    import httpx

    delay = BACKOFF
    last_error: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
                resp = await client.get(url)
                resp.raise_for_status()
                return resp.json()
        except Exception as exc:
            last_error = exc
            logger.warning(
                "GET %s rc-fail (попытка %d/%d): %s",
                url, attempt, MAX_RETRIES, exc,
            )
            if attempt < MAX_RETRIES:
                await asyncio.sleep(delay)
                delay *= 2
    logger.error("GET %s: все %d попыток провалились: %s", url, MAX_RETRIES, last_error)
    return None


async def _fetch_keyrate_soap(days_back: int = 60) -> list | None:
    """Тянет историю ключевой ставки ЦБ за последние `days_back` дней через SOAP.

    Возвращает список dict {"DT": iso8601, "Rate": str}, неотсортированный,
    или None при сбое всех попыток.
    """
    import httpx
    import xml.etree.ElementTree as ET
    from datetime import timedelta

    today = date.today()
    from_date = (today - timedelta(days=days_back)).isoformat()
    to_date = today.isoformat()

    envelope = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope'
        ' xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
        ' xmlns:xsd="http://www.w3.org/2001/XMLSchema">'
        '<soap:Body><KeyRate xmlns="http://web.cbr.ru/">'
        f"<fromDate>{from_date}</fromDate>"
        f"<ToDate>{to_date}</ToDate>"
        "</KeyRate></soap:Body></soap:Envelope>"
    )
    headers = {
        "Content-Type": "text/xml; charset=utf-8",
        "SOAPAction": f'"{CBR_KEYRATE_SOAPACTION}"',
    }

    delay = BACKOFF
    last_error: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
                resp = await client.post(
                    CBR_KEYRATE_SOAP_URL, content=envelope, headers=headers
                )
                resp.raise_for_status()
                root = ET.fromstring(resp.text)
                records = []
                for kr in root.iter("KR"):
                    dt = kr.findtext("DT")
                    rate = kr.findtext("Rate")
                    if dt and rate:
                        records.append({"DT": dt, "Rate": rate})
                return records
        except Exception as exc:
            last_error = exc
            logger.warning(
                "SOAP KeyRate rc-fail (попытка %d/%d): %s",
                attempt, MAX_RETRIES, exc,
            )
            if attempt < MAX_RETRIES:
                await asyncio.sleep(delay)
                delay *= 2
    logger.error("SOAP KeyRate: все %d попыток провалились: %s", MAX_RETRIES, last_error)
    return None


async def upsert_macro(snapshot: MacroSnapshot) -> tuple[bool, bool]:
    """Идемпотентный upsert по дате. Возвращает (inserted, updated)."""
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from audit_engine.config import settings

    async_url = settings.database_url.replace(
        "postgresql://", "postgresql+asyncpg://"
    )
    engine = create_async_engine(async_url, echo=False)
    Session = async_sessionmaker(engine, expire_on_commit=False)
    payload = snapshot.to_db_payload()

    async with Session() as session:
        async with session.begin():
            existing = await session.execute(
                text("SELECT id FROM macro_economics WHERE date = :d"),
                {"d": payload["date"]},
            )
            row = existing.first()
            if row:
                update_set = []
                params = {"id": row.id}
                for field in ("cbr_key_rate", "inflation_annual", "source"):
                    if payload.get(field) is not None:
                        update_set.append(f"{field} = :{field}")
                        params[field] = payload[field]
                if not update_set:
                    return (False, False)
                await session.execute(
                    text(
                        f"UPDATE macro_economics SET {', '.join(update_set)} "
                        "WHERE id = :id"
                    ),
                    params,
                )
                return (False, True)
            await session.execute(
                text(
                    "INSERT INTO macro_economics "
                    "(date, cbr_key_rate, inflation_annual, source) "
                    "VALUES (:date, :cbr_key_rate, :inflation_annual, :source)"
                ),
                payload,
            )
            return (True, False)


async def _run(args) -> int:
    if args.input:
        logger.info("Offline: читаю фикстуру %s", args.input)
        raw = json.loads(Path(args.input).read_text(encoding="utf-8"))
        snapshot = merge_snapshots(
            keyrate_payload=raw.get("keyrate"),
            daily_payload=raw.get("daily"),
            snapshot_date=date.today(),
        )
    else:
        keyrate, daily = await asyncio.gather(
            _fetch_keyrate_soap(),
            _fetch_json(CBR_DAILY_URL),
        )
        if keyrate is None and daily is None:
            logger.error("Оба источника недоступны — выход")
            return 2
        snapshot = merge_snapshots(keyrate, daily)

    if snapshot.cbr_key_rate is None and snapshot.inflation_annual is None:
        logger.error("Ничего не извлекли (key_rate=None, inflation=None)")
        return 3

    logger.info(
        "Снапшот: date=%s, cbr_key_rate=%s, inflation_annual=%s",
        snapshot.date, snapshot.cbr_key_rate, snapshot.inflation_annual,
    )

    if args.dry_run:
        print(json.dumps(snapshot.to_db_payload(), default=str, indent=2))
        return 0

    inserted, updated = await upsert_macro(snapshot)
    logger.info(
        "✅ macro_economics: %s",
        "inserted" if inserted else ("updated" if updated else "no-op"),
    )
    return 0


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", type=Path, help="Offline JSON {keyrate, daily}")
    ap.add_argument("--dry-run", action="store_true", help="Не писать в БД")
    args = ap.parse_args()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
