"""Еженедельный дайджест рынка недвижимости — автономный конвейер.

Запускается каждый понедельник в 09:00 МСК (06:00 UTC) через cron-job
«Market Digest Pipeline (Monday)» (id 9a713339-… в cron/jobs.json архива openclaw).

Логика:
1. Собирает факты прошедшей недели:
   - urgent_events за 7 дней (audit-v2-postgres:5433/news-DB)
   - RSS-обзор недели (те же 7 источников что у urgent_collector, без LLM-классификации)
   - Макро-данные (cbr_key_rate, inflation, mortgage_rate) и свежие банковские оферы
2. Подгружает party-line — последние market_digest посты, через get_party_line
   (триграммный поиск по postgres-local.posts_queue).
3. Генерирует JSON-дайджест через Omniroute (cc/claude-sonnet-4-5-20250929):
   {body_html, topic_hashtags, short_summary, consistency_check}.
4. Прогоняет body через sanitize_body_html, добавляет BRAND_TAGS + filter_topic_hashtags.
5. Кладёт пост в production posts_queue (postgres-local) со status='SCHEDULED'
   через enqueue_urgent_post — publisher_bot подхватит за ≤5 мин.

Циркут-брейкер: system_flags['digest_disabled'] (не пересекается с urgent).
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
from datetime import datetime, timedelta, timezone

import socket

import feedparser
import psycopg2
import requests

# feedparser использует urllib без таймаута — без socket-defaults один медленный
# RSS-источник (например, rbc.ru) виснет навсегда. 15 сек на запрос достаточно.
socket.setdefaulttimeout(15)
from psycopg2.extras import RealDictCursor

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(SCRIPT_DIR)


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

# Боевой каталог конвейера. До 11.09.26 путь вёл в openclaw
# (workspace-conveyor); openclaw переведён в архив, наружу больше не ходим.
CONVEYOR_HOME = os.environ.get("CONVEYOR_HOME", "/opt/victory-conveyor")
# Подцепляем токен бота из publisher's .env (там же канал и whitelist).

from content_db_utils import (  # noqa: E402
    enqueue_urgent_post,
    get_party_line,
    get_system_flag,
    set_system_flag,
)
from pipeline_utils import (  # noqa: E402
    BRAND_TAGS,
    build_site_footer,
    complete_with_fallbacks,
    fallback_site_url,
    filter_topic_hashtags,
    format_prior_positions,
    mirror_to_victory,
    notify_failure,
    sanitize_body_html,
)
from urgent_collector import RSS_SOURCES  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("weekly_digest")


def _fmt_ddmmyy(d) -> str:
    """Format a date/datetime/ISO-string as dd.MM.yy (project standard).

    Accepts datetime.date, datetime.datetime, ISO-string ('2026-05-18'),
    or None. Empty/None → '?'. Unparseable strings → returned as-is so
    bugs are visible rather than silently masked. Use this everywhere
    dates render into user-facing text (TG posts, /news article bodies).
    """
    if not d:
        return "?"
    if hasattr(d, "strftime"):
        return d.strftime("%d.%m.%y")
    try:
        return datetime.fromisoformat(str(d)).strftime("%d.%m.%y")
    except (ValueError, TypeError):
        return str(d)


PIPELINE_LOG = os.path.join(CONVEYOR_HOME, "logs/weekly_digest.log")
PUBLISHED_DIR = os.path.join(CONVEYOR_HOME, "published")

# Telegram Bot API — для длинных дайджестов публикуем серией с reply-цепочкой
# напрямую, минуя publisher_bot (он умеет только одно сообщение). urgent-посты
# по-прежнему идут через publisher_bot.
TELEGRAM_BOT_TOKEN = os.getenv("CHANNEL_BOT_TOKEN")
TELEGRAM_CHANNEL = os.getenv("RZNVICTORY_CHANNEL", "@rznvictory")

# News DB (audit-v2-postgres:5433) — urgent_events, macro_economics, bank_offers.
NEWS_DB_HOST = os.getenv("NEWS_DB_HOST", "localhost")
NEWS_DB_PORT = os.getenv("NEWS_DB_PORT", "5433")
NEWS_DB_NAME = os.getenv("NEWS_DB_NAME", "re_audit")
NEWS_DB_USER = os.getenv("NEWS_DB_USER", os.environ["DB_USER"])
NEWS_DB_PASSWORD = os.getenv("NEWS_DB_PASSWORD", os.environ["DB_PASSWORD"])

# Дайджест генерится через pipeline_utils.complete_with_fallbacks (in-process
# fallback-цепочка). DIGEST_TRIGGER_MODEL — опциональный single-model override.
DIGEST_TRIGGER_MODEL_OVERRIDE = os.getenv("DIGEST_TRIGGER_MODEL")

WEEK_DAYS = 7

# Чат для технических уведомлений о провале. В @rznvictory такое слать нельзя,
# поэтому без переменной notify_failure ограничится файлом-следом.
DIGEST_ALERT_CHAT_ID = os.getenv("DIGEST_ALERT_CHAT_ID")


# ---------- ИДЕМПОТЕНТНОСТЬ ----------
# Крон бьёт по скрипту 21 раз в неделю (пн 06–20, вт 06–12), догоняя
# пропущенный выпуск. Значит решение «нужен ли дайджест» принимает сам скрипт,
# а не расписание.

def week_anchor(now: datetime) -> datetime:
    """Ближайший прошедший понедельник 00:00 UTC — начало текущей «недели выпуска».

    Всё, что опубликовано после этого момента, считается выпуском этой недели.
    """
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    monday = now - timedelta(days=now.weekday())
    return monday.replace(hour=0, minute=0, second=0, microsecond=0)


def digest_published_since(anchor: datetime) -> dict | None:
    """Вернуть сведения о выпуске этой недели, либо None.

    Два источника, именно в этом порядке:

    1. system_flags['digest_last_published'] — маркер, который пишется сразу
       после успеха publish_thread, ДО enqueue_urgent_post. Между отправкой в
       Telegram и появлением строки в posts_queue есть окно; упади мы в нём,
       ретрай без маркера опубликовал бы дайджест повторно.
    2. posts_queue — источник правды, если маркер потеряли (сброс флага,
       ручная чистка).
    """
    flag = get_system_flag("digest_last_published")
    if flag and flag.get("published_at"):
        try:
            published_at = datetime.fromisoformat(flag["published_at"])
            if published_at.tzinfo is None:
                published_at = published_at.replace(tzinfo=timezone.utc)
            if published_at >= anchor:
                return {"source": "system_flag", **flag}
        except (ValueError, TypeError) as e:
            logger.warning(f"digest_last_published unparseable ({e}); falling back to posts_queue")

    try:
        from content_db_utils import _connect
        conn = _connect()
        cur = conn.cursor()
        cur.execute(
            "SELECT id, published_at, tg_message_id FROM posts_queue "
            "WHERE content_type = 'market_digest' AND status = 'PUBLISHED' "
            "  AND published_at >= %s "
            "ORDER BY published_at DESC LIMIT 1",
            (anchor,),
        )
        row = cur.fetchone()
        cur.close()
        conn.close()
        if row:
            return {"source": "posts_queue", "queue_id": row[0],
                    "published_at": row[1].isoformat(), "root_msg_id": row[2]}
    except Exception as e:
        # Не смогли проверить — безопаснее не публиковать, чем выпустить дубль.
        logger.error(f"digest_published_since check failed: {e}")
        raise

    return None


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


# ---------- FACT COLLECTION ----------

def _connect_news():
    return psycopg2.connect(
        host=NEWS_DB_HOST, port=NEWS_DB_PORT, dbname=NEWS_DB_NAME,
        user=NEWS_DB_USER, password=NEWS_DB_PASSWORD,
    )


def fetch_urgent_events(days: int = WEEK_DAYS) -> list[dict]:
    """Источники для еженедельного дайджеста за последние `days` дней.

    Берём оба ведра — URGENT и DIGEST (см. urgent_collector 4-bucket классификатор):
    URGENT — то, что уже могло быть опубликовано прямо в TG (рейт ЦБ, новые законы);
    DIGEST — экспертная аналитика, налоговая практика, премиум-тренды, которые
    не выстреливают, но обязаны попасть в недельную сводку.
    ARCHIVE / NOISE сюда не идут — они либо для ручного семантического поиска,
    либо вообще не хранятся.
    """
    conn = _connect_news()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        cur.execute(
            """
            SELECT id, event_type, headline, details, source_url, created_at,
                   relevance_tier, audience_fit
            FROM urgent_events
            WHERE created_at >= NOW() - (%s || ' days')::interval
              AND relevance_tier IN ('URGENT', 'DIGEST')
              AND headline IS NOT NULL
            ORDER BY
              CASE relevance_tier WHEN 'URGENT' THEN 0 ELSE 1 END,
              created_at DESC
            LIMIT 25
            """,
            (str(days),),
        )
        return [dict(r) for r in cur.fetchall()]
    except Exception as e:
        logger.error(f"fetch_urgent_events failed: {e}")
        return []
    finally:
        cur.close()
        conn.close()


def fetch_macro_snapshot() -> dict:
    """Последняя ставка ЦБ + динамика инфляции + средняя ипотечная ставка."""
    conn = _connect_news()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        cur.execute(
            """
            SELECT date, cbr_key_rate
            FROM macro_economics
            WHERE cbr_key_rate IS NOT NULL
            ORDER BY date DESC
            LIMIT 1
            """
        )
        rate_row = cur.fetchone()

        cur.execute(
            """
            SELECT date, inflation_annual, inflation_monthly
            FROM macro_economics
            WHERE inflation_annual IS NOT NULL OR inflation_monthly IS NOT NULL
            ORDER BY date DESC
            LIMIT 4
            """
        )
        inflation_rows = [dict(r) for r in cur.fetchall()]

        cur.execute(
            """
            SELECT date, avg_mortgage_rate
            FROM macro_economics
            WHERE avg_mortgage_rate IS NOT NULL
            ORDER BY date DESC
            LIMIT 1
            """
        )
        mortgage_row = cur.fetchone()

        return {
            "cbr_key_rate": dict(rate_row) if rate_row else None,
            "inflation_series": inflation_rows,
            "avg_mortgage_rate": dict(mortgage_row) if mortgage_row else None,
        }
    except Exception as e:
        logger.error(f"fetch_macro_snapshot failed: {e}")
        return {}
    finally:
        cur.close()
        conn.close()


def fetch_bank_offers(limit: int = 5) -> list[dict]:
    """Свежие активные ипотечные предложения."""
    conn = _connect_news()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        cur.execute(
            """
            SELECT bank_name, product_type, product_name,
                   rate_min, rate_max, valid_from, source_url
            FROM bank_offers
            WHERE is_active = TRUE
              AND product_type IN ('mortgage','family_mortgage','it_mortgage','far_east_mortgage')
            ORDER BY scraped_at DESC, rate_min ASC
            LIMIT %s
            """,
            (limit,),
        )
        return [dict(r) for r in cur.fetchall()]
    except Exception as e:
        logger.error(f"fetch_bank_offers failed: {e}")
        return []
    finally:
        cur.close()
        conn.close()


def fetch_rss_overview(week_start: datetime, max_per_source: int = 5) -> list[dict]:
    """Лёгкий RSS-сборщик: top-N свежих entries из каждого источника, без LLM-классификации."""
    out = []
    week_start_ts = week_start.timestamp()
    for source in RSS_SOURCES:
        try:
            feed = feedparser.parse(source["url"])
            count = 0
            for entry in feed.entries:
                if count >= max_per_source:
                    break
                pub_struct = getattr(entry, "published_parsed", None) or getattr(entry, "updated_parsed", None)
                if pub_struct:
                    pub_ts = datetime(*pub_struct[:6], tzinfo=timezone.utc).timestamp()
                    if pub_ts < week_start_ts:
                        continue
                title = getattr(entry, "title", "").strip()
                if not title:
                    continue
                out.append({
                    "source": source["name"],
                    "title": title[:240],
                    "summary": (getattr(entry, "summary", "") or "")[:400],
                    "link": getattr(entry, "link", ""),
                })
                count += 1
        except Exception as e:
            logger.warning(f"RSS overview failed for {source['name']}: {e}")
    return out


def collect_facts(week_start: datetime, week_end: datetime) -> dict:
    """Собрать все факты прошедшей недели."""
    return {
        "week_start": week_start,
        "week_end": week_end,
        "urgent_events": fetch_urgent_events(),
        "rss_items": fetch_rss_overview(week_start),
        "macro": fetch_macro_snapshot(),
        "bank_offers": fetch_bank_offers(),
    }


# ---------- PROMPT FORMATTING ----------

def _format_urgent_block(events: list[dict]) -> str:
    if not events:
        return "(за неделю срочных событий не зафиксировано)"
    lines = []
    for e in events:
        date = _fmt_ddmmyy(e.get("created_at"))
        url = e.get("source_url") or "(нет URL)"
        lines.append(f"- [{e['event_type']} · {date}] {e['headline']}\n  url: {url}\n  {(e.get('details') or '')[:300]}")
    return "\n".join(lines)


def _format_rss_block(items: list[dict]) -> str:
    if not items:
        return "(нет свежих RSS-записей за неделю)"
    lines = []
    for it in items:
        lines.append(f"- [{it['source']}] {it['title']}\n  {it['link']}")
    return "\n".join(lines)


def _format_macro_block(macro: dict) -> str:
    if not macro:
        return "(макро-данные недоступны)"
    out = []
    rate = macro.get("cbr_key_rate") or {}
    if rate:
        out.append(f"Ключевая ставка ЦБ: {rate.get('cbr_key_rate')}% (на {_fmt_ddmmyy(rate.get('date'))})")
    series = macro.get("inflation_series") or []
    if series:
        formatted = "; ".join(
            f"{_fmt_ddmmyy(r.get('date'))}: годовая {r.get('inflation_annual') or '—'}%, мес. {r.get('inflation_monthly') or '—'}%"
            for r in series
        )
        out.append("Инфляция (последние точки): " + formatted)
    mortgage = macro.get("avg_mortgage_rate") or {}
    if mortgage:
        out.append(f"Средняя ипотечная ставка: {mortgage.get('avg_mortgage_rate')}% (на {_fmt_ddmmyy(mortgage.get('date'))})")
    return "\n".join(out) if out else "(макро-данные пустые)"


def _format_bank_offers_block(offers: list[dict]) -> str:
    if not offers:
        return "(нет активных банковских предложений)"
    lines = []
    for o in offers:
        rng = f"{o.get('rate_min')}–{o.get('rate_max')}%" if o.get("rate_max") else f"{o.get('rate_min')}%"
        lines.append(f"- {o['bank_name']} · {o['product_name']} ({o['product_type']}) — ставка {rng}, действует с {_fmt_ddmmyy(o.get('valid_from'))}")
    return "\n".join(lines)


DIGEST_PROMPT_TEMPLATE = """Ты — главный редактор еженедельного дайджеста АН «Виктори». \
Получив набор фактов прошедшей недели, ты пишешь обзор для Telegram-канала @rznvictory.

# ФАКТЫ НЕДЕЛИ (с {week_start} по {week_end})

## Срочные события из нашей базы urgent_events:
{urgent_block}

## Дополнительный контекст из RSS (свежие заголовки за неделю):
{rss_block}

## Макроэкономика:
{macro_block}

## Свежие ипотечные предложения банков:
{bank_offers_block}

# НАШИ ПРОШЛЫЕ ДАЙДЖЕСТЫ ПО ЭТОЙ ТЕМАТИКЕ
{prior_positions}

# ПРАВИЛА КОНСИСТЕНТНОСТИ — БЕЗ «ПЕРЕОБУВАНИЙ»
1. ПРЕЕМСТВЕННОСТЬ. Если ситуация развивает наш прежний прогноз — сошлись на него: \
«как мы и писали в <a href="https://t.me/rznvictory/MSG_ID">прошлом дайджесте от ДД.ММ.ГГ</a>».
2. ОБЯЗАТЕЛЬНО хотя бы ОДНА ссылка на наш предыдущий пост (URL берёшь из блока «Прошлые дайджесты»).
3. ЦИТАТА своего же тезиса при сильном совпадении — через <blockquote>«…»</blockquote> с подписью \
«Ранее в @rznvictory (ДД.ММ.ГГ): <a href=URL>…</a>».
4. ЭВОЛЮЦИЯ позиции — только с обоснованием конкретного триггера: «раньше X, потому что Y; \
Y изменилось на Y' (конкретный факт), поэтому уточняем: Z».
5. РАЗВОРОТ НА 180° БЕЗ ПРИЧИНЫ — НЕДОПУСТИМ. Лучше переформулируй мягче.

# ТОН И АУДИТОРИЯ
Канал @rznvictory читают обыватели — потенциальные покупатели и продавцы квартир, \
не финансовые аналитики. Пиши как умный сосед-эксперт за чашкой чая, \
а не как пресс-релиз ЦБ.
- Короткие предложения, простой язык. Любой термин (ДКП, эскроу, андеррайтинг, \
ОФЗ) — поясни в скобках при первом упоминании.
- КАЖДУЮ ключевую цифру разворачивай в бытовой пример с расчётом. \
Не «ставка 14,5%», а «ставка 14,5% — на двушку за 7 млн с первоначалкой 1,5 млн \
платёж выходит около 76 тыс/мес, переплата за 20 лет ≈ 12,8 млн ₽». \
Город в примерах НЕ называй — пример должен работать для любого среднего \
российского города, цифры адаптируй под средние по стране данные.
- Используй 1–2 ярких аналогии или гипотетических сценария: «Представьте, что \
вы продаёте бабушкину квартиру, приватизированную в 1995-м…» или «Если вы \
снимаете двушку за 35 тыс, то ипотека под льготные 6% на ту же двушку — это \
платёж 38 тыс, то есть фактически вы платите за съём чужого жилья столько же».

# МНОГОСТОРОННЯЯ ОЦЕНКА — ОБЯЗАТЕЛЬНО
В каждой тематической секции дай ХОТЯ БЫ ОДИН плюс и ХОТЯ БЫ ОДИН риск/минус. \
Не сваливайся в чистый позитив или чистый негатив. Рекомендуемая разметка:
   <b>📉 Ставки и ДКП</b>
   <факт + конкретный пример с цифрами>
   <i>Плюс:</i> для тех, кто откладывает покупку — депозит под 18% сейчас приносит \
больше, чем рост цен на жильё за тот же срок.
   <i>Риск:</i> длительные высокие ставки сжимают вторичку — продавцы держат \
цены, ликвидных предложений мало, поторговаться удастся не везде.

Если факт реально однозначный (например, антимошеннические поправки) — скажи \
прямо: «здесь рисков по сути нет». Не выдумывай риск ради формы.

# СВОЙ ГОЛОС — НЕ БОЙСЯ ИДТИ ПРОТИВ БОЛЬШИНСТВА
Если у нас есть основание не соглашаться с расхожим мнением — скажи это прямо.
- Когда рынок паникует, а данные не подтверждают паники — обоснуй цифрами. \
Пример: «Все боятся 7,5% инфляции, но базовая инфляция (без сезонного овоща \
и волатильных компонентов) — около 5%. Это НЕ повод откладывать покупку \
вторички, если объект ваш».
- Когда рынок благодушен, а мы видим зреющий риск — выскажись без эвфемизмов.
- Используй формулировки типа «вопреки общему мнению…», «многие думают X, но \
на деле…», «нам часто говорят, что…, но цифры показывают обратное».
- Однако: «свой голос» НЕ означает разворот прежней позиции без причин. \
Правило consistency_check (matches_past / reason_for_shift) сохраняется.

# РАЗБИЕНИЕ НА НЕСКОЛЬКО ПОСТОВ
Дайджест отдаётся в Telegram как ЦЕПОЧКА из 2–3 связанных сообщений (треда). \
Это разрешает писать развёрнуто, без потери человечности и многосторонности. \
Второе и третье сообщения подвязываются reply-ом к первому, читателю показывается \
как ветка с перепиской.

Распределение по постам:
- Пост 1 («Главное»): шапка-заголовок + лид-абзац + 1–2 ключевые тематические \
секции (выбирай те, где на этой неделе самые яркие события — обычно «Законодательство» \
и/или «Ипотека»). В конце — фраза-anchor «👇 Продолжение в треде: ставки, рынок и \
что делать на этой неделе».
- Пост 2 («Контекст»): оставшиеся тематические секции (1–2) + блок \
<b>Связь с прошлым:</b> со ссылкой на наш предыдущий дайджест.
- Пост 3 («Что делать»): ровно 3 совета по разным ролям + хэштеги в самом конце. \
Если фактов мало и достаточно 2 постов — третий не делай, тогда «Что делать» и \
хэштеги вшиваются в конец второго.

# СТРУКТУРА КАЖДОГО ПОСТА (строго)
- Тематическая секция:
   — заголовок секции в <b>…</b> с эмодзи в начале (📉 ставки и ДКП, 🏠 ипотека и льготы, \
⚖️ законодательство, 🏗 застройщики, 📊 макро). Включай ТОЛЬКО секции с фактами.
   — 2–4 предложения с цифрами, ссылками на источники И как минимум одним \
бытовым примером с расчётом.
   — где уместно — цитата официального лица через <blockquote>.
   — обязательно: <i>Плюс:</i> + <i>Риск:</i> (см. блок «Многосторонняя оценка»).
- Блок «Что делать на этой неделе:» — ровно 3 совета, каждый с новой строки \
и тире «— ». Каждый — для разной роли читателя: «если копите/готовитесь к покупке», \
«если уже взяли ипотеку», «если продаёте» (или «если инвестируете», если основная \
роль неактуальна). Три совета ВСЕГДА покрывают РАЗНЫЕ кейсы, не дубль.

# ФОРМАТИРОВАНИЕ — ТОЛЬКО Telegram HTML
Разрешены: <b>, <i>, <u>, <s>, <code>, <pre>, <a href="…">, <blockquote>.
ЗАПРЕЩЕНО: **, *, _, `>` в начале строки для цитат, ##, #заголовки, <ul>, <li>, <p>, <div>, <br>, <h1-6>.
Хэштеги внутри постов 1 и 2 — НЕТ. Хэштеги ставятся ТОЛЬКО в самый конец последнего поста серии.

# ОГРАНИЧЕНИЯ ДЛИНЫ
- Каждый отдельный пост ≤ 3500 символов (Telegram держит 4096; запас).
- Серия: 2 поста по 1500–2500 симв либо 3 поста по 1500–2000 симв. Если фактов мало — 2 коротких поста.

# JSON-OUTPUT (только валидный JSON, без пояснений)
{{
  "posts": [
    "<HTML-текст поста 1, без хэштегов>",
    "<HTML-текст поста 2, без хэштегов>",
    "<HTML-текст поста 3 (опционально), без хэштегов — хэштеги добавятся отдельно>"
  ],
  "topic_hashtags": ["6–8 тематических тегов без #", "не начинать с «Виктори»"],
  "short_summary": "≤80 символов резюме недели для логов",
  "consistency_check": {{
    "matches_past": true|false,
    "cited_msg_ids": [<integer tg_message_id>],
    "reason_for_shift": "<обоснование если позиция эволюционировала, иначе null>"
  }}
}}

# ПРАВИЛА для topic_hashtags
- 6–8 штук, на русском или латинице, без пробелов и без «#».
- По темам: ставкаЦБ, ипотека2026, льготнаяИпотека, недвижимостьРФ, ДКП, инфляция, инвестиции и т.п.
- Запрещено начинать тег со слова «Виктори» — бренд-теги добавляем сами."""


def _facts_to_topic(facts: dict) -> str:
    """Сжать факты в один topic-string для get_party_line/триграммного поиска."""
    parts = []
    for e in facts.get("urgent_events") or []:
        parts.append(e.get("headline") or "")
    for it in (facts.get("rss_items") or [])[:10]:
        parts.append(it.get("title") or "")
    macro = facts.get("macro") or {}
    rate = macro.get("cbr_key_rate") or {}
    if rate.get("cbr_key_rate"):
        parts.append(f"ключевая ставка {rate['cbr_key_rate']}%")
    return " ".join(p for p in parts if p)[:4000]


# ---------- LLM CALL ----------

def _parse_digest_json(raw: str) -> dict:
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw, flags=re.IGNORECASE)
    if not raw.startswith("{"):
        m = re.search(r"\{.*\}", raw, flags=re.DOTALL)
        if m:
            raw = m.group(0)
    parsed = json.loads(raw)
    posts = parsed.get("posts")
    if not posts or not isinstance(posts, list):
        raise ValueError("missing or invalid 'posts' in digest JSON")
    return parsed


def generate_digest(facts: dict, prior_items: list[dict]) -> tuple[dict, str] | tuple[None, None]:
    """LLM-вызов с DIGEST_PROMPT_TEMPLATE → (parsed_dict, model_used) или (None, None)."""
    week_start = facts["week_start"]
    week_end = facts["week_end"]
    prompt = DIGEST_PROMPT_TEMPLATE.format(
        # Все даты, видимые LLM в промпте, идут в dd.MM.yy — чтобы вывод
        # дайджеста (TG/site) был в проектном стандарте. ISO-варианты ниже
        # для filename/meta остаются как есть (machine-parseable).
        week_start=week_start.strftime("%d.%m.%y"),
        week_end=week_end.strftime("%d.%m.%y"),
        week_start_short=week_start.strftime("%d.%m.%y"),
        week_end_short=week_end.strftime("%d.%m.%y"),
        urgent_block=_format_urgent_block(facts.get("urgent_events") or []),
        rss_block=_format_rss_block(facts.get("rss_items") or []),
        macro_block=_format_macro_block(facts.get("macro") or {}),
        bank_offers_block=_format_bank_offers_block(facts.get("bank_offers") or []),
        prior_positions=format_prior_positions(prior_items),
    )

    chain_override = None
    if DIGEST_TRIGGER_MODEL_OVERRIDE:
        chain_override = [("omniroute", DIGEST_TRIGGER_MODEL_OVERRIDE, 180)]

    logger.info("Generating digest via LLM fallback chain...")
    try:
        model_used, raw = complete_with_fallbacks(
            messages=[{"role": "user", "content": prompt}],
            temperature=0.4,
            max_tokens=4096,
            parse_fn=_parse_digest_json,
            chain=chain_override,
        )
        parsed = _parse_digest_json(raw)
        return parsed, model_used
    except Exception as e:
        logger.error(f"Failed to generate digest: {e}")
        return None, None


# ---------- TELEGRAM PUBLISH (multi-message thread) ----------

def _telegram_send(text: str, reply_to: int | None = None,
                   chat_id: str | None = None) -> int | None:
    """Отправить одно HTML-сообщение. Возвращает message_id или None.

    chat_id по умолчанию — публичный канал. Явно передаётся только для
    служебных уведомлений, которым в @rznvictory не место.
    """
    if not TELEGRAM_BOT_TOKEN:
        logger.error("CHANNEL_BOT_TOKEN missing — cannot publish thread.")
        return None
    api_url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    data = {
        "chat_id": chat_id or TELEGRAM_CHANNEL,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    if reply_to:
        data["reply_to_message_id"] = reply_to
    for attempt in range(3):
        try:
            resp = requests.post(api_url, data=data, timeout=30)
            if resp.status_code == 200 and resp.json().get("ok"):
                return resp.json()["result"]["message_id"]
            logger.warning(f"telegram send attempt {attempt+1}: {resp.status_code} {resp.text[:200]}")
        except Exception as e:
            logger.warning(f"telegram send attempt {attempt+1} exception: {e}")
        if attempt < 2:
            import time as _t
            _t.sleep(3)
    return None


def publish_thread(
    posts: list[str], hashtags: list[str], site_url: str | None = None
) -> tuple[int | None, list[int]]:
    """Публикует серию (1–3) сообщений как тред с reply на первое.

    Хэштеги добавляются в самый конец последнего поста, если ещё не добавлены.
    Если передан site_url — в КАЖДОМ посту в самом низу появляется footer-блок
    «Подробнее у нас на сайте: <url>» (на последнем посту — после хэштегов).
    Возвращает (root_msg_id, [все msg_id]).
    """
    if not posts:
        return None, []

    # Нормализуем: к последнему посту приклеиваем хэштеги.
    posts = [p.rstrip() for p in posts if p and p.strip()]
    if posts:
        posts[-1] = posts[-1] + "\n\n" + " ".join(hashtags)
    if site_url:
        footer = build_site_footer(site_url)
        posts = [p + footer for p in posts]

    msg_ids = []
    root_id = None
    for idx, body in enumerate(posts):
        if len(body) > 4096:
            logger.warning(f"post #{idx+1} length {len(body)} > 4096; will be cut by Telegram")
        mid = _telegram_send(body, reply_to=root_id if idx > 0 else None)
        if mid is None:
            logger.error(f"Failed to publish part {idx+1}/{len(posts)}; aborting thread.")
            break
        msg_ids.append(mid)
        if idx == 0:
            root_id = mid
        # пауза между сообщениями, чтобы Telegram не сжал rate limit
        if idx < len(posts) - 1:
            import time as _t
            _t.sleep(2)
    return root_id, msg_ids


# ---------- ENTRYPOINT ----------

def _alert_failure(reason: str, detail: str = "") -> None:
    """Уведомить о провале, не чаще одного Telegram-сообщения на неделю.

    Файл-след пишется каждый раз (дёшево и полезно для разбора), а вот
    сообщение в чат дедуплицируется по номеру ISO-недели: окно догона даёт до
    21 запуска, и без дедупа человек получил бы 21 одинаковый алерт.
    """
    iso_week = datetime.now(timezone.utc).strftime("%G-W%V")
    already = get_system_flag("digest_alert_sent") or {}
    send_tg = already.get("iso_week") != iso_week

    result = notify_failure(
        component="weekly_digest",
        reason=reason,
        detail=detail,
        chat_id=DIGEST_ALERT_CHAT_ID if send_tg else None,
        bot_token=TELEGRAM_BOT_TOKEN,
    )
    if send_tg and result.get("telegram"):
        set_system_flag("digest_alert_sent", {"iso_week": iso_week,
                                              "ts": datetime.now(timezone.utc).isoformat()})
    logger.info(f"failure notified: {result}")


def run_weekly_pipeline(auto_publish: bool = True) -> tuple[str, int | None]:
    """Прогнать недельный дайджест.

    Возвращает (status, queue_id), где status ∈ published | skipped | failed.
    Раньше здесь был int | None, и None означал одновременно «штатно пропустили»
    и «упало» — из-за чего ни крон, ни человек не отличали провал от нормы.
    """
    logger.info("📰 Starting Weekly Digest Pipeline...")

    flag = get_system_flag("digest_disabled")
    if flag and flag.get("disabled") is True:
        logger.warning(f"Weekly digest paused: {flag.get('reason')}")
        _log_pipeline_event({"action": "skipped_circuit_breaker", "flag": flag})
        return "skipped", None

    # Проверка ДО сбора фактов: холостой запуск в окне догона должен стоить
    # один SQL-запрос, а не обход семи RSS-лент и вызов LLM.
    anchor = week_anchor(datetime.now(timezone.utc))
    try:
        already_published = digest_published_since(anchor)
    except Exception as e:
        # Не смогли проверить — молчим и ждём следующего часа. Опубликовать
        # вслепую хуже: получится второй дайджест за неделю.
        logger.error(f"Idempotency check failed, skipping this attempt: {e}")
        _alert_failure("idempotency_check_failed", str(e))
        return "failed", None

    if already_published:
        logger.info(
            f"Digest for week of {anchor.date()} already published "
            f"({already_published.get('source')}, msg_id={already_published.get('root_msg_id')}). Nothing to do."
        )
        _log_pipeline_event({"action": "skipped_already_published",
                             "anchor": anchor.date().isoformat(),
                             "found": already_published})
        return "skipped", None

    week_end = datetime.now(timezone.utc)
    week_start = week_end - timedelta(days=WEEK_DAYS)
    facts = collect_facts(week_start, week_end)
    fact_counts = {
        "urgent_events": len(facts.get("urgent_events") or []),
        "rss_items": len(facts.get("rss_items") or []),
        "bank_offers": len(facts.get("bank_offers") or []),
        "macro_present": bool((facts.get("macro") or {}).get("cbr_key_rate")),
    }
    logger.info(f"Collected facts: {fact_counts}")

    if fact_counts["urgent_events"] == 0 and fact_counts["rss_items"] == 0:
        logger.warning("No facts to digest. Aborting.")
        _log_pipeline_event({"action": "skipped_empty", "fact_counts": fact_counts})
        return "skipped", None

    topic = _facts_to_topic(facts)
    prior_items = get_party_line(topic, limit=4) if topic else []
    logger.info(f"Prior digests for party-line: {len(prior_items)}")

    parsed, model_used = generate_digest(facts, prior_items)
    raw_posts = parsed.get("posts") if parsed else None
    if not raw_posts or not isinstance(raw_posts, list):
        logger.error("Generation failed or 'posts' missing.")
        _log_pipeline_event({"action": "generation_failed", "fact_counts": fact_counts})
        _alert_failure("generation_failed",
                       f"model={model_used}; вся цепочка не отдала посты. facts={fact_counts}")
        return "failed", None

    posts = [sanitize_body_html(p.strip()) for p in raw_posts if isinstance(p, str) and p.strip()]
    posts = [p for p in posts if p]
    if not posts:
        logger.error("All posts empty after sanitize.")
        _log_pipeline_event({"action": "generation_empty_after_sanitize"})
        _alert_failure("generation_empty_after_sanitize", f"model={model_used}")
        return "failed", None

    auto_tags = filter_topic_hashtags(parsed.get("topic_hashtags") or [])
    hashtags = BRAND_TAGS + auto_tags
    short_summary = (parsed.get("short_summary") or "Недельный дайджест")[:80]
    consistency = parsed.get("consistency_check") or {}

    # Артефакты для архива (склеенный текст для анализа).
    full_text = ("\n\n— — —\n\n").join(posts) + "\n\n" + " ".join(hashtags)
    date_str = week_end.strftime("%Y%m%d")
    os.makedirs(PUBLISHED_DIR, exist_ok=True)
    txt_path = os.path.join(PUBLISHED_DIR, f"digest_{date_str}.txt")
    meta_path = os.path.join(PUBLISHED_DIR, f"digest_{date_str}.meta.json")
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write(full_text)
    meta = {
        "week_start": week_start.date().isoformat(),
        "week_end": week_end.date().isoformat(),
        "fact_counts": fact_counts,
        "post_count": len(posts),
        "post_chars": [len(p) for p in posts],
        "hashtags": hashtags,
        "short_summary": short_summary,
        "model": model_used,
        "consistency_check": consistency,
        "prior_msg_ids": [it["tg_message_id"] for it in prior_items if it.get("tg_message_id")],
        "prior_count": len(prior_items),
    }
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

    if not auto_publish:
        logger.info(f"AUTO_PUBLISH=0 → not published. Artifacts at {txt_path}")
        _log_pipeline_event({
            "action": "draft_only",
            "fact_counts": fact_counts,
            "post_count": len(posts),
            "post_chars": [len(p) for p in posts],
            "consistency_check": consistency,
            "prior_count": len(prior_items),
        })
        return "skipped", None

    # === victory62.org web-mirror (ДО публикации в TG) ===
    # Зеркалим дайджест на сайт и забираем канонический URL из ответа,
    # чтобы в каждое из 3 сообщений треда вставить footer «Подробнее на сайте».
    # external_id = "digest_<date>", сайт идемпотентен. Если упал — fallback
    # на детерминированный URL, mirror подхватит при следующем прогоне.
    site_url = mirror_to_victory(meta_path, txt_path)
    mirror_ok = bool(site_url)
    if not site_url:
        site_url = fallback_site_url(f"digest_{date_str}")

    # Прямая публикация треда через Telegram Bot API.
    root_id, msg_ids = publish_thread(posts, hashtags, site_url=site_url)
    if not root_id:
        logger.error("Thread publish failed.")
        _log_pipeline_event({
            "action": "publish_failed",
            "fact_counts": fact_counts,
            "site_url": site_url,
            "mirror_ok": mirror_ok,
        })
        _alert_failure("publish_failed", f"Telegram не принял тред; site_url={site_url}")
        return "failed", None

    # Маркер ставим здесь, сразу после успеха публикации и ДО записи в
    # posts_queue: если упадём между этими шагами, следующий запуск в окне
    # догона обязан увидеть, что дайджест уже в канале, и не выпустить второй.
    set_system_flag("digest_last_published", {
        "published_at": datetime.now(timezone.utc).isoformat(),
        "root_msg_id": root_id,
        "msg_ids": msg_ids,
        "week_anchor": anchor.date().isoformat(),
    })

    # Записываем в posts_queue факт публикации (одна запись с tg_message_id первого поста)
    # — нужно для будущего party-line поиска.
    queue_id = enqueue_urgent_post(
        text=full_text,
        request_text=f"[weekly_digest] {short_summary}",
        content_type="market_digest",
        project_name="Виктори_Дайджест",
        tg_channel=TELEGRAM_CHANNEL,
        hashtags=hashtags,
        auto_publish=False,  # не запускать publisher_bot — мы уже опубликовали
    )
    # после insert обновим строку до PUBLISHED + msg_id
    if queue_id:
        try:
            from content_db_utils import _connect
            conn = _connect()
            cur = conn.cursor()
            cur.execute(
                "UPDATE posts_queue SET status='PUBLISHED', published_at=NOW(), tg_message_id=%s WHERE id=%s",
                (root_id, queue_id),
            )
            conn.commit()
            cur.close()
            conn.close()
        except Exception as e:
            logger.error(f"posts_queue post-publish update failed: {e}")

    logger.info(
        f"✅ Published digest thread: root_msg_id={root_id}, parts={msg_ids}, "
        f"queue_id={queue_id}, site_url={site_url} (mirror_ok={mirror_ok})"
    )
    _log_pipeline_event({
        "action": "published_thread",
        "root_msg_id": root_id,
        "msg_ids": msg_ids,
        "queue_id": queue_id,
        "fact_counts": fact_counts,
        "post_count": len(posts),
        "post_chars": [len(p) for p in posts],
        "hashtags": hashtags,
        "consistency_check": consistency,
        "prior_count": len(prior_items),
        "site_url": site_url,
        "mirror_ok": mirror_ok,
    })
    return "published", queue_id


if __name__ == "__main__":
    auto_publish = os.getenv("AUTO_PUBLISH", "1") not in ("0", "false", "False")
    status, _queue_id = run_weekly_pipeline(auto_publish=auto_publish)
    # Ненулевой код только на реальном провале: крон и обёртки должны отличать
    # «упало, надо чинить» от «сегодня выпуск не нужен».
    sys.exit(1 if status == "failed" else 0)
