"""Бэктест фильтра срочных новостей на исторических данных.

Прогоняет текущий промпт-классификатор (`urgent_collector.analyze_news_item`)
и гейт (`urgent_relevance.gate_urgent`) по уже накопленным строкам
`urgent_events` и показывает, что изменилось бы в канале. Нужен всякий раз,
когда трогаешь критерии URGENT: без замера легко ужесточить фильтр до нуля и
не заметить, что вместе с мусором ушли решения по ставке.

Меряет обе стороны, и это принципиально:

  A. Ложноположительные — что из реально опубликованного отсеется сейчас.
  B. Ложноотрицательные — что из DIGEST с профильной лексикой поднялось бы
     в URGENT. Без этой половины бэктест бессмысленен.

Из `details` вырезается блок «AI Analysis (…)» — вердикт прошлого прогона
классификатора. Без этого модель читает готовый ответ и бэктест врёт.

Запуск:
    IT/venv/bin/python3 backtest_urgent_relevance.py
    IT/venv/bin/python3 backtest_urgent_relevance.py --days 14 --json out.json

Стоит реальных LLM-вызовов (по одному на событие, см. MAIN_MODEL_CHAIN в
pipeline_utils), поэтому по умолчанию ограничен последними 30 днями.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import psycopg2  # noqa: E402
from psycopg2.extras import RealDictCursor  # noqa: E402

from urgent_collector import RSS_SOURCES, analyze_news_item  # noqa: E402
from urgent_relevance import gate_urgent  # noqa: E402

# \s* съедало бы \n\n перед «AI Analysis», и для пустого Summary группа
# захватывала вердикт прежнего классификатора — харнесс мерил сам себя.
# [ \t]* останавливается на переводе строки и оставляет разделитель на месте.
SUMMARY_RE = re.compile(r"Summary:[ \t]*(.*?)(?:\n\nAI Analysis|\Z)", re.DOTALL)
SOURCE_RE = re.compile(r"Source:\s*(.+)")

SOURCE_WEIGHTS = {s["name"]: s.get("weight", "medium") for s in RSS_SOURCES}

# Лексика недвижимости — ею отбирается выборка для поиска ложноотрицательных.
RE_LEXICON = (
    "ипотек", "жиль", "недвижим", "ключев%ставк", "квартир",
    "застройщик", "аренд", "налог", "кадастр", "эскроу",
)


def _load_env(path: str) -> None:
    if not os.path.exists(path):
        return
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def connect():
    return psycopg2.connect(
        host=os.getenv("NEWS_DB_HOST") or os.getenv("DB_HOST", "localhost"),
        port=os.getenv("NEWS_DB_PORT") or "5433",
        dbname=os.getenv("NEWS_DB_NAME") or os.getenv("DB_NAME", "re_audit"),
        user=os.getenv("NEWS_DB_USER") or os.environ["DB_USER"],
        password=os.getenv("NEWS_DB_PASSWORD") or os.environ["DB_PASSWORD"],
    )


def fetch(sql: str, params: tuple) -> list[dict]:
    conn = connect()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute(sql, params)
    rows = [dict(r) for r in cur.fetchall()]
    cur.close()
    conn.close()
    return rows


def strip_prior_verdict(details: str) -> tuple[str, str]:
    """Вернуть (summary, source), отрезав вердикт прошлого классификатора."""
    details = details or ""
    match = SUMMARY_RE.search(details)
    summary = (match.group(1) if match else details).strip()
    source_match = SOURCE_RE.search(details)
    source = source_match.group(1).strip() if source_match else "Unknown"
    return summary, source


def evaluate(row: dict) -> dict:
    summary, source = strip_prior_verdict(row["details"])
    try:
        result = analyze_news_item(
            row["headline"], summary, source, SOURCE_WEIGHTS.get(source, "medium")
        )
    except Exception as e:  # сеть/квота — не роняем весь прогон
        return {
            "id": row["id"], "headline": row["headline"], "source": source,
            "old_tier": row["relevance_tier"], "old_type": row["event_type"],
            "new_tier": "ERROR", "new_type": "ERROR", "gate": False,
            "gate_reason": f"error:{e}"[:80], "final_urgent": False, "reasoning": "",
        }
    passes, reason = gate_urgent(result.event_type, row["headline"])
    return {
        "id": row["id"], "headline": row["headline"], "source": source,
        "old_tier": row["relevance_tier"], "old_type": row["event_type"],
        "new_tier": result.relevance_tier, "new_type": result.event_type,
        "gate": passes, "gate_reason": reason,
        "final_urgent": result.relevance_tier == "URGENT" and passes,
        "reasoning": result.reasoning[:200],
    }


def run(rows: list[dict], workers: int) -> list[dict]:
    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(evaluate, rows))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--days", type=int, default=30, help="окно истории (по умолчанию 30)")
    parser.add_argument("--limit-digest", type=int, default=120,
                        help="сколько DIGEST-событий проверять на ложноотрицательные")
    parser.add_argument("--workers", type=int, default=6, help="параллельных LLM-вызовов")
    parser.add_argument("--json", dest="json_path", help="куда сложить полный результат")
    args = parser.parse_args()

    _load_env(os.path.join(SCRIPT_DIR, ".env"))
    window = f"{args.days} days"

    published = fetch(
        """
        SELECT id, headline, details, relevance_tier, event_type
        FROM urgent_events
        WHERE relevance_tier = 'URGENT' AND published_to_tg = TRUE
          AND created_at > now() - %s::interval
        ORDER BY created_at DESC
        """,
        (window,),
    )
    # Паттерны идут параметром, а не в текст запроса: literal '%ипотек%'
    # внутри SQL psycopg2 принимает за собственный плейсхолдер.
    digest = fetch(
        """
        SELECT id, headline, details, relevance_tier, event_type
        FROM urgent_events
        WHERE relevance_tier = 'DIGEST'
          AND created_at > now() - %s::interval
          AND headline ILIKE ANY(%s)
        ORDER BY created_at DESC
        LIMIT %s
        """,
        (window, [f"%{w}%" for w in RE_LEXICON], args.limit_digest),
    )

    print(f"A. Ранее опубликованные: {len(published)}", flush=True)
    res_published = run(published, args.workers)
    print(f"B. DIGEST с профильной лексикой: {len(digest)}", flush=True)
    res_digest = run(digest, args.workers)

    kept = [r for r in res_published if r["final_urgent"]]
    print(f"\n=== A. Из {len(res_published)} опубликованных остаётся {len(kept)} ===")
    for r in kept:
        print(f"  + [{r['new_type']}] {r['headline'][:88]}")

    print("\n--- причины отсева ---")
    dropped = (
        r["gate_reason"] if not r["gate"] else f"tier={r['new_tier']}"
        for r in res_published if not r["final_urgent"]
    )
    for reason, n in Counter(dropped).most_common():
        print(f"  {n:4}  {reason}")

    promoted = [r for r in res_digest if r["final_urgent"]]
    print(f"\n=== B. Из {len(res_digest)} DIGEST поднялось бы {len(promoted)} ===")
    for r in promoted:
        print(f"  ^ [{r['new_type']}] {r['headline'][:88]}")

    errors = [r for r in res_published + res_digest if r["new_tier"] == "ERROR"]
    if errors:
        print(f"\n!! классификатор упал на {len(errors)} событиях — результат неполный")

    print(f"\nИтого за {args.days} дн.: было {len(res_published)}, "
          f"стало {len(kept) + len(promoted)}")

    if args.json_path:
        with open(args.json_path, "w", encoding="utf-8") as fh:
            json.dump({"published": res_published, "digest": res_digest},
                      fh, ensure_ascii=False, indent=1)
        print(f"JSON: {args.json_path}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
