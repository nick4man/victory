"""Автоматическое обновление реестра bank_offers из публичных источников.

Архитектура:
- Каждый источник = плагин-функция, возвращающая list[OfferUpdate].
- CLI вызывает один или несколько плагинов, агрегирует результаты,
  идемпотентно апсёртит в `bank_offers` по натуральному ключу
  (bank_name, product_type, product_name).
- При отсутствии сети или явной ошибке парсинга — exit-code 2 (cron-эскалация).

Доступные источники (--source):
- `cbr-keyrate-derived` — производит ориентир ставки от CBR keyrate (ключевая+спред).
  Идея: при изменении ключевой ставки минимальные ставки рынка двигаются
  синхронно (≈ keyrate + 2pp для базовой ипотеки). Не заменяет реальный
  скрейпинг банков, но даёт нижнюю границу для аудита, пока живые scraping-плагины не подключены.
- `manual-yaml` — читает YAML с ручными офферами (для разовой подгрузки).

Запуск:
    python -m scripts.fetch_bank_offers --source cbr-keyrate-derived
    python -m scripts.fetch_bank_offers --source manual-yaml --input offers.yaml
    python -m scripts.fetch_bank_offers --dry-run --source cbr-keyrate-derived

Cron (см. RUNBOOK):
    30 8 * * 1,4  cd /app && python -m scripts.fetch_bank_offers --source cbr-keyrate-derived
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import re
import sys
from dataclasses import asdict, dataclass, field
from datetime import date
from pathlib import Path
from typing import Callable, Iterable, Optional

logger = logging.getLogger("fetch_bank_offers")

HTTP_TIMEOUT = 20
MAX_RETRIES = 3
BACKOFF = 1.5


@dataclass
class OfferUpdate:
    """Унифицированный формат для всех плагинов-источников."""
    bank_name: str
    product_type: str
    product_name: str
    rate_min: float
    rate_max: Optional[float] = None
    term_years_min: Optional[int] = None
    term_years_max: Optional[int] = None
    down_payment_min_pct: Optional[float] = None
    max_loan_amount: Optional[float] = None
    requirements: dict = field(default_factory=dict)
    valid_from: date = field(default_factory=date.today)
    source: str = "manual"
    source_url: Optional[str] = None
    is_active: bool = True


# ---------------------------------------------------------------------------
# Plugin: cbr-keyrate-derived
#   Берём текущий keyrate из macro_economics (last row), формируем 3 опорных
#   оффера: «Базовая ипотека» (keyrate+2pp), «Семейная» (keyrate-7pp clamped
#   к 6%), «IT» (keyrate-7pp clamped к 5%). Остальные банки сохраняем такими
#   как есть — этот источник только обновляет «Рынок (ориентир)».
# ---------------------------------------------------------------------------


def derive_offers_from_keyrate(keyrate_pct: float, today: date) -> list[OfferUpdate]:
    """Pure-функция: вычисляет 3 ориентировочных оффера от ключевой ставки.

    Используется и плагином, и тестами. Не лезет в сеть и в БД.
    """
    base_rate = round(keyrate_pct + 2.0, 2)
    family_rate = max(round(keyrate_pct - 7.0, 2), 6.0)
    it_rate = max(round(keyrate_pct - 7.0, 2), 5.0)
    return [
        OfferUpdate(
            bank_name="Рынок (ориентир)",
            product_type="mortgage",
            product_name="Базовая ипотека (ориентир от ЦБ)",
            rate_min=base_rate,
            rate_max=round(base_rate + 4.0, 2),
            term_years_min=1,
            term_years_max=30,
            down_payment_min_pct=20.0,
            valid_from=today,
            source="cbr-keyrate-derived",
            source_url="https://www.cbr.ru/DailyInfoWebServ/DailyInfo.asmx?op=KeyRate",
            requirements={"derived_from_keyrate": keyrate_pct, "spread_pp": 2.0},
        ),
        OfferUpdate(
            bank_name="Рынок (ориентир)",
            product_type="mortgage",
            product_name="Семейная ипотека (ориентир)",
            rate_min=family_rate,
            rate_max=round(family_rate + 0.5, 2),
            term_years_min=1,
            term_years_max=30,
            down_payment_min_pct=20.0,
            valid_from=today,
            source="cbr-keyrate-derived",
            source_url="https://www.cbr.ru/DailyInfoWebServ/DailyInfo.asmx?op=KeyRate",
            requirements={
                "program": "family",
                "derived_from_keyrate": keyrate_pct,
                "subsidy_pp": 7.0,
                "floor_pct": 6.0,
            },
        ),
        OfferUpdate(
            bank_name="Рынок (ориентир)",
            product_type="mortgage",
            product_name="IT-ипотека (ориентир)",
            rate_min=it_rate,
            rate_max=round(it_rate + 0.5, 2),
            term_years_min=1,
            term_years_max=30,
            down_payment_min_pct=20.0,
            valid_from=today,
            source="cbr-keyrate-derived",
            source_url="https://www.cbr.ru/DailyInfoWebServ/DailyInfo.asmx?op=KeyRate",
            requirements={
                "program": "it",
                "derived_from_keyrate": keyrate_pct,
                "subsidy_pp": 7.0,
                "floor_pct": 5.0,
            },
        ),
    ]


async def plugin_cbr_keyrate_derived() -> list[OfferUpdate]:
    """Получить ставки-ориентир из последнего keyrate в macro_economics."""
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from audit_engine.config import settings

    async_url = settings.database_url.replace(
        "postgresql://", "postgresql+asyncpg://"
    )
    engine = create_async_engine(async_url, echo=False)
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as session:
        row = (
            await session.execute(
                text(
                    "SELECT cbr_key_rate FROM macro_economics "
                    "WHERE cbr_key_rate IS NOT NULL "
                    "ORDER BY date DESC LIMIT 1"
                )
            )
        ).first()
    if row is None or row.cbr_key_rate is None:
        logger.error(
            "macro_economics пуст — сначала запусти fetch_macro_cbr"
        )
        return []
    return derive_offers_from_keyrate(float(row.cbr_key_rate), date.today())


# ---------------------------------------------------------------------------
# Plugin: banki-ru
#   Источник: https://www.banki.ru/products/hypothec/ — публичная витрина
#   с встроенным schema.org JSON-LD (Product → AggregateOffer → MortgageLoan).
#   Стабильность 5/5: schema.org-стандарт, поля
#   `annualPercentageRate.minValue/maxValue`, `broker.name`, `loanTerm` (в днях),
#   `amount.value` ("X–Y ₽") — годами не меняются вне зависимости от редизайна.
#
#   Покрытие: ВТБ, Альфа-Банк, Банк ДОМ.РФ, Совкомбанк, Т-Банк, ВБРР, ПИК и др.
#   Сбер и Газпромбанк через banki.ru НЕ публикуются — для них Phase-3
#   будет fallback на sravni.ru (см. план).
#
#   Маппинг типа продукта по `name`:
#   * содержит «семейн», «для семей с детьми» → family_mortgage
#   * содержит «IT», «ит-ипотека» → it_mortgage
#   * содержит «дальневост», «арктическ» → far_east_mortgage
#   * содержит «господдержк», «субсидир» → subsidized_mortgage
#   * иначе → mortgage
# ---------------------------------------------------------------------------


BANKI_RU_URL = "https://www.banki.ru/products/hypothec/"
BANKI_RU_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)
# Целевые банки для фильтрации (нижний регистр, substring-match):
BANKI_RU_TARGETS_LOWER = {
    "сбербанк", "сбер",
    "втб",
    "газпромбанк",
    "альфа-банк", "альфабанк",
    "банк дом.рф", "дом.рф",
}


def _classify_product_type(name: str) -> str:
    n = name.lower()
    if "семейн" in n or "семей с детьми" in n:
        return "family_mortgage"
    if re.search(r"\bit[ -]", n) or "ит-ипотек" in n or "it-ипотек" in n:
        return "it_mortgage"
    if "дальневост" in n or "арктическ" in n:
        return "far_east_mortgage"
    if "сельск" in n:
        return "rural_mortgage"
    if "военн" in n:
        return "military_mortgage"
    if "господдержк" in n or "субсидир" in n:
        return "subsidized_mortgage"
    return "mortgage"


_AMOUNT_RANGE_RE = re.compile(
    r"(\d[\d\s ]*(?:[.,]\d+)?)\s*[–-]\s*(\d[\d\s ]*(?:[.,]\d+)?)"
)


def _parse_amount_max(amount_str: str) -> Optional[float]:
    """Из 'value': '500 000–60 000 000 ₽' достать верхнюю границу как float (рубли)."""
    if not amount_str:
        return None
    m = _AMOUNT_RANGE_RE.search(amount_str)
    if m:
        upper = m.group(2).replace(" ", "").replace(" ", "").replace(",", ".")
        try:
            return float(upper)
        except ValueError:
            return None
    # Single-value fallback
    cleaned = re.sub(r"[^\d.,]", "", amount_str).replace(",", ".")
    try:
        return float(cleaned)
    except ValueError:
        return None


def _parse_term_years(loan_term: dict) -> tuple[Optional[int], Optional[int]]:
    """schema.org loanTerm.value c unitCode='DAY' → years_max."""
    if not loan_term:
        return (None, None)
    value = loan_term.get("value")
    unit = (loan_term.get("unitCode") or "").upper()
    try:
        v = float(value)
    except (TypeError, ValueError):
        return (None, None)
    if unit == "DAY":
        years = round(v / 365.0)
    elif unit == "MON":
        years = round(v / 12.0)
    elif unit == "ANN":
        years = round(v)
    else:
        return (None, None)
    return (1, max(1, years))


def parse_banki_ru_html(html: str) -> list[OfferUpdate]:
    """Pure-функция: HTML banki.ru → список OfferUpdate для целевых 5 банков.

    Извлекает все JSON-LD-блоки, ищет Product → offers (AggregateOffer)
    → offers (list[MortgageLoan]). Фильтрует по `broker.name` substring-match
    с `BANKI_RU_TARGETS_LOWER`.
    """
    out: list[OfferUpdate] = []
    today = date.today()
    blocks = re.findall(
        r'<script type="application/ld\+json"[^>]*>(.*?)</script>', html, re.S
    )
    for b in blocks:
        try:
            d = json.loads(b)
        except (ValueError, json.JSONDecodeError):
            continue
        if d.get("@type") != "Product":
            continue
        ag = d.get("offers")
        if not isinstance(ag, dict):
            continue
        inner = ag.get("offers") or []
        for o in inner:
            if (o.get("@type") or "").lower() != "mortgageloan":
                continue
            broker = (o.get("broker") or {}).get("name", "").strip()
            broker_lc = broker.lower()
            if not any(t in broker_lc for t in BANKI_RU_TARGETS_LOWER):
                continue
            apr = o.get("annualPercentageRate") or {}
            try:
                rate_min = float(apr["minValue"])
            except (KeyError, TypeError, ValueError):
                continue
            try:
                rate_max = float(apr["maxValue"]) if apr.get("maxValue") is not None else None
            except (TypeError, ValueError):
                rate_max = None
            name = (o.get("name") or "").strip() or "Ипотека"
            ptype = _classify_product_type(name)
            amount = (o.get("amount") or {}).get("value", "")
            max_loan = _parse_amount_max(amount)
            term_min, term_max = _parse_term_years(o.get("loanTerm") or {})
            url = o.get("url") or BANKI_RU_URL
            out.append(
                OfferUpdate(
                    bank_name=broker,
                    product_type=ptype,
                    product_name=name[:255],
                    rate_min=rate_min,
                    rate_max=rate_max,
                    term_years_min=term_min,
                    term_years_max=term_max,
                    down_payment_min_pct=None,  # banki.ru JSON-LD это поле не отдаёт
                    max_loan_amount=max_loan,
                    valid_from=today,
                    source="banki.ru",
                    source_url=url,
                    requirements={
                        "schema_org_type": "MortgageLoan",
                        "amount_range": amount,
                    },
                )
            )
    return out


async def _fetch_banki_ru_html() -> str | None:
    """Тянет HTML banki.ru с cookie jar (нужен для cookie-wall)."""
    import httpx

    delay = BACKOFF
    last_error: Exception | None = None
    headers = {
        "User-Agent": BANKI_RU_USER_AGENT,
        "Accept-Language": "ru-RU,ru;q=0.9",
        "Accept": "text/html,application/xhtml+xml",
    }
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            async with httpx.AsyncClient(
                timeout=HTTP_TIMEOUT,
                headers=headers,
                follow_redirects=True,
            ) as c:
                # Two-pass: первый запрос проставляет cookies, второй уже даёт HTML
                await c.get(BANKI_RU_URL)
                resp = await c.get(BANKI_RU_URL)
                resp.raise_for_status()
                return resp.text
        except Exception as exc:
            last_error = exc
            logger.warning(
                "GET banki.ru rc-fail (попытка %d/%d): %s",
                attempt, MAX_RETRIES, exc,
            )
            if attempt < MAX_RETRIES:
                await asyncio.sleep(delay)
                delay *= 2
    logger.error("GET banki.ru: все %d попыток провалились: %s", MAX_RETRIES, last_error)
    return None


async def plugin_banki_ru() -> list[OfferUpdate]:
    """Получить mortgage-офферы для целевых 5 банков с banki.ru."""
    html = await _fetch_banki_ru_html()
    if html is None:
        return []
    return parse_banki_ru_html(html)


# ---------------------------------------------------------------------------
# Plugin: sravni-bank
#   Источник: sravni.ru/bank/<slug>/ipoteka/ — Next.js страница конкретного
#   банка с встроенным __NEXT_DATA__ JSON. Фолбэк для банков, которых нет
#   на banki.ru (Газпромбанк). Сбер на sravni не публикуется (DomClick).
#
#   --bank-slug передаёт slug (`gazprombank`, `vtb`, ...). Имя банка для
#   bank_offers.bank_name берётся из таблицы SRAVNI_SLUG_TO_NAME.
# ---------------------------------------------------------------------------


SRAVNI_BASE_URL = "https://www.sravni.ru/bank/{slug}/ipoteka/"
SRAVNI_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)
# Slug → каноническое имя банка для bank_offers.bank_name (стиль banki.ru):
SRAVNI_SLUG_TO_NAME = {
    "gazprombank": "Газпромбанк",
    "sberbank": "Сбербанк",
    "vtb": "ВТБ",
    "alfabank": "Альфа-Банк",
    "domrf": "Банк ДОМ.РФ",
}

# programCode → product_type (фолбэк к _classify_product_type):
SRAVNI_PROGRAM_TO_TYPE = {
    "semejnaya": "family_mortgage",
    "it-ipoteka": "it_mortgage",
    "selskaya": "rural_mortgage",
    "voennaya": "military_mortgage",
    "dalnevostochnaya": "far_east_mortgage",
    "subsidirovannaya": "subsidized_mortgage",
}


def _months_to_years(months: Optional[int]) -> Optional[int]:
    if not months:
        return None
    try:
        return max(1, round(int(months) / 12))
    except (TypeError, ValueError):
        return None


def parse_sravni_html(html: str, bank_slug: str) -> list[OfferUpdate]:
    """Pure-функция: HTML страницы sravni.ru/bank/<slug>/ipoteka/ →
    список OfferUpdate. Имя банка берётся из SRAVNI_SLUG_TO_NAME."""
    out: list[OfferUpdate] = []
    today = date.today()
    bank_name = SRAVNI_SLUG_TO_NAME.get(bank_slug.lower(), bank_slug)
    m = re.search(
        r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', html, re.S
    )
    if not m:
        return []
    try:
        data = json.loads(m.group(1))
    except (ValueError, json.JSONDecodeError):
        return []
    redux = (data.get("props") or {}).get("initialReduxState") or {}
    products = redux.get("products") or {}
    plist = products.get("list") or {}
    if not isinstance(plist, dict):
        return []
    offers_dict = plist.get("offers") or {}
    items = offers_dict.get("items") if isinstance(offers_dict, dict) else None
    if not isinstance(items, list):
        return []
    for it in items:
        if not isinstance(it, dict):
            continue
        try:
            rate_min = float(it["minRate"])
        except (KeyError, TypeError, ValueError):
            continue
        try:
            rate_max = float(it["maxRate"]) if it.get("maxRate") is not None else None
        except (TypeError, ValueError):
            rate_max = None
        name = (it.get("name") or "").strip() or "Ипотека"
        # Тип: сначала programCode, потом fallback на классификатор по имени.
        ptype = None
        for code in it.get("programCode") or []:
            if code in SRAVNI_PROGRAM_TO_TYPE:
                ptype = SRAVNI_PROGRAM_TO_TYPE[code]
                break
        if ptype is None:
            ptype = _classify_product_type(name)
        try:
            max_loan = float(it["maxSum"]) if it.get("maxSum") is not None else None
        except (TypeError, ValueError):
            max_loan = None
        url = it.get("link") or SRAVNI_BASE_URL.format(slug=bank_slug)
        if url and url.startswith("/"):
            url = "https://www.sravni.ru" + url
        out.append(
            OfferUpdate(
                bank_name=bank_name,
                product_type=ptype,
                product_name=name[:255],
                rate_min=rate_min,
                rate_max=rate_max,
                term_years_min=_months_to_years(it.get("minTerm")),
                term_years_max=_months_to_years(it.get("maxTerm")),
                down_payment_min_pct=None,
                max_loan_amount=max_loan,
                valid_from=today,
                source="sravni.ru",
                source_url=url,
                requirements={
                    "sravni_id": it.get("id"),
                    "program_codes": it.get("programCode") or [],
                },
            )
        )
    return out


async def _fetch_sravni_html(bank_slug: str) -> str | None:
    import httpx

    url = SRAVNI_BASE_URL.format(slug=bank_slug)
    delay = BACKOFF
    last_error: Exception | None = None
    headers = {
        "User-Agent": SRAVNI_USER_AGENT,
        "Accept-Language": "ru-RU,ru;q=0.9",
        "Accept": "text/html,application/xhtml+xml",
    }
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            async with httpx.AsyncClient(
                timeout=HTTP_TIMEOUT, headers=headers, follow_redirects=True
            ) as c:
                resp = await c.get(url)
                resp.raise_for_status()
                return resp.text
        except Exception as exc:
            last_error = exc
            logger.warning(
                "GET %s rc-fail (попытка %d/%d): %s", url, attempt, MAX_RETRIES, exc
            )
            if attempt < MAX_RETRIES:
                await asyncio.sleep(delay)
                delay *= 2
    logger.error("GET %s: все %d попыток провалились: %s", url, MAX_RETRIES, last_error)
    return None


async def plugin_sravni_bank(bank_slug: str = "gazprombank") -> list[OfferUpdate]:
    html = await _fetch_sravni_html(bank_slug)
    if html is None:
        return []
    return parse_sravni_html(html, bank_slug)


# ---------------------------------------------------------------------------
# Plugin: manual-yaml — для разовой подгрузки.
# ---------------------------------------------------------------------------


def parse_manual_yaml(text: str) -> list[OfferUpdate]:
    """Pure-функция: список dict-ов из YAML/JSON в OfferUpdate."""
    try:
        import yaml  # type: ignore
        raw = yaml.safe_load(text)
    except ImportError:
        raw = json.loads(text)
    if raw is None:
        return []
    if isinstance(raw, dict):
        raw = raw.get("offers") or []
    out: list[OfferUpdate] = []
    for item in raw:
        out.append(OfferUpdate(**item))
    return out


# ---------------------------------------------------------------------------
# Idempotent upserter (общий)
# ---------------------------------------------------------------------------


async def upsert_offers(offers: Iterable[OfferUpdate]) -> tuple[int, int]:
    """Идемпотентный upsert по (bank_name, product_type, product_name).

    Возвращает (inserted, updated).
    """
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from audit_engine.config import settings

    async_url = settings.database_url.replace(
        "postgresql://", "postgresql+asyncpg://"
    )
    engine = create_async_engine(async_url, echo=False)
    Session = async_sessionmaker(engine, expire_on_commit=False)
    inserted = 0
    updated = 0
    async with Session() as session:
        async with session.begin():
            for o in offers:
                row = (
                    await session.execute(
                        text(
                            "SELECT id FROM bank_offers "
                            "WHERE bank_name = :bn AND product_type = :pt "
                            "  AND product_name = :pn"
                        ),
                        {"bn": o.bank_name, "pt": o.product_type, "pn": o.product_name},
                    )
                ).first()
                params = {
                    "bn": o.bank_name,
                    "pt": o.product_type,
                    "pn": o.product_name,
                    "rmin": o.rate_min,
                    "rmax": o.rate_max,
                    "tmin": o.term_years_min,
                    "tmax": o.term_years_max,
                    "dpmin": o.down_payment_min_pct,
                    "mla": o.max_loan_amount,
                    "req": json.dumps(o.requirements or {}, ensure_ascii=False),
                    "vf": o.valid_from,
                    "src": o.source,
                    "url": o.source_url,
                    "act": o.is_active,
                }
                if row:
                    await session.execute(
                        text(
                            "UPDATE bank_offers SET "
                            "  rate_min = :rmin, rate_max = :rmax, "
                            "  term_years_min = :tmin, term_years_max = :tmax, "
                            "  down_payment_min_pct = :dpmin, "
                            "  max_loan_amount = :mla, "
                            "  requirements = CAST(:req AS jsonb), "
                            "  valid_from = :vf, source = :src, "
                            "  source_url = :url, is_active = :act, "
                            "  scraped_at = now() "
                            "WHERE id = :id"
                        ),
                        {**params, "id": row.id},
                    )
                    updated += 1
                else:
                    await session.execute(
                        text(
                            "INSERT INTO bank_offers "
                            "(bank_name, product_type, product_name, rate_min, "
                            " rate_max, term_years_min, term_years_max, "
                            " down_payment_min_pct, max_loan_amount, requirements, "
                            " valid_from, source, source_url, is_active) "
                            "VALUES (:bn, :pt, :pn, :rmin, :rmax, :tmin, :tmax, "
                            ":dpmin, :mla, CAST(:req AS jsonb), :vf, :src, :url, :act)"
                        ),
                        params,
                    )
                    inserted += 1
    return inserted, updated


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


SOURCES: dict[str, Callable[..., "asyncio.Future[list[OfferUpdate]]"]] = {
    "cbr-keyrate-derived": plugin_cbr_keyrate_derived,
    "banki-ru": plugin_banki_ru,
    "sravni-bank": plugin_sravni_bank,
}


async def _run(args) -> int:
    if args.source == "manual-yaml":
        if not args.input:
            logger.error("--source manual-yaml требует --input <yaml>")
            return 2
        offers = parse_manual_yaml(Path(args.input).read_text(encoding="utf-8"))
    else:
        plugin = SOURCES.get(args.source)
        if plugin is None:
            logger.error("Неизвестный --source: %s", args.source)
            return 2
        if args.source == "sravni-bank":
            offers = await plugin(args.bank_slug)
        else:
            offers = await plugin()

    if not offers:
        logger.error("Источник %s не вернул ни одного оффера", args.source)
        return 3

    logger.info("Подготовлено %d офферов от источника %s", len(offers), args.source)

    if args.dry_run:
        for o in offers:
            print(json.dumps(asdict(o), default=str, ensure_ascii=False, indent=2))
        return 0

    inserted, updated = await upsert_offers(offers)
    logger.info("✅ bank_offers: +%d, обновлено %d", inserted, updated)
    return 0


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--source",
        required=True,
        choices=list(SOURCES.keys()) + ["manual-yaml"],
    )
    ap.add_argument("--input", type=Path, help="Только для --source manual-yaml")
    ap.add_argument(
        "--bank-slug",
        default="gazprombank",
        help="Только для --source sravni-bank (slug из URL sravni.ru/bank/<slug>/)",
    )
    ap.add_argument("--dry-run", action="store_true", help="Не писать в БД")
    args = ap.parse_args()
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
