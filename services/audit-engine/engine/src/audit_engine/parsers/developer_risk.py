"""Парсер риск-индекса застройщика — Федресурс + Картотека арбитражных судов.

Цель: для каждого застройщика по ИНН вычислить:
- `federresurs_status` — есть ли процедура банкротства / ликвидации
- `lawsuits_count`     — оценка числа судебных дел (грубая, по поиску)
- `risk_multiplier`    — итоговый коэффициент к EI

Источники:
- https://fedresurs.ru/search?searchString=<INN>
  Публичный HTML-поиск Единого федерального реестра сведений о банкротстве.
  Возвращает карточку организации со статусом и числом сообщений.

- https://kad.arbitr.ru/Kad/Card?numb=... (опционально)
  Картотека арбитражных дел; стабильное API нет, парсить дорого. В MVP
  оставляем `lawsuits_count = 0` если Федресурс ничего не нашёл, иначе
  оцениваем по числу сообщений в карточке Федресурса (грубо).

Логика risk_multiplier (см. миграцию j8f5e6a7b9c2):
- active       + lawsuits<5  → 1.00
- active       + 5≤lawsuits<20 → 0.95
- active       + lawsuits≥20 → 0.90
- bankruptcy_initiated       → 0.90
- bankruptcy / liquidated    → 0.85
- unknown                    → 1.00 (нет данных — не штрафуем)

Использование:
    from audit_engine.parsers.developer_risk import refresh_developer_by_inn
    snap = await refresh_developer_by_inn("7707083893")  # Сбер
    # → DeveloperRiskSnapshot(...)

CLI:
    python -m audit_engine.parsers.developer_risk --inn 7707083893
    python -m audit_engine.parsers.developer_risk --inn 7707083893 --dry-run
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import re
from dataclasses import dataclass
from datetime import datetime, timezone

import httpx
from sqlalchemy import text

from audit_engine.db import get_session

logger = logging.getLogger(__name__)

FEDRESURS_URL = "https://fedresurs.ru/search?searchString={inn}"
DEFAULT_HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
    "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
    "Accept": "text/html,application/xhtml+xml",
}

# Эвристики статуса. Федресурс рендерит SPA, но в первичном HTML отдаёт
# <meta>-тэги и JSON с инициализационными данными в <script>. Ищем триггерные
# подстроки независимо от обёртки.
# Триггеры по корням слов, чтобы ловить разные склонения. Порядок важен —
# первый match выигрывает. Сильнее всего «ликвидирован» (необратимо).
STATUS_HINTS: tuple[tuple[str, str], ...] = (
    ("ликвидирован", "liquidated"),
    ("процедура банкротства завершен", "bankruptcy"),
    ("конкурсное производство", "bankruptcy"),
    ("признан банкротом", "bankruptcy"),
    ("процедура наблюдени", "bankruptcy_initiated"),
    ("введена процедура наблюдени", "bankruptcy_initiated"),
    ("финансовое оздоровлени", "bankruptcy_initiated"),
    ("внешнее управлени", "bankruptcy_initiated"),
    ("заявление о банкротстве", "bankruptcy_initiated"),
    ("намерени", "bankruptcy_initiated"),
)


@dataclass
class DeveloperRiskSnapshot:
    inn: str
    name: str | None
    federresurs_status: str
    lawsuits_count: int
    risk_multiplier: float
    notes: str
    raw_excerpt: str | None = None


def _classify_status(html: str) -> tuple[str, str]:
    """Возвращает (status, notes). lowercase HTML для match."""
    if not html:
        return ("unknown", "Источник вернул пустой ответ")
    lower = html.lower()
    for hint, status in STATUS_HINTS:
        if hint in lower:
            return (status, f"Триггер: «{hint}»")
    return ("active", "Без негативных триггеров")


def _extract_name(html: str, inn: str) -> str | None:
    # Грубая эвристика. Ищем "<title>...{что-то с ИНН или организацией}...</title>"
    m = re.search(r"<title>(.*?)</title>", html, re.IGNORECASE | re.DOTALL)
    if m:
        title = re.sub(r"\s+", " ", m.group(1)).strip()
        if title and "fedresurs" not in title.lower():
            return title[:256]
    return None


def _count_lawsuits(html: str) -> int:
    """Очень грубо: число вхождений "сообщений|publication-card|search-result-item".

    Это даёт верхнюю границу, не реальную статистику. Реальный счётчик
    потребовал бы JS-рендеринг (Playwright) — пока остаёмся на эвристике.
    """
    if not html:
        return 0
    return min(
        html.lower().count("publication-card") + html.lower().count("search-result-item"),
        999,
    )


def _calc_multiplier(status: str, lawsuits: int) -> float:
    if status in ("bankruptcy", "liquidated"):
        return 0.85
    if status == "bankruptcy_initiated":
        return 0.90
    if status == "active":
        if lawsuits >= 20:
            return 0.90
        if lawsuits >= 5:
            return 0.95
        return 1.00
    return 1.00  # unknown


async def fetch_federresurs(inn: str) -> str | None:
    url = FEDRESURS_URL.format(inn=inn)
    async with httpx.AsyncClient(
        timeout=20.0, headers=DEFAULT_HEADERS, follow_redirects=True
    ) as client:
        try:
            resp = await client.get(url)
            resp.raise_for_status()
            return resp.text
        except Exception as exc:
            logger.warning("federresurs fetch failed for %s: %s", inn, exc)
            return None


async def assess_inn(inn: str) -> DeveloperRiskSnapshot:
    html = await fetch_federresurs(inn)
    if html is None:
        return DeveloperRiskSnapshot(
            inn=inn,
            name=None,
            federresurs_status="unknown",
            lawsuits_count=0,
            risk_multiplier=1.00,
            notes="Источник недоступен; multiplier не понижаем",
            raw_excerpt=None,
        )

    status, status_note = _classify_status(html)
    lawsuits = _count_lawsuits(html)
    multiplier = _calc_multiplier(status, lawsuits)
    name = _extract_name(html, inn)

    notes = f"{status_note} | lawsuits≈{lawsuits}"
    return DeveloperRiskSnapshot(
        inn=inn,
        name=name,
        federresurs_status=status,
        lawsuits_count=lawsuits,
        risk_multiplier=multiplier,
        notes=notes,
        raw_excerpt=html[:500] if html else None,
    )


async def upsert_snapshot(snap: DeveloperRiskSnapshot, dry_run: bool = False) -> None:
    if dry_run:
        return

    async with get_session() as session:
        if snap.name:
            # Сначала пробуем найти по INN
            existing = await session.execute(
                text("SELECT id, name FROM developers WHERE inn = :inn"),
                {"inn": snap.inn},
            )
            row = existing.first()
            if row:
                await session.execute(
                    text(
                        "UPDATE developers SET "
                        "federresurs_status = :st, lawsuits_count = :lc, "
                        "risk_multiplier = :rm, last_check_at = :now, notes = :n "
                        "WHERE id = :id"
                    ),
                    {
                        "st": snap.federresurs_status,
                        "lc": snap.lawsuits_count,
                        "rm": snap.risk_multiplier,
                        "now": datetime.now(timezone.utc),
                        "n": snap.notes,
                        "id": row[0],
                    },
                )
                return

            # Не нашли по INN — пробуем по name
            existing = await session.execute(
                text("SELECT id FROM developers WHERE name = :name"),
                {"name": snap.name},
            )
            row = existing.first()
            if row:
                await session.execute(
                    text(
                        "UPDATE developers SET "
                        "inn = :inn, federresurs_status = :st, lawsuits_count = :lc, "
                        "risk_multiplier = :rm, last_check_at = :now, notes = :n "
                        "WHERE id = :id"
                    ),
                    {
                        "inn": snap.inn,
                        "st": snap.federresurs_status,
                        "lc": snap.lawsuits_count,
                        "rm": snap.risk_multiplier,
                        "now": datetime.now(timezone.utc),
                        "n": snap.notes,
                        "id": row[0],
                    },
                )
                return

            # Совсем новый — вставка
            await session.execute(
                text(
                    "INSERT INTO developers "
                    "(name, inn, federresurs_status, lawsuits_count, risk_multiplier, last_check_at, notes) "
                    "VALUES (:name, :inn, :st, :lc, :rm, :now, :n)"
                ),
                {
                    "name": snap.name,
                    "inn": snap.inn,
                    "st": snap.federresurs_status,
                    "lc": snap.lawsuits_count,
                    "rm": snap.risk_multiplier,
                    "now": datetime.now(timezone.utc),
                    "n": snap.notes,
                },
            )
        else:
            # Имя не извлекли — храним только по INN с заглушкой
            await session.execute(
                text(
                    "INSERT INTO developers (name, inn, federresurs_status, lawsuits_count, risk_multiplier, last_check_at, notes) "
                    "VALUES (:name, :inn, :st, :lc, :rm, :now, :n) "
                    "ON CONFLICT (inn) WHERE inn IS NOT NULL DO UPDATE SET "
                    "federresurs_status = EXCLUDED.federresurs_status, "
                    "lawsuits_count = EXCLUDED.lawsuits_count, "
                    "risk_multiplier = EXCLUDED.risk_multiplier, "
                    "last_check_at = EXCLUDED.last_check_at, "
                    "notes = EXCLUDED.notes"
                ),
                {
                    "name": f"INN-{snap.inn}",
                    "inn": snap.inn,
                    "st": snap.federresurs_status,
                    "lc": snap.lawsuits_count,
                    "rm": snap.risk_multiplier,
                    "now": datetime.now(timezone.utc),
                    "n": snap.notes,
                },
            )


async def refresh_developer_by_inn(inn: str, dry_run: bool = False) -> DeveloperRiskSnapshot:
    """Главный публичный вход. Возвращает snapshot + кладёт в БД."""
    snap = await assess_inn(inn)
    await upsert_snapshot(snap, dry_run=dry_run)
    logger.info(
        "developer_risk inn=%s status=%s lawsuits=%d mult=%.2f",
        inn, snap.federresurs_status, snap.lawsuits_count, snap.risk_multiplier,
    )
    return snap


def main() -> int:
    parser = argparse.ArgumentParser(description="Refresh developer risk index by INN")
    parser.add_argument("--inn", required=True, help="ИНН организации")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в БД")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")
    snap = asyncio.run(refresh_developer_by_inn(args.inn, dry_run=args.dry_run))
    print(
        f"INN={snap.inn}  name={snap.name!r}  status={snap.federresurs_status}  "
        f"lawsuits={snap.lawsuits_count}  multiplier={snap.risk_multiplier:.2f}"
    )
    print(f"notes: {snap.notes}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
