import json
import logging
import os
import re
import sys
from datetime import datetime, timedelta, timezone

import psycopg2
from psycopg2.extras import RealDictCursor
import requests

WORKSPACE = "/opt/.openclaw/.openclaw/workspace-conveyor"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(WORKSPACE)
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

from content_db_utils import (  # noqa: E402
    enqueue_urgent_post,
    get_party_line,
    get_embedding,
    get_system_flag,
)
from urgent_relevance import gate_urgent  # noqa: E402
from pipeline_utils import (  # noqa: E402
    BRAND_TAGS,
    BRAND_TAG_RE,
    build_site_footer,
    complete_with_fallbacks,
    fallback_site_url,
    filter_topic_hashtags,
    format_prior_positions as _format_prior_positions,
    mirror_to_victory,
    sanitize_body_html,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("urgent_trigger")

PIPELINE_LOG = os.path.join(WORKSPACE, "SHARED/logs/urgent_pipeline.log")

# urgent_events читаем из news-DB (audit-v2-postgres:5433, с pgvector).
# Запись в production posts_queue идёт через content_db_utils.enqueue_urgent_post,
# которая сама подключается к postgres-local.
DB_HOST = os.getenv("NEWS_DB_HOST") or os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("NEWS_DB_PORT") or "5433"
DB_NAME = os.getenv("NEWS_DB_NAME") or os.getenv("DB_NAME", "re_audit")
DB_USER = os.getenv("NEWS_DB_USER") or os.environ["DB_USER"]
DB_PASSWORD = os.getenv("NEWS_DB_PASSWORD") or os.environ["DB_PASSWORD"]

# Generation идёт через pipeline_utils.complete_with_fallbacks (in-process
# fallback-цепочка). URGENT_TRIGGER_MODEL — опциональный single-model override
# для отладки.
URGENT_TRIGGER_MODEL_OVERRIDE = os.getenv("URGENT_TRIGGER_MODEL")

def _log_pipeline_event(event: dict) -> None:
    try:
        os.makedirs(os.path.dirname(PIPELINE_LOG), exist_ok=True)
        record = {"ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), **event}
        with open(PIPELINE_LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        logger.warning(f"pipeline-log write failed: {e}")


def check_for_duplicates(cur, embedding, current_event_id: int = None, hours: int = 48):
    """Сравнивает embedding текущей новости с embedding'ами предыдущих urgent_events
    в окне `hours`. Исключает само текущее событие (защита от self-match sim=1.0).
    """
    if not embedding:
        return False
    # Дедуп защищает от двойной публикации одного события в TG-канал. Поэтому
    # сравниваем кандидата только с тем, что **реально ушло** в @rznvictory
    # (published_to_tg=true), а не со всеми URGENT-row в БД.
    #
    # История:
    # • 2026-05-14: после 4-bucket патча DIGEST/ARCHIVE начали копить embedding'и;
    #   дедуп их видел и заглушал URGENT — добавили `relevance_tier='URGENT'`.
    # • 2026-05-22: тот же баг в более тонкой форме — зарезанные дедупом URGENT
    #   сами становились якорями для следующих URGENT. 4 дня тишины: ~31 событие
    #   зарезано, в том числе валидные «Минфин ужесточения семейной ипотеки»
    #   (sim 0.863 к «Euroclear отказался»), «ЦБ снизил курс доллара» (0.898 к
    #   операциям РЕПО), «Кабмин страховка вкладов» (0.882 к «Контроль ЦБ»).
    #   Корень: gemini-embedding-001 на коротких русских официальных заголовках
    #   держит baseline ~0.85+ из-за общего лексикона (Банк России, Указание,
    #   числа, даты). Истинные дубли всё ещё ≥0.93.
    # • Фикс: published_to_tg=true (анкорим только реально опубликованные) +
    #   порог 0.85→0.92 (отсечь baseline-шум).
    query = """
        SELECT id, headline, 1 - (embedding <=> %s::vector) as similarity
        FROM urgent_events
        WHERE created_at > %s
          AND embedding IS NOT NULL
          AND relevance_tier = 'URGENT'
          AND published_to_tg = TRUE
          AND id <> COALESCE(%s, -1)
          AND (1 - (embedding <=> %s::vector)) > 0.92
        ORDER BY similarity DESC
        LIMIT 1;
    """
    time_threshold = datetime.now() - timedelta(hours=hours)
    cur.execute(query, (embedding, time_threshold, current_event_id, embedding))
    return cur.fetchone()


def check_urgent_events():
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )
    cur = conn.cursor(cursor_factory=RealDictCursor)

    # 4-bucket режим (2026-05-14): только relevance_tier='URGENT' идёт в TG.
    # DIGEST/ARCHIVE-строки хранятся, но не публикуются: дайджест собирает их
    # отдельно (weekly_digest_trigger.fetch_urgent_events). NOISE не пишется.
    #
    # 2026-08-08: берём пачку кандидатов, а не одного. Каждый прогоняется через
    # gate_urgent — страховка от ошибок классификатора и от строк, попавших в
    # очередь до ужесточения фильтра. Непрошедшие понижаются до DIGEST прямо
    # здесь, иначе один зарезанный кандидат съедал бы весь 15-минутный цикл.
    cur.execute(
        "SELECT * FROM urgent_events "
        "WHERE is_processed = FALSE AND relevance_tier = 'URGENT' "
        "ORDER BY created_at ASC LIMIT 10;"
    )
    candidates = cur.fetchall()

    event = None
    for candidate in candidates:
        passes, gate_reason = gate_urgent(candidate["event_type"], candidate["headline"])
        if passes:
            event = candidate
            break
        cur.execute(
            "UPDATE urgent_events SET relevance_tier = 'DIGEST', is_processed = TRUE "
            "WHERE id = %s",
            (candidate["id"],),
        )
        conn.commit()
        logger.info(
            f"Gate demoted URGENT→DIGEST [{gate_reason}]: {candidate['headline'][:80]}"
        )
        _log_pipeline_event({
            "action": "demoted",
            "event_id": candidate["id"],
            "headline_preview": candidate["headline"][:80],
            "reason": gate_reason,
        })

    if event:
        logger.info(f"Processing event: {event['headline']}")
        content_to_embed = f"{event['headline']} {event['details']}"
        embedding = get_embedding(content_to_embed)

        if embedding:
            cur.execute(
                "UPDATE urgent_events SET embedding = %s WHERE id = %s",
                (embedding, event["id"]),
            )
            conn.commit()

        duplicate = check_for_duplicates(cur, embedding, current_event_id=event["id"])
        cur.execute(
            "UPDATE urgent_events SET is_processed = TRUE WHERE id = %s", (event["id"],)
        )
        conn.commit()

        if duplicate:
            logger.warning(
                f"DUPLICATE DETECTED: '{event['headline']}' is similar to "
                f"'{duplicate['headline']}' (Sim: {duplicate['similarity']:.4f})"
            )
            _log_pipeline_event({
                "action": "deduped",
                "event_id": event["id"],
                "headline_preview": event["headline"][:80],
                "matched_id": duplicate["id"],
                "similarity": float(duplicate["similarity"]),
            })
            event = None

    cur.close()
    conn.close()
    return event


URGENT_PROMPT_TEMPLATE = """Ты — экспертный SMM-редактор АН «Виктори». Получив СРОЧНУЮ новость \
рынка недвижимости/финансов, ты пишешь компактный, информативный пост для Telegram-канала @rznvictory.

# ИСХОДНОЕ СОБЫТИЕ
Тип: {event_type}
Заголовок: {headline}
Детали: {details}

# НАШИ ПРОШЛЫЕ ПОЗИЦИИ ПО ЭТОЙ ТЕМЕ
{prior_positions}

# КЛЮЧЕВОЕ ПРАВИЛО — НЕ «ПЕРЕОБУВАЙСЯ»
АН «Виктори» — это голос, у которого читатели запоминают позиции. Нельзя без обоснования \
менять прежние выводы на противоположные. Применяй такие правила:

1. ПРЕЕМСТВЕННОСТЬ. Если новое событие подтверждает или развивает наш прежний прогноз — \
явно сошлись на это. Используй формулировки вроде «как мы и предупреждали ранее», \
«это укладывается в наш прогноз от <дата>». ОБЯЗАТЕЛЬНО вставь хотя бы одну ссылку \
<a href="https://t.me/rznvictory/MSG_ID">наш прошлый пост</a> (URL берёшь из блока «Наши прошлые позиции»).

2. ЦИТАТА ИЗ СВОЕГО ЖЕ ПОСТА. Если в прошлой публикации есть тезис, прямо относящийся \
к нынешнему событию, процитируй его в <blockquote>«текст из старого поста»</blockquote> \
с подписью «Ранее в @rznvictory (ДД.ММ.ГГ): <a href=URL>…</a>». Это укрепляет \
последовательность позиции и повышает доверие.

3. ОБОСНОВАННАЯ ЭВОЛЮЦИЯ. Если позиция действительно изменилась (рынок развернулся, \
решение ЦБ переломное, политика поменялась), ты можешь её скорректировать — НО только \
с явным указанием конкретной причины. Шаблон: «Раньше мы считали X, потому что Y. \
Сейчас Y изменилось на Y' (конкретный факт), поэтому уточняем: Z». Без такого обоснования \
позицию менять ЗАПРЕЩЕНО — это повредит репутации канала.

4. РАЗВОРОТ НА 180° БЕЗ ПРИЧИНЫ — НЕДОПУСТИМ. Если кажется, что новый вывод полностью \
противоречит прошлым без видимого триггера в новости — лучше переформулируй мягче, \
покажи нюанс, но не отрицай прежнюю линию.

5. ЕСЛИ ПРОШЛЫХ ПОСТОВ НЕТ или они нерелевантны — пиши с нуля, но в спокойном экспертном \
тоне; не делай слишком категоричных утверждений (это станет нашей будущей «прежней позицией»).

# СТРУКТУРА ТЕКСТА (строго в этом порядке)
1) Шапка одной строкой: ⚡️ <b>СРОЧНО</b> · <категория события — 3–5 слов>
2) Суть события — один абзац, 2–3 предложения, факты и цифры. Если в новости есть прямая \
цитата официального лица — оформи её через <blockquote>«текст»</blockquote>.
3) (Если есть релевантные прошлые посты) — отдельный короткий абзац с ссылкой на наш \
прошлый материал и/или цитатой из него; чётко скажи, подтверждается ли наш прогноз или \
обоснованно эволюционирует.
4) <b>Что это значит:</b> 3–4 пункта аналитики для покупателей и инвесторов. Каждый — \
с новой строки, начинается с «— ».
5) <b>Действие:</b> одна строка с практической рекомендацией.

# ФОРМАТИРОВАНИЕ — ТОЛЬКО HTML, НИКАКОГО MARKDOWN
- Жирный — <b>текст</b>. НЕ **текст** и НЕ *текст*.
- Курсив — <i>текст</i>. НЕ _текст_.
- Подчёркивание — <u>текст</u>. Зачёркнутое — <s>текст</s>.
- Моноширинный — <code>текст</code> или <pre>блок</pre>.
- Цитата — <blockquote>текст</blockquote>. НЕ начинай строку с «>».
- Ссылка — <a href="https://…">текст</a>.
- Заголовки/решётки запрещены: НЕ ##, НЕ #тема (внутри body_html), НЕ <h1>/<h2>.
- Списки — НЕ <ul>/<li>. Только переносы строк и тире «— ».

# ЖЁСТКИЕ ОГРАНИЧЕНИЯ
- Telegram HTML, ТОЛЬКО: <b>, <i>, <u>, <s>, <code>, <pre>, <a href="…">, <blockquote>.
- ЗАПРЕЩЕНО: **, *, _, `>` для цитат, ##, #заголовки, <ul>, <li>, <p>, <div>, <br>, <h1>.
- Хэштеги внутри body_html ЗАПРЕЩЕНЫ — они уходят в topic_hashtags.
- Длина body_html ≤ 1700 символов.

# ПРИМЕР ХОРОШЕГО ВЫВОДА (фрагмент с преемственностью)
⚡️ <b>СРОЧНО</b> · ЦБ снизил ставку до 14,5%

Банк России на заседании 25 апреля снизил ключевую ставку с 16% до 14,5%.
<blockquote>«Мы видим устойчивое замедление инфляции», — отметила Эльвира Набиуллина.</blockquote>

Это подтверждает <a href="https://t.me/rznvictory/412">наш прогноз от 14 апреля</a>: \
мы предупреждали, что инфляция замедлится и ЦБ начнёт смягчение к концу апреля.

<b>Что это значит:</b>
— Рыночная ипотека подешевеет на 0,3–0,5 п.п. в ближайшие 2 недели...
...

# ПРИМЕР ПЛОХОГО (НЕ ДЕЛАТЬ)
- Текст без ссылок на прошлые публикации, хотя в блоке «Наши прошлые позиции» они есть.
- Резкое противоречие прошлому посту без указания, что именно изменилось.
- **Жирный**, *курсив*, > цитата, ## заголовок, #хэштеги внутри тела.

# ВЫВОД В ФОРМАТЕ JSON (без пояснений, только валидный JSON):
{{
  "body_html": "<готовый HTML-пост без хэштегов>",
  "topic_hashtags": ["тег1", "тег2", "тег3", "тег4"],
  "short_summary": "≤60 символов резюме события",
  "consistency_check": {{
    "matches_past": true|false,
    "cited_msg_ids": [<integer tg_message_id ссылок, на которые ты сослался>],
    "reason_for_shift": "<если позиция эволюционировала — короткое обоснование причины; иначе null>"
  }}
}}

# ПРАВИЛА для topic_hashtags
- 4–6 штук, на русском или латинице, без пробелов и без «#».
- По теме (ставкаЦБ, ипотека, недвижимость2026, льготнаяИпотека, ДКП, инвестиции).
- Запрещено начинать тег со слова «Виктори» — бренд-теги мы добавляем сами."""


def _parse_post_json(raw: str) -> dict:
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw, flags=re.IGNORECASE)
    if not raw.startswith("{"):
        m = re.search(r"\{.*\}", raw, flags=re.DOTALL)
        if m:
            raw = m.group(0)
    parsed = json.loads(raw)
    if not (parsed.get("body_html") or "").strip():
        raise ValueError("empty body_html in LLM response")
    return parsed


def generate_post(event):
    logger.info("Generating text via LLM fallback chain...")
    prior_items = get_party_line(event["headline"] + " " + event["details"], limit=4)
    prior_block = _format_prior_positions(prior_items)
    prompt = URGENT_PROMPT_TEMPLATE.format(
        event_type=event["event_type"],
        headline=event["headline"],
        details=event["details"],
        prior_positions=prior_block,
    )

    chain_override = None
    if URGENT_TRIGGER_MODEL_OVERRIDE:
        chain_override = [("omniroute", URGENT_TRIGGER_MODEL_OVERRIDE, 90)]

    try:
        model_used, raw = complete_with_fallbacks(
            messages=[{"role": "user", "content": prompt}],
            temperature=0.4,
            max_tokens=2048,
            parse_fn=_parse_post_json,
            chain=chain_override,
        )
        parsed = _parse_post_json(raw)
        body_html = sanitize_body_html((parsed.get("body_html") or "").strip())
        topic_hashtags = parsed.get("topic_hashtags") or []
        short_summary = (parsed.get("short_summary") or event["headline"])[:60]
        consistency = parsed.get("consistency_check") or {}
        if not body_html:
            raise ValueError("empty body_html after sanitize")
        return body_html, topic_hashtags, short_summary, consistency, prior_items, model_used
    except Exception as e:
        logger.error(f"Failed to generate content: {e}")
        return None, None, None, None, prior_items, None


def run_urgent_pipeline():
    logger.info("⚡ Starting Autonomous URGENT NEWS Pipeline...")

    # Circuit breaker: если publisher 5 раз подряд упал — пауза до ручного ресета.
    # postgres-local (порт 5432) может быть временно недоступен (контейнер падал
    # 2026-05-14) — в таком случае не плюёмся traceback'ом каждые 15 минут, а
    # тихо выходим с exit 0; cron не шлёт fail-alerts, человек видит WARNING в логе.
    try:
        flag = get_system_flag("urgent_publishing_disabled")
    except psycopg2.OperationalError as e:
        logger.warning(
            "Production DB (postgres-local:5432) unreachable — skipping urgent_trigger run: %s",
            str(e).split("\n")[0],
        )
        sys.exit(0)
    if flag and flag.get("disabled") is True:
        logger.warning(f"Urgent publishing is paused: {flag.get('reason')}")
        _log_pipeline_event({"action": "skipped_circuit_breaker", "flag": flag})
        return

    event = check_urgent_events()
    if not event:
        logger.info("No unhandled urgent events found.")
        return

    logger.info(f"🚨 Found urgent event: {event['headline']}")

    body_html, topic_hashtags, short_summary, consistency, prior_items, model_used = generate_post(event)
    if not body_html:
        logger.error("Text generation failed. Aborting.")
        _log_pipeline_event({
            "action": "generation_failed",
            "event_id": event["id"],
            "headline_preview": event["headline"][:80],
        })
        return

    auto_tags = filter_topic_hashtags(topic_hashtags)
    hashtags = BRAND_TAGS + auto_tags
    # base_text — то, что пишется в meta+log и уходит на сайт (без footer'а:
    # на сайте нет смысла линковать статью саму на себя). Footer добавляется
    # к финальному TG-тексту ниже.
    base_text = body_html.rstrip() + "\n\n" + " ".join(hashtags)

    date_str = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_dir = os.path.join(WORKSPACE, "CREATIVE/published")
    os.makedirs(log_dir, exist_ok=True)
    log_file = os.path.join(log_dir, f"urgent_{date_str}.txt")
    meta_file = os.path.join(log_dir, f"urgent_{date_str}.meta.json")
    with open(log_file, "w", encoding="utf-8") as f:
        f.write(base_text)
    with open(meta_file, "w", encoding="utf-8") as f:
        json.dump(
            {
                "event_id": event["id"],
                "event_type": event["event_type"],
                "headline": event["headline"],
                "source_url": event.get("source_url"),
                "hashtags": hashtags,
                "short_summary": short_summary,
                "model": model_used,
                "consistency_check": consistency,
                "prior_msg_ids": [it["tg_message_id"] for it in prior_items if it.get("tg_message_id")],
                "prior_count": len(prior_items),
            },
            f,
            ensure_ascii=False,
            indent=2,
        )

    # === victory62.org web-mirror (ДО enqueue) ===
    # Зеркалим в /webhooks/news_ingest и забираем канонический URL статьи,
    # чтобы вставить его в TG-пост. Если сайт недоступен — fallback на
    # детерминированный URL по event_id (mirror всё равно будет ретрайнут
    # при следующем прогоне, посколько idempotency идёт по external_id).
    site_url = mirror_to_victory(meta_file, log_file)
    mirror_ok = bool(site_url)
    if not site_url:
        site_url = fallback_site_url(event["id"])
    final_text = base_text + build_site_footer(site_url)

    request_text = f"[urgent] {event['event_type']}: {short_summary}"
    try:
        queue_id = enqueue_urgent_post(
            text=final_text,
            request_text=request_text,
            content_type="urgent_news",
            tg_channel="@rznvictory",
            hashtags=hashtags,
            auto_publish=True,
        )
    except psycopg2.OperationalError as e:
        logger.warning(
            "Production DB unreachable mid-run — cannot enqueue event #%s; meta/log files saved at %s. Error: %s",
            event["id"], log_file, str(e).split("\n")[0],
        )
        sys.exit(0)
    if queue_id:
        # Маркируем urgent_event как реально ушедший в TG — это якорь для будущих
        # dedup-проверок (см. check_for_duplicates). Без этого новые URGENT
        # сравнивались бы со зарезанными неопубликованными — что и привело к
        # 4-дневной тишине 2026-05-18→22.
        try:
            from content_db_utils import _connect_news
            _news_conn = _connect_news()
            with _news_conn.cursor() as _cur:
                _cur.execute(
                    "UPDATE urgent_events SET published_to_tg = TRUE WHERE id = %s",
                    (event["id"],),
                )
                _news_conn.commit()
            _news_conn.close()
        except Exception as e:
            logger.warning(
                "Failed to set published_to_tg on event #%s (non-fatal, post already enqueued): %s",
                event["id"], e,
            )
        logger.info(
            f"✅ Enqueued for content-publisher: posts_queue.id={queue_id} "
            f"site_url={site_url} (mirror_ok={mirror_ok})"
        )
        _log_pipeline_event({
            "action": "enqueued",
            "event_id": event["id"],
            "queue_id": queue_id,
            "headline_preview": event["headline"][:80],
            "hashtags": hashtags,
            "body_chars": len(body_html),
            "consistency_check": consistency,
            "prior_count": len(prior_items),
            "site_url": site_url,
            "mirror_ok": mirror_ok,
        })
    else:
        logger.error("Failed to enqueue urgent post.")
        _log_pipeline_event({
            "action": "enqueue_failed",
            "event_id": event["id"],
            "headline_preview": event["headline"][:80],
            "site_url": site_url,
            "mirror_ok": mirror_ok,
        })


if __name__ == "__main__":
    run_urgent_pipeline()
