"""Парсер месячной инфляции YoY с публичной страницы ЦБ.

Источник: https://www.cbr.ru/hd_base/infl/ — HTML-таблица с колонками
(месяц `MM.YYYY`, ключевая ставка %, инфляция YoY %, цель %). Серверный
рендер, формат стабильный годами, без JS.

Что делает:
1. Тянет HTML, парсит таблицу regex'ами (без lxml, чтобы не тащить depend).
2. Берёт самый свежий месяц с непустой инфляцией.
3. Идемпотентный upsert в `macro_economics` за дату = последний день месяца:
   - `inflation_annual` ← найденное значение,
   - `inflation_monthly` пока None (страница даёт только YoY),
   - `source` = "cbr.ru/hd_base/infl HTML".

Запуск:
    python -m scripts.fetch_inflation_cbr            # online
    python -m scripts.fetch_inflation_cbr --dry-run  # без записи
    python -m scripts.fetch_inflation_cbr --input fixture.html  # offline

Cron:
    15 8 * * 1,4  cd /app && python -m scripts.fetch_inflation_cbr
"""
from __future__ import annotations

import argparse
import asyncio
import calendar
import logging
import re
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Optional

logger = logging.getLogger("fetch_inflation_cbr")

CBR_INFL_URL = "https://www.cbr.ru/hd_base/infl/"
USER_AGENT = "Mozilla/5.0 (audit-engine fetch_inflation_cbr/1.0)"
HTTP_TIMEOUT = 15
MAX_RETRIES = 3
BACKOFF = 1.5


@dataclass
class InflationRecord:
    period_end: date  # последний день месяца
    inflation_annual: float
    source: str = "cbr.ru/hd_base/infl HTML"


# ---------------------------------------------------------------------------
# Pure-функции
# ---------------------------------------------------------------------------


_ROW_RE = re.compile(
    r"<tr[^>]*>\s*"
    r"<td[^>]*>\s*(?P<month>\d{2})\.(?P<year>\d{4})\s*</td>\s*"
    r"<td[^>]*>\s*(?P<keyrate>[\d,\.]*)\s*</td>\s*"
    r"<td[^>]*>\s*(?P<infl>[\d,\.]*)\s*</td>\s*"
    r"<td[^>]*>\s*(?P<target>[\d,\.]*)\s*</td>\s*"
    r"</tr>",
    re.IGNORECASE | re.DOTALL,
)


def _parse_ru_float(s: str) -> Optional[float]:
    if not s:
        return None
    s = s.replace("\xa0", "").replace(" ", "").replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def parse_inflation_html(html: str) -> Optional[InflationRecord]:
    """Найти самый свежий месяц с непустой YoY-инфляцией.

    HTML страницы стабильно содержит блок `<tr>` со строкой вида:
        <td>03.2026</td><td>15,00</td><td>5,86</td><td>4,00</td>

    Возвращает None, если ни одной валидной строки не нашлось.
    """
    candidates: list[InflationRecord] = []
    for m in _ROW_RE.finditer(html):
        infl = _parse_ru_float(m.group("infl"))
        if infl is None:
            continue
        try:
            month = int(m.group("month"))
            year = int(m.group("year"))
            last_day = calendar.monthrange(year, month)[1]
            period_end = date(year, month, last_day)
        except ValueError:
            continue
        candidates.append(InflationRecord(period_end=period_end, inflation_annual=infl))

    if not candidates:
        return None
    candidates.sort(key=lambda r: r.period_end, reverse=True)
    return candidates[0]


# ---------------------------------------------------------------------------
# IO
# ---------------------------------------------------------------------------


async def _fetch_html(url: str) -> str | None:
    import httpx

    delay = BACKOFF
    last_error: Exception | None = None
    headers = {"User-Agent": USER_AGENT, "Accept-Language": "ru-RU,ru;q=0.9"}
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, headers=headers) as c:
                resp = await c.get(url)
                resp.raise_for_status()
                return resp.text
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


async def upsert_inflation(rec: InflationRecord) -> tuple[bool, bool]:
    """Идемпотентный upsert по дате (последний день месяца)."""
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from audit_engine.config import settings

    async_url = settings.database_url.replace(
        "postgresql://", "postgresql+asyncpg://"
    )
    engine = create_async_engine(async_url, echo=False)
    Session = async_sessionmaker(engine, expire_on_commit=False)

    async with Session() as session:
        async with session.begin():
            existing = await session.execute(
                text("SELECT id, inflation_annual FROM macro_economics WHERE date = :d"),
                {"d": rec.period_end},
            )
            row = existing.first()
            if row:
                if (
                    row.inflation_annual is not None
                    and float(row.inflation_annual) == rec.inflation_annual
                ):
                    return (False, False)
                await session.execute(
                    text(
                        "UPDATE macro_economics "
                        "SET inflation_annual = :infl, source = :src "
                        "WHERE id = :id"
                    ),
                    {"id": row.id, "infl": rec.inflation_annual, "src": rec.source},
                )
                return (False, True)
            await session.execute(
                text(
                    "INSERT INTO macro_economics (date, inflation_annual, source) "
                    "VALUES (:d, :infl, :src)"
                ),
                {"d": rec.period_end, "infl": rec.inflation_annual, "src": rec.source},
            )
            return (True, False)


async def _run(args) -> int:
    if args.input:
        logger.info("Offline: читаю фикстуру %s", args.input)
        html = Path(args.input).read_text(encoding="utf-8")
    else:
        html = await _fetch_html(CBR_INFL_URL)
        if html is None:
            return 2

    rec = parse_inflation_html(html)
    if rec is None:
        logger.error("Не нашли ни одной валидной строки в HTML")
        return 3

    logger.info(
        "Свежий месяц: %s, inflation_annual=%.2f%%",
        rec.period_end, rec.inflation_annual,
    )
    if args.dry_run:
        print(f"{rec.period_end}\t{rec.inflation_annual}\t{rec.source}")
        return 0

    inserted, updated = await upsert_inflation(rec)
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
    ap.add_argument("--input", type=Path, help="Offline HTML-фикстура (cbr.ru/hd_base/infl)")
    ap.add_argument("--dry-run", action="store_true", help="Не писать в БД")
    args = ap.parse_args()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
