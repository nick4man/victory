"""Недельная сводка расхода LLM по телеметрии llm_usage.jsonl (13.10.26).

Читает лог, который пишет pipeline_utils.complete_with_fallbacks на каждую
попытку вызова (поля: ts, chain, provider, model, ok, latency_s, paid, err),
и отвечает на вопросы: живы ли бесплатные звенья, как часто доезжаем до
платного хвоста, не упёрлись ли в бюджет, что за ошибки преобладают.

Запуск:
    python3 llm_usage_report.py              # за 7 дней, в stdout
    python3 llm_usage_report.py --days 30
    python3 llm_usage_report.py --telegram   # краткая сводка главреду

Пустой или отсутствующий лог — не ошибка (код 0): значит, вызовов не было.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from pipeline_utils import _notify_telegram, fmt_ddmmyy, llm_usage_log_path  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Отказы платного звена по бюджету помечаются этой строкой в поле err —
# см. complete_with_fallbacks в pipeline_utils.py.
BUDGET_EXHAUSTED_ERR = "paid budget exhausted"


def _parse_ts(ts) -> datetime | None:
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def load_records(path: str, days: int) -> tuple[list[dict], int]:
    """Записи лога за окно days суток + число битых строк (их не роняем —
    лог append-only, половинчатая строка при падении процесса неизбежна)."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    records: list[dict] = []
    broken = 0
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                broken += 1
                continue
            if not isinstance(rec, dict):
                broken += 1
                continue
            ts = _parse_ts(rec.get("ts"))
            if ts is not None and ts < cutoff:
                continue
            records.append(rec)
    return records, broken


def summarize(records: list[dict]) -> dict:
    """Чистая агрегация — без IO, чтобы было что гонять в тестах."""
    total = len(records)
    ok_count = sum(1 for r in records if r.get("ok"))
    paid_count = sum(1 for r in records if r.get("paid"))
    paid_ok = sum(1 for r in records if r.get("paid") and r.get("ok"))
    budget_exhausted = sum(
        1 for r in records if str(r.get("err", "")).startswith(BUDGET_EXHAUSTED_ERR)
    )

    per_model: dict[str, dict] = defaultdict(
        lambda: {"calls": 0, "ok": 0, "latencies": [], "paid": False}
    )
    for r in records:
        label = f"{r.get('provider', '?')}/{r.get('model', '?')}"
        m = per_model[label]
        m["calls"] += 1
        m["ok"] += 1 if r.get("ok") else 0
        m["paid"] = m["paid"] or bool(r.get("paid"))
        lat = r.get("latency_s")
        if isinstance(lat, (int, float)) and not isinstance(lat, bool):
            m["latencies"].append(float(lat))

    per_chain: dict[str, dict] = defaultdict(lambda: {"calls": 0, "ok": 0})
    for r in records:
        c = per_chain[str(r.get("chain", "?"))]
        c["calls"] += 1
        c["ok"] += 1 if r.get("ok") else 0

    # Причины ошибок нормализуем до первых 80 символов: в хвосте там обычно
    # уникальный request-id, из-за которого Counter расползается в шум.
    errors = Counter(
        str(r.get("err", "?"))[:80]
        for r in records if not r.get("ok")
    )

    return {
        "total": total,
        "ok": ok_count,
        "paid": paid_count,
        "paid_ok": paid_ok,
        "budget_exhausted": budget_exhausted,
        "per_model": dict(per_model),
        "per_chain": dict(per_chain),
        "top_errors": errors.most_common(5),
    }


def _pct(part: int, whole: int) -> str:
    return f"{(100.0 * part / whole):.1f}%" if whole else "—"


def format_report(summary: dict, days: int, broken: int) -> str:
    lines = []
    lines.append(
        f"Сводка расхода LLM за {days} дн. (на {fmt_ddmmyy(datetime.now(timezone.utc))})"
    )
    total = summary["total"]
    free = total - summary["paid"]
    lines.append(
        f"Всего вызовов: {total} · успешных {_pct(summary['ok'], total)}"
        f" · бесплатных {_pct(free, total)}"
    )
    lines.append(f"Сработки платного хвоста (paid+ok): {summary['paid_ok']}")
    lines.append(f"Отказы по бюджету ({BUDGET_EXHAUSTED_ERR!r}): {summary['budget_exhausted']}")
    if broken:
        lines.append(f"(битых строк лога пропущено: {broken})")

    lines.append("\nПо цепочкам:")
    for chain in sorted(summary["per_chain"]):
        c = summary["per_chain"][chain]
        lines.append(f"  {chain:12} {c['calls']:6} вызовов, ok {_pct(c['ok'], c['calls'])}")

    lines.append("\nПо моделям (вызовы · ok% · ср. латентность):")
    rows = sorted(summary["per_model"].items(),
                  key=lambda kv: kv[1]["calls"], reverse=True)
    for label, m in rows:
        avg = f"{sum(m['latencies']) / len(m['latencies']):.1f}s" if m["latencies"] else "—"
        paid_mark = " 💸" if m["paid"] else ""
        lines.append(f"  {label:55} {m['calls']:5}  {_pct(m['ok'], m['calls']):>6}  {avg}{paid_mark}")

    if summary["top_errors"]:
        lines.append("\nТоп-5 причин ошибок:")
        for err, n in summary["top_errors"]:
            lines.append(f"  {n:5}  {err}")
    return "\n".join(lines)


def format_telegram(summary: dict, days: int) -> str:
    total = summary["total"]
    free = total - summary["paid"]
    return (
        f"📊 <b>Расход LLM за {days} дн.</b>\n\n"
        f"<b>Вызовов:</b> {total} · ok {_pct(summary['ok'], total)}"
        f" · бесплатных {_pct(free, total)}\n"
        f"<b>Платный хвост:</b> {summary['paid_ok']} сработок,"
        f" {summary['budget_exhausted']} отказов по бюджету"
    )


def _load_env(path: str) -> None:
    """Подтянуть .env рядом со скриптом (токены Telegram для --telegram).
    setdefault: реальное окружение cron важнее файла."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--days", type=int, default=7, help="окно в сутках (по умолчанию 7)")
    parser.add_argument("--telegram", action="store_true",
                        help="отправить краткую сводку главреду через _notify_telegram")
    args = parser.parse_args()

    _load_env(os.path.join(SCRIPT_DIR, ".env"))

    # Путь читаем в момент вызова: .env подтягивается после import pipeline_utils.
    path = llm_usage_log_path()
    if not os.path.exists(path):
        print(f"Лог расхода LLM не найден: {path} — вызовов за окно не было.")
        return 0

    try:
        records, broken = load_records(path, args.days)
    except Exception as e:
        # Лог не читается — это не повод ронять cron-задачу ненулевым кодом:
        # конвейер живой, сломалась только сводка. Ругаемся и выходим.
        logger.error("[usage-report] не могу прочитать %s: %s", path, e)
        print(f"Не могу прочитать лог {path}: {e}")
        return 0

    if not records:
        print(f"В логе {path} нет записей за последние {args.days} дн.")
        return 0

    summary = summarize(records)
    print(format_report(summary, args.days, broken))

    if args.telegram:
        _notify_telegram(format_telegram(summary, args.days))
        logger.info("[usage-report] сводка отправлена в Telegram (если заданы токены)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
