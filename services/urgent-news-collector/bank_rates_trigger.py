"""Bank Rates Trigger — парсинг ставок банков и DM-обзор Оксане (вт/чт 10:00 МСК).

Конвейер:
1. Запускает существующие плагины fetch_bank_offers (cbr-keyrate-derived + banki-ru)
   через `docker exec audit-v2-api python -m scripts.fetch_bank_offers …`. Они
   идемпотентно апсёртят в audit-v2-postgres.bank_offers.
2. Читает текущий снимок активных предложений, агрегирует MIN(rate_min) по
   (bank_name, product_type).
3. Сравнивает с прошлым прогоном (system_flags['bank_rates_last_snapshot']).
4. Собирает краткий Telegram-HTML обзор: ставка ЦБ + топ-5 ипотек + топ-3
   потребкредитов + изменения с прошлого вт/чт.
5. Шлёт в личку Оксане (chat_id 1272500574) через @victory62_bot напрямую.
6. Обновляет snapshot в system_flags для следующего прогона.

ENV:
- DRY_RUN=1 → не отправляет в TG, кладёт текст в /tmp/bank_rates_brief.html.
- CHANNEL_BOT_TOKEN — из agents/content-publisher/.env (тот же бот @victory62_bot).
"""

from __future__ import annotations

import json
import logging
import os
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone

import psycopg2
import requests
from psycopg2.extras import RealDictCursor

# Боевой каталог конвейера. До 11.09.26 путь вёл в openclaw
# (workspace-conveyor); openclaw переведён в архив, наружу больше не ходим.
CONVEYOR_HOME = os.environ.get("CONVEYOR_HOME", "/opt/victory-conveyor")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(SCRIPT_DIR)

socket.setdefaulttimeout(30)


def _load_env_file(path: str) -> None:
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if not sep:
                continue
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_env_file(os.path.join(SCRIPT_DIR, ".env"))

from content_db_utils import (  # noqa: E402
    _connect_news,
    get_system_flag,
    set_system_flag,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("bank_rates")

PIPELINE_LOG = os.path.join(CONVEYOR_HOME, "logs/bank_rates.jsonl")
DRY_RUN = os.getenv("DRY_RUN", "0") in ("1", "true", "True")

OKSANA_CHAT_ID = "1272500574"
TELEGRAM_BOT_TOKEN = os.getenv("CHANNEL_BOT_TOKEN")

CHANGE_THRESHOLD_PP = 0.05  # шум-фильтр для diff'а
TOP_MORTGAGES = 5
TOP_CONSUMER = 3

# product_type из bank_offers, которые считаются ипотечными.
MORTGAGE_TYPES = (
    "mortgage", "family_mortgage", "it_mortgage", "far_east_mortgage",
    "military_mortgage", "subsidized", "refinance",
)
CONSUMER_TYPES = ("consumer_loan",)

PRODUCT_LABEL = {
    "mortgage": "Стандартная",
    "family_mortgage": "Семейная",
    "it_mortgage": "IT",
    "far_east_mortgage": "Дальневосточная",
    "military_mortgage": "Военная",
    "subsidized": "Субсидированная",
    "refinance": "Рефинансирование",
    "consumer_loan": "Потребкредит",
}


# ---------- LOGGING ----------

def _log_pipeline_event(event: dict) -> None:
    try:
        os.makedirs(os.path.dirname(PIPELINE_LOG), exist_ok=True)
        record = {
            "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            **event,
        }
        with open(PIPELINE_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        logger.warning(f"pipeline-log write failed: {e}")


# ---------- FETCH (через docker exec плагины) ----------

def _run_fetcher(args: list[str]) -> int:
    cmd = ["docker", "exec", "audit-v2-api", "python", "-m", "scripts.fetch_bank_offers"] + args
    logger.info("Running: %s", " ".join(cmd))
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if proc.returncode != 0:
            logger.warning(f"fetcher rc={proc.returncode} stderr={proc.stderr[-500:]}")
        else:
            logger.info(f"fetcher ok: {(proc.stdout or '').strip()[-200:]}")
        return proc.returncode
    except Exception as e:
        logger.error(f"fetcher exception: {e}")
        return -1


# ---------- READ SNAPSHOT ----------

def _classify_by_name(product_type: str, product_name: str) -> str:
    """In-memory реклассификация — плагины (banki.ru, cbr-keyrate-derived,
    dom_rf) иногда ставят неверный product_type. Если в названии явно указана
    программа — она побеждает. Применяем для всех входных типов, кроме
    consumer_loan (потребкредит — отдельная категория, не путаем с ипотекой).
    """
    if not product_name or product_type == "consumer_loan":
        return product_type
    lo = product_name.lower()
    # Порядок важен: дальневосточная имеет приоритет перед общим subsidized.
    if "дальневосточ" in lo or "арктическ" in lo:
        return "far_east_mortgage"
    if "военн" in lo:
        return "military_mortgage"
    if "ит-специалист" in lo or "it-ипотека" in lo or "ит-ипотека" in lo:
        return "it_mortgage"
    if "семейн" in lo:
        return "family_mortgage"
    if "рефинанс" in lo:
        return "refinance"
    if "сельск" in lo:
        return "subsidized"
    return product_type


def _read_active_offers() -> dict:
    """Возвращает {key: {...}} где key='<bank>::<product_type>'.
    Для каждой группы берём MIN(rate_min), MIN-rate_max — это «лучшее» предложение группы.
    Перед агрегацией прогоняем in-memory реклассификацию product_type по тексту
    product_name (защита от багов плагинов)."""
    conn = _connect_news()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        cur.execute(
            """
            SELECT bank_name, product_type, product_name,
                   rate_min, rate_max
            FROM bank_offers
            WHERE is_active = TRUE
            """
        )
        # Ручная агрегация после реклассификации.
        buckets: dict[tuple[str, str], dict] = {}
        for r in cur.fetchall():
            ptype = _classify_by_name(r["product_type"], r["product_name"])
            key = (r["bank_name"], ptype)
            cur_min = float(r["rate_min"]) if r["rate_min"] is not None else None
            cur_max = float(r["rate_max"]) if r["rate_max"] is not None else None
            existing = buckets.get(key)
            if existing is None:
                buckets[key] = {"rate_min": cur_min, "rate_max": cur_max}
            else:
                if cur_min is not None and (existing["rate_min"] is None or cur_min < existing["rate_min"]):
                    existing["rate_min"] = cur_min
                if cur_max is not None and (existing["rate_max"] is None or cur_max < existing["rate_max"]):
                    existing["rate_max"] = cur_max
        # Конвертим buckets в формат для snapshot/diff.
        offers = {}
        for (bank_name, ptype), v in buckets.items():
            key = f"{bank_name}::{ptype}"
            offers[key] = {
                "bank_name": bank_name,
                "product_type": ptype,
                "rate_min": v["rate_min"],
                "rate_max": v["rate_max"],
            }
        # Текущая ключевая ставка.
        cur.execute(
            "SELECT cbr_key_rate FROM macro_economics WHERE cbr_key_rate IS NOT NULL ORDER BY date DESC LIMIT 1"
        )
        row = cur.fetchone()
        cbr_key_rate = float(row["cbr_key_rate"]) if row and row.get("cbr_key_rate") else None
        return {"offers": offers, "cbr_key_rate": cbr_key_rate}
    finally:
        cur.close()
        conn.close()


# ---------- DIFF ----------

def _compute_changes(prev: dict, curr: dict) -> list[dict]:
    prev_offers = (prev or {}).get("offers") or {}
    curr_offers = curr.get("offers") or {}
    changes = []
    keys = set(prev_offers) | set(curr_offers)
    for key in keys:
        p = prev_offers.get(key)
        c = curr_offers.get(key)
        if c and not p:
            changes.append({"key": key, "kind": "new", "curr_rate": c["rate_min"]})
        elif p and not c:
            changes.append({"key": key, "kind": "gone", "prev_rate": p["rate_min"]})
        elif p and c:
            pr, cr = p.get("rate_min"), c.get("rate_min")
            if pr is None or cr is None:
                continue
            delta = round(cr - pr, 2)
            if abs(delta) >= CHANGE_THRESHOLD_PP:
                changes.append({
                    "key": key, "kind": "changed",
                    "prev_rate": pr, "curr_rate": cr, "delta_pp": delta,
                })
    # Сортировка: сильные изменения первыми
    changes.sort(key=lambda x: -abs(x.get("delta_pp", 0) or 0))
    return changes


# ---------- BRIEF ----------

def _format_rate(rate_min: float | None, rate_max: float | None) -> str:
    if rate_min is None:
        return "—"
    if rate_max is not None and rate_max > rate_min + 0.01:
        return f"{rate_min:.2f}–{rate_max:.2f}%"
    return f"{rate_min:.2f}%"


def _short_bank(name: str) -> str:
    """Сокращает длинные названия для красивого шапки."""
    repl = {
        "Сбербанк": "Сбер",
        "Sberbank": "Сбер",
        "Сбер": "Сбер",
        "Альфа-Банк": "Альфа",
        "Alfa-Bank": "Альфа",
        "Россельхозбанк": "РСХБ",
        "Газпромбанк": "ГПБ",
        "Совкомбанк": "Совком",
        "Банк ДОМ.РФ": "ДОМ.РФ",
        "Банк Дом.РФ": "ДОМ.РФ",
        "Рынок (ориентир)": "Ориентир",
    }
    return repl.get(name, name)


def _build_brief(snapshot: dict, changes: list[dict], is_first_run: bool) -> str:
    weekday = datetime.now().strftime("%a %d.%m").replace("Tue", "ВТ").replace("Thu", "ЧТ")
    cbr = snapshot.get("cbr_key_rate")
    offers = snapshot.get("offers") or {}

    # «Рынок (ориентир)» — synthetic-данные от cbr-keyrate-derived; полезны для
    # audit-engine, но в обзоре читателю нужен реальный банк. Исключаем.
    SYNTHETIC_BANKS = {"Рынок (ориентир)"}

    # Топ ипотека: сортировка по rate_min asc, фильтр MORTGAGE_TYPES.
    mortgage_offers = [
        v for v in offers.values()
        if v["product_type"] in MORTGAGE_TYPES
        and v["rate_min"] is not None
        and v["bank_name"] not in SYNTHETIC_BANKS
    ]
    mortgage_offers.sort(key=lambda v: v["rate_min"])
    top_mortgage = mortgage_offers[:TOP_MORTGAGES]

    # Топ потребкредит.
    consumer_offers = [
        v for v in offers.values()
        if v["product_type"] in CONSUMER_TYPES
        and v["rate_min"] is not None
        and v["bank_name"] not in SYNTHETIC_BANKS
    ]
    consumer_offers.sort(key=lambda v: v["rate_min"])
    top_consumer = consumer_offers[:TOP_CONSUMER]

    lines = [f"📊 <b>Сводка ставок</b> · {weekday}", ""]
    if cbr is not None:
        lines.append(f"Ключевая ставка ЦБ: <b>{cbr:.2f}%</b>")
        lines.append("")

    # «Лучшее предложение в каждой категории» вместо глобального топа —
    # иначе все 5 строк забиваются дальневосточной ипотекой по 2%.
    by_category: dict[str, dict] = {}
    for v in mortgage_offers:
        ptype = v["product_type"]
        if ptype not in by_category or v["rate_min"] < by_category[ptype]["rate_min"]:
            by_category[ptype] = v

    # Сортируем категории в осмысленном порядке: стандарт первым (он-же обычно
    # самый высокий, привлекает внимание), потом льготные по возрастанию ставки.
    category_order = ["mortgage", "family_mortgage", "it_mortgage",
                      "subsidized", "far_east_mortgage", "military_mortgage", "refinance"]
    ordered_offers = []
    for ptype in category_order:
        if ptype in by_category:
            ordered_offers.append(by_category[ptype])

    lines.append("🏠 <b>Лучшие ипотечные ставки по категориям</b>")
    if ordered_offers:
        for v in ordered_offers[:TOP_MORTGAGES]:
            label = PRODUCT_LABEL.get(v["product_type"], v["product_type"])
            rate = _format_rate(v["rate_min"], v["rate_max"])
            lines.append(f"• {label}: <b>{rate}</b> ({_short_bank(v['bank_name'])})")
    else:
        lines.append("(нет активных ипотечных предложений в БД)")
    lines.append("")

    lines.append(f"💳 <b>Потребкредиты (топ-{TOP_CONSUMER})</b>")
    if top_consumer:
        for i, v in enumerate(top_consumer, 1):
            rate = _format_rate(v["rate_min"], v["rate_max"])
            lines.append(f"{i}. {_short_bank(v['bank_name'])}: <b>{rate}</b>")
    else:
        lines.append("(нет активных потребкредитов в БД)")
    lines.append("")

    if is_first_run:
        lines.append("📈 <b>Изменения с прошлого прогона:</b>")
        lines.append("Это первый запуск — базовая точка для сравнения зафиксирована.")
    elif not changes:
        lines.append("📈 <b>Изменения с прошлого прогона:</b>")
        lines.append("Без значимых изменений за период.")
    else:
        lines.append(f"📈 <b>Изменения с прошлого прогона ({len(changes)}):</b>")
        for ch in changes[:10]:
            bank, ptype = ch["key"].split("::", 1)
            label = PRODUCT_LABEL.get(ptype, ptype)
            short = f"{_short_bank(bank)} · {label}"
            if ch["kind"] == "changed":
                arrow = "↑" if ch["delta_pp"] > 0 else "↓"
                lines.append(
                    f"— {short}: {arrow} {abs(ch['delta_pp']):.2f} п.п. "
                    f"(с {ch['prev_rate']:.2f} → {ch['curr_rate']:.2f})"
                )
            elif ch["kind"] == "new":
                lines.append(f"— {short}: новое предложение, <b>{ch['curr_rate']:.2f}%</b>")
            elif ch["kind"] == "gone":
                lines.append(f"— {short}: больше не активно (было {ch['prev_rate']:.2f}%)")
        if len(changes) > 10:
            lines.append(f"… и ещё {len(changes) - 10}.")
    lines.append("")

    lines.append('<i>Хочешь полную сводку — ответь словом «детально», пришлю все активные предложения.</i>')
    return "\n".join(lines)


# ---------- TELEGRAM DM ----------

def _telegram_send_dm(text: str, chat_id: str) -> int | None:
    if not TELEGRAM_BOT_TOKEN:
        logger.error("CHANNEL_BOT_TOKEN missing — cannot DM.")
        return None
    api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    for attempt in range(3):
        try:
            resp = requests.post(api_url, data=data, timeout=30)
            if resp.status_code == 200 and resp.json().get("ok"):
                return resp.json()["result"]["message_id"]
            logger.warning(f"send DM attempt {attempt+1}: {resp.status_code} {resp.text[:200]}")
        except Exception as e:
            logger.warning(f"send DM attempt {attempt+1} exception: {e}")
        if attempt < 2:
            time.sleep(3)
    return None


# ---------- CIRCUIT BREAKER ----------

def _check_circuit_breaker() -> bool:
    """Возвращает True если можно отправлять, False если CB активен."""
    flag = get_system_flag("bank_rates_dm_disabled")
    if flag and flag.get("disabled") is True:
        logger.warning(f"DM disabled by circuit-breaker: {flag.get('reason')}")
        return False
    return True


def _trip_circuit_breaker(reason: str) -> None:
    set_system_flag("bank_rates_dm_disabled", {
        "disabled": True,
        "reason": reason,
        "tripped_at": datetime.now(timezone.utc).isoformat(),
    })


# ---------- ENTRYPOINT ----------

def run_bank_rates_pipeline() -> None:
    logger.info("📊 Starting Bank Rates Pipeline (DRY_RUN=%s)", DRY_RUN)

    if not DRY_RUN and not _check_circuit_breaker():
        _log_pipeline_event({"action": "skipped_circuit_breaker"})
        return

    # 1. Запуск парсеров (не критично если что-то упадёт — используем что есть в БД).
    rc1 = _run_fetcher(["--source", "cbr-keyrate-derived"])
    rc2 = _run_fetcher(["--source", "banki-ru"])

    # 2. Снимок.
    snapshot = _read_active_offers()
    if not snapshot.get("offers"):
        logger.error("No active offers in DB — aborting.")
        _log_pipeline_event({"action": "no_offers", "fetcher_rc": [rc1, rc2]})
        return

    # 3. Diff.
    prev = get_system_flag("bank_rates_last_snapshot")
    is_first_run = not prev
    changes = _compute_changes(prev or {}, snapshot)
    logger.info(f"snapshot: {len(snapshot['offers'])} offers, changes: {len(changes)}, first_run: {is_first_run}")

    # 4. Сборка обзора.
    text = _build_brief(snapshot, changes, is_first_run)
    logger.info(f"brief length: {len(text)} chars")

    # 5. Отправка/dry-run.
    if DRY_RUN:
        out_path = "/tmp/bank_rates_brief.html"
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(text)
        logger.info(f"DRY_RUN → {out_path}")
        _log_pipeline_event({
            "action": "dry_run",
            "n_offers": len(snapshot["offers"]),
            "n_changes": len(changes),
            "fetcher_rc": [rc1, rc2],
        })
        return

    msg_id = _telegram_send_dm(text, OKSANA_CHAT_ID)
    if msg_id is None:
        logger.error("DM failed.")
        # Считаем подряд неудачные попытки в jsonl для CB.
        try:
            failed_in_a_row = 1
            if os.path.exists(PIPELINE_LOG):
                with open(PIPELINE_LOG, encoding="utf-8") as fh:
                    last_lines = fh.readlines()[-3:]
                for ln in reversed(last_lines):
                    try:
                        rec = json.loads(ln)
                        if rec.get("action") == "send_failed":
                            failed_in_a_row += 1
                        else:
                            break
                    except Exception:
                        break
            if failed_in_a_row >= 3:
                _trip_circuit_breaker(f"3 consecutive DM failures (chat_id={OKSANA_CHAT_ID})")
        except Exception:
            pass
        _log_pipeline_event({
            "action": "send_failed",
            "n_offers": len(snapshot["offers"]),
            "n_changes": len(changes),
        })
        return

    # 6. Сохранение snapshot.
    set_system_flag("bank_rates_last_snapshot", snapshot)

    logger.info(f"✅ Sent to Оксана: msg_id={msg_id}")
    _log_pipeline_event({
        "action": "sent",
        "chat_id": OKSANA_CHAT_ID,
        "msg_id": msg_id,
        "n_offers": len(snapshot["offers"]),
        "n_changes": len(changes),
        "fetcher_rc": [rc1, rc2],
        "first_run": is_first_run,
    })


if __name__ == "__main__":
    # postgres-local (5432) или audit-v2-postgres (5433) могут быть временно
    # недоступны (контейнер падал 2026-05-14) — тогда тихо выходим exit 0,
    # cron не шлёт fail-alert. WARNING остаётся в логе для постфактум-разбора.
    try:
        run_bank_rates_pipeline()
    except psycopg2.OperationalError as e:
        logger.warning(
            "Production DB unreachable — skipping bank_rates run: %s",
            str(e).split("\n")[0],
        )
        sys.exit(0)
