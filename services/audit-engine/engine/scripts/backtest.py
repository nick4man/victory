"""Back-testing прошлых прогнозов аудита.

Сравнивает прогнозную стоимость объекта (на момент аудита) с фактической
стоимостью позже (из `price_history` или из более свежего аудита того же
ЖК/типа). Считает MAPE, RMSE, sign-accuracy, выдаёт Markdown-отчёт.

Запуск:
    python -m scripts.backtest --month 2026-03
    python -m scripts.backtest --since 2025-10-01 --until 2026-04-01
    python -m scripts.backtest --input pairs.json --dry-run  # оффлайн

Результат:
    SHARED/accuracy/<YYYY-MM>.md — Markdown-отчёт (или --output PATH).

Связанная политика (см. `agents/project-planner/SOUL.md §Правило 4`):
- MAPE > 20% → эскалация Боссу, пересмотр калибровки σ в MC.
- Sign-accuracy < 70% → серьёзная ошибка в логике verdict.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import statistics
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Iterable

logger = logging.getLogger("backtest")


# ---------------------------------------------------------------------------
# Pure-функции (тестируются без БД и без сети)
# ---------------------------------------------------------------------------


@dataclass
class Forecast:
    """Единица сравнения: прогноз ↔ фактическая цена в известную дату."""
    audit_id: str
    complex_name: str
    apartment_type: str
    audit_date: date
    horizon_years: float
    original_price: float
    growth_annual_pct: float
    verdict: str
    target_date: date
    projected_price: float
    actual_price: float

    @property
    def t_years(self) -> float:
        return (self.target_date - self.audit_date).days / 365.25

    @property
    def abs_pct_error(self) -> float:
        if self.actual_price <= 0:
            return math.inf
        return abs(self.projected_price - self.actual_price) / self.actual_price * 100.0

    @property
    def direction_correct(self) -> bool:
        """Совпало ли направление: был `buy`-вердикт → цена реально выросла.

        Flat-случай (цена не изменилась) считается совпадением с `neutral`/
        `hold`-вердиктом: обе стороны «не предсказали роста».
        """
        actual_grew = self.actual_price > self.original_price
        predicted_grew = self.verdict.lower() in ("buy", "yes", "✅", "favorable")
        return actual_grew == predicted_grew


def project_price(original: float, growth_annual_pct: float, t_years: float) -> float:
    """Проекция цены вперёд на `t_years` при постоянном росте."""
    return original * (1.0 + growth_annual_pct / 100.0) ** t_years


def mape(forecasts: Iterable[Forecast]) -> float | None:
    errors = [f.abs_pct_error for f in forecasts if math.isfinite(f.abs_pct_error)]
    return statistics.fmean(errors) if errors else None


def rmse(forecasts: Iterable[Forecast]) -> float | None:
    diffs = [
        (f.projected_price - f.actual_price) ** 2
        for f in forecasts
        if f.actual_price > 0
    ]
    return math.sqrt(statistics.fmean(diffs)) if diffs else None


def sign_accuracy(forecasts: Iterable[Forecast]) -> float | None:
    checked = list(forecasts)
    if not checked:
        return None
    hits = sum(1 for f in checked if f.direction_correct)
    return hits / len(checked) * 100.0


@dataclass
class BacktestResult:
    period_from: date
    period_to: date
    forecasts: list[Forecast] = field(default_factory=list)

    @property
    def n(self) -> int:
        return len(self.forecasts)

    @property
    def mape(self) -> float | None:
        return mape(self.forecasts)

    @property
    def rmse(self) -> float | None:
        return rmse(self.forecasts)

    @property
    def sign_accuracy(self) -> float | None:
        return sign_accuracy(self.forecasts)

    @property
    def worst(self) -> list[Forecast]:
        return sorted(
            self.forecasts, key=lambda f: f.abs_pct_error, reverse=True
        )[:5]


def render_markdown(result: BacktestResult) -> str:
    """Markdown-отчёт для SHARED/accuracy/<YYYY-MM>.md.

    Формат рассчитан на быстрое сканирование: шапка с 4 метриками,
    таблица по ЖК, таблица топ-5 худших случаев, итоговый вывод.
    """
    if result.n == 0:
        return (
            f"# Back-test {result.period_from:%Y-%m-%d} → {result.period_to:%Y-%m-%d}\n\n"
            "⚠️ Нет пар (прогноз/факт) для оценки. "
            "Проверь, что в `audit_archive` есть записи и что для этих ЖК "
            "заполнена `price_history` (или есть более свежий аудит того же объекта).\n"
        )

    lines = [
        f"# Back-test {result.period_from:%Y-%m-%d} → {result.period_to:%Y-%m-%d}",
        "",
        f"**Пар (прогноз ↔ факт):** {result.n}",
        f"**MAPE:** {result.mape:.2f}% "
        f"({'🚨 > 20%, пересмотр калибровки' if (result.mape or 0) > 20 else '✅ в норме'})",
        f"**RMSE:** {result.rmse:,.0f} ₽" if result.rmse else "**RMSE:** —",
        f"**Sign-accuracy (совпадение направления):** "
        f"{result.sign_accuracy:.1f}% "
        f"({'🚨 < 70%, ревизия verdict-логики' if (result.sign_accuracy or 0) < 70 else '✅ ок'})",
        "",
        "## Разбивка по ЖК",
        "",
        "| ЖК | Тип | N | MAPE, % | Sign, % |",
        "|---|---|---:|---:|---:|",
    ]
    groups: dict[tuple[str, str], list[Forecast]] = {}
    for f in result.forecasts:
        groups.setdefault((f.complex_name, f.apartment_type), []).append(f)
    for (cx, apt), items in sorted(groups.items()):
        g_mape = mape(items)
        g_sign = sign_accuracy(items)
        lines.append(
            f"| {cx} | {apt} | {len(items)} | "
            f"{g_mape:.1f} | {g_sign:.0f} |"
        )

    lines += [
        "",
        "## Топ-5 худших прогнозов",
        "",
        "| audit_date | target_date | ЖК | projected | actual | error, % |",
        "|---|---|---|---:|---:|---:|",
    ]
    for f in result.worst:
        lines.append(
            f"| {f.audit_date} | {f.target_date} | {f.complex_name} | "
            f"{f.projected_price:,.0f} | {f.actual_price:,.0f} | "
            f"{f.abs_pct_error:.1f} |"
        )

    lines += [
        "",
        "## Выводы и действия",
        "",
    ]
    notes: list[str] = []
    if result.mape and result.mape > 20:
        notes.append(
            "- 🚨 **MAPE > 20%**: откалибровать `mc_price_growth_std` на свежей "
            "`price_history`. Возможно, `price_growth_annual` в аудитах "
            "задавался без привязки к исторической волатильности."
        )
    if result.sign_accuracy and result.sign_accuracy < 70:
        notes.append(
            "- 🚨 **Sign-accuracy < 70%**: проверить пороги EI и логику verdict'а "
            "в `re-analyst`. Возможно, порог `EI_BUY` слишком консервативен/оптимистичен."
        )
    if not notes:
        notes.append("- ✅ Метрики в пределах нормы. Калибровка подтверждена.")
    lines += notes
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Загрузчики (DB / JSON)
# ---------------------------------------------------------------------------


def _parse_date(s: str) -> date:
    return datetime.strptime(s, "%Y-%m-%d").date()


def forecasts_from_pairs(pairs: list[dict]) -> list[Forecast]:
    """Построить `Forecast`-ы из plain-dict-пар (для оффлайн-режима)."""
    out: list[Forecast] = []
    for p in pairs:
        audit_dt = _parse_date(p["audit_date"])
        target_dt = _parse_date(p["target_date"])
        t_years = (target_dt - audit_dt).days / 365.25
        original = float(p["original_price"])
        growth = float(p["growth_annual_pct"])
        projected = p.get("projected_price") or project_price(original, growth, t_years)
        out.append(
            Forecast(
                audit_id=p.get("audit_id", ""),
                complex_name=p["complex_name"],
                apartment_type=p.get("apartment_type", "1BR"),
                audit_date=audit_dt,
                horizon_years=float(p.get("horizon_years", 5)),
                original_price=original,
                growth_annual_pct=growth,
                verdict=p.get("verdict", "neutral"),
                target_date=target_dt,
                projected_price=float(projected),
                actual_price=float(p["actual_price"]),
            )
        )
    return out


async def load_forecasts_from_db(since: date, until: date) -> list[Forecast]:
    """Собрать пары (аудит → фактическая цена) из БД за период.

    Факт ищется в таком приоритете:
    1. Самый свежий снапшот `price_history` для (complex, apartment_type)
       в окне (audit_date + 90d, audit_date + horizon*365d).
    2. Более свежий `audit_archive` для того же объекта (fallback).
    """
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from audit_engine.config import settings

    async_url = settings.database_url.replace(
        "postgresql://", "postgresql+asyncpg://"
    )
    engine = create_async_engine(async_url, echo=False)
    Session = async_sessionmaker(engine, expire_on_commit=False)

    out: list[Forecast] = []
    async with Session() as s:
        audits = await s.execute(
            text(
                "SELECT id, object_address AS complex_name, apartment_type, "
                "       audit_date, price_total, price_growth_annual, "
                "       horizon_years, verdict "
                "FROM audit_archive "
                "WHERE audit_date BETWEEN :s AND :u "
                "ORDER BY audit_date"
            ),
            {"s": since, "u": until},
        )
        for row in audits.mappings().all():
            fact_row = await s.execute(
                text(
                    "SELECT snapshot_date, price_total "
                    "FROM price_history "
                    "WHERE complex_name = :cx AND apartment_type = :apt "
                    "  AND snapshot_date > :ad + INTERVAL '90 days' "
                    "ORDER BY snapshot_date DESC LIMIT 1"
                ),
                {
                    "cx": row["complex_name"],
                    "apt": row["apartment_type"],
                    "ad": row["audit_date"],
                },
            )
            fact = fact_row.first()
            if not fact:
                fact_row = await s.execute(
                    text(
                        "SELECT audit_date AS snapshot_date, price_total "
                        "FROM audit_archive "
                        "WHERE object_address = :cx AND apartment_type = :apt "
                        "  AND audit_date > :ad + INTERVAL '90 days' "
                        "ORDER BY audit_date DESC LIMIT 1"
                    ),
                    {
                        "cx": row["complex_name"],
                        "apt": row["apartment_type"],
                        "ad": row["audit_date"],
                    },
                )
                fact = fact_row.first()
            if not fact:
                continue

            target_dt = fact.snapshot_date
            original = float(row["price_total"])
            growth = float(row["price_growth_annual"] or 0)
            t_years = (target_dt - row["audit_date"]).days / 365.25
            out.append(
                Forecast(
                    audit_id=str(row["id"]),
                    complex_name=row["complex_name"] or "",
                    apartment_type=row["apartment_type"] or "",
                    audit_date=row["audit_date"],
                    horizon_years=float(row["horizon_years"] or 5),
                    original_price=original,
                    growth_annual_pct=growth,
                    verdict=str(row["verdict"] or "neutral"),
                    target_date=target_dt,
                    projected_price=project_price(original, growth, t_years),
                    actual_price=float(fact.price_total),
                )
            )
    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _default_output(period_from: date) -> Path:
    return Path("SHARED/accuracy") / f"{period_from:%Y-%m}.md"


def _month_range(month: str) -> tuple[date, date]:
    y, m = (int(x) for x in month.split("-"))
    since = date(y, m, 1)
    if m == 12:
        until = date(y + 1, 1, 1) - timedelta(days=1)
    else:
        until = date(y, m + 1, 1) - timedelta(days=1)
    return since, until


async def _run(args) -> int:
    if args.input:
        logger.info("Offline: читаю %s", args.input)
        raw = json.loads(Path(args.input).read_text(encoding="utf-8"))
        forecasts = forecasts_from_pairs(raw)
        since = min((f.audit_date for f in forecasts), default=date.today())
        until = max((f.target_date for f in forecasts), default=date.today())
    else:
        if args.month:
            since, until = _month_range(args.month)
        else:
            since = _parse_date(args.since)
            until = _parse_date(args.until)
        logger.info("DB: загружаю аудиты с %s по %s", since, until)
        forecasts = await load_forecasts_from_db(since, until)

    result = BacktestResult(period_from=since, period_to=until, forecasts=forecasts)
    report = render_markdown(result)

    if args.dry_run:
        print(report)
        return 0

    out_path = Path(args.output) if args.output else _default_output(since)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(report, encoding="utf-8")
    logger.info(
        "✅ Отчёт: %s (n=%d, MAPE=%s%%)",
        out_path,
        result.n,
        f"{result.mape:.2f}" if result.mape is not None else "—",
    )

    # E3 — записываем результат в `backtest_runs` для исторических трендов.
    # При сбое БД продолжаем — отчёт-файл уже создан.
    if not args.no_db:
        try:
            await persist_backtest_run(result, report)
        except Exception as exc:
            logger.warning("persist_backtest_run failed: %s", exc)

    if result.mape is not None and result.mape > 20:
        logger.warning("🚨 MAPE > 20%% — пересмотр калибровки MC")
        return 3
    return 0


async def persist_backtest_run(result: BacktestResult, report: str) -> int:
    """Сохраняем результат back-test-а в БД для исторических трендов.

    Использует общий `get_session` (audit-engine config), поэтому требует
    что DATABASE_URL смотрит на live-Postgres. Возвращает id записи или
    -1 при пустом списке forecasts (запись всё равно создаётся для трекинга
    тишины).
    """
    from sqlalchemy import text as sa_text

    from audit_engine.db import get_session

    async with get_session() as session:
        result_row = await session.execute(
            sa_text(
                "INSERT INTO backtest_runs "
                "(started_at, finished_at, period_from, period_to, n_forecasts, "
                "mape, rmse, sign_accuracy, markdown_report, status) "
                "VALUES (now(), now(), :pf, :pt, :n, :mape, :rmse, :sa, :md, 'success') "
                "RETURNING id"
            ),
            {
                "pf": result.period_from,
                "pt": result.period_to,
                "n": result.n,
                "mape": result.mape,
                "rmse": result.rmse,
                "sa": result.sign_accuracy,
                "md": report,
            },
        )
        run_id = int(result_row.scalar() or -1)
        await session.commit()
    return run_id


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--month", help="YYYY-MM")
    g.add_argument("--input", type=Path, help="Offline JSON-файл с парами")
    ap.add_argument("--since", help="YYYY-MM-DD (если не указан --month)")
    ap.add_argument("--until", help="YYYY-MM-DD (если не указан --month)")
    ap.add_argument("--output", help="Куда писать Markdown-отчёт")
    ap.add_argument("--dry-run", action="store_true", help="Печатать в stdout, не писать файл")
    ap.add_argument("--no-db", action="store_true", help="Не записывать результат в backtest_runs")
    args = ap.parse_args()

    if args.month is None and args.input is None:
        if not (args.since and args.until):
            ap.error("--since и --until обязательны без --month / --input")

    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
