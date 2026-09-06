import os
import logging
from datetime import datetime
from typing import Optional

import requests
import psycopg2
from psycopg2.extras import RealDictCursor

logger = logging.getLogger("content_db_utils")

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


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


_load_env_file(os.path.join(_SCRIPT_DIR, ".env"))

# Production DB (postgres-local:5432) — здесь живут posts_queue и system_flags,
# отсюда читает publisher_bot. Pgvector НЕ установлен, поэтому embedding-колонка
# отсутствует и не используется.
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "re_audit")
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]

# News DB (audit-v2-postgres:5433) — отдельный инстанс с pgvector для
# urgent_events.embedding и embedding-дедупа новостей.
NEWS_DB_HOST = os.getenv("NEWS_DB_HOST", "localhost")
NEWS_DB_PORT = os.getenv("NEWS_DB_PORT", "5433")
NEWS_DB_NAME = os.getenv("NEWS_DB_NAME", "re_audit")
NEWS_DB_USER = os.getenv("NEWS_DB_USER", DB_USER)
NEWS_DB_PASSWORD = os.getenv("NEWS_DB_PASSWORD") or DB_PASSWORD

# Embedding key — отдельная переменная, fallback на общий GEMINI_API_KEY для совместимости.
GEMINI_API_KEY = os.environ.get("GEMINI_EMBEDDING_API_KEY") or os.environ["GEMINI_API_KEY"]


def _connect():
    """Подключение к production DB (posts_queue, system_flags)."""
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD
    )


def _connect_news():
    """Подключение к news DB с pgvector (urgent_events)."""
    return psycopg2.connect(
        host=NEWS_DB_HOST, port=NEWS_DB_PORT, dbname=NEWS_DB_NAME,
        user=NEWS_DB_USER, password=NEWS_DB_PASSWORD,
    )


def get_embedding(text, task_type: str = "RETRIEVAL_DOCUMENT"):
    """Generate 3072-dim embedding via gemini-embedding-001.

    Schema: urgent_events.embedding и posts_queue.embedding объявлены как
    vector(3072) — это дефолтная размерность gemini-embedding-001. Раньше тут
    стоял text-embedding-004 (768 dim), из-за чего все INSERT ... embedding
    падали и дедуп не работал. См. план ticklish-skipping-penguin.md.
    """
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent?key={GEMINI_API_KEY}"
    payload = {
        "model": "models/gemini-embedding-001",
        "content": {"parts": [{"text": text}]},
        "taskType": task_type,
    }
    try:
        resp = requests.post(url, json=payload, timeout=15)
        resp.raise_for_status()
        return resp.json()["embedding"]["values"]
    except Exception as e:
        logger.error(f"Embedding generation failed: {e}")
        return None


def save_published_post(text, content_type="regular", tg_message_id=None):
    """Записать готовый пост в posts_queue (production DB, без embedding)."""
    conn = _connect()
    cur = conn.cursor()
    try:
        query = """
            INSERT INTO posts_queue
            (request_text, content_type, final_text, smm_text, status,
             published_at, tg_channel, tg_message_id)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        """
        cur.execute(
            query,
            (
                "Авто-публикация",
                content_type,
                text,
                text,
                "PUBLISHED",
                datetime.now(),
                "@rznvictory",
                tg_message_id,
            ),
        )
        conn.commit()
        return True
    except Exception as e:
        logger.error(f"DB Save Error: {e}")
        conn.rollback()
        return False
    finally:
        cur.close()
        conn.close()


def enqueue_urgent_post(
    text: str,
    request_text: str,
    content_type: str = "urgent_news",
    tg_channel: str = "@rznvictory",
    hashtags: Optional[list] = None,
    project_name: str = "Виктори_Срочно",
    auto_publish: bool = True,
) -> Optional[int]:
    """Insert a generated urgent post into production posts_queue (postgres-local).

    Пишем одновременно в smm_text (publisher_bot читает именно его — см.
    publisher_bot.py:71) и final_text (для совместимости со скриптами,
    которые ищут в final_text).

    Embedding-колонки в production-БД нет (alpine postgres без pgvector),
    поэтому НЕ используем её при вставке — дедуп urgent-новостей работает
    на стороне urgent_events в news-DB.

    auto_publish=True (по умолчанию) → status='SCHEDULED', scheduled_at=NOW().
    publisher_bot.scheduler.job_publish_due крутится каждые 5 минут.
    auto_publish=False → 'WAITING_APPROVAL' для ручного аппрува.
    """
    if auto_publish:
        status = "SCHEDULED"
        scheduled_at_clause = "NOW()"
    else:
        status = "WAITING_APPROVAL"
        scheduled_at_clause = "NULL"

    conn = _connect()
    cur = conn.cursor()
    try:
        query = f"""
            INSERT INTO posts_queue
            (project_name, content_type, requester, request_text,
             smm_text, final_text, hashtags, status, scheduled_at,
             tg_channel, is_urgent, created_by, requested_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, {scheduled_at_clause},
                    %s, %s, %s, NOW())
            RETURNING id
        """
        cur.execute(
            query,
            (
                project_name,
                content_type,
                "auto-urgent",
                request_text,
                text,
                text,
                hashtags or [],
                status,
                tg_channel,
                True,
                "urgent_trigger",
            ),
        )
        row = cur.fetchone()
        conn.commit()
        return row[0] if row else None
    except Exception as e:
        logger.error(f"DB Enqueue Error: {e}")
        conn.rollback()
        return None
    finally:
        cur.close()
        conn.close()


def get_system_flag(name: str):
    """Return jsonb value of a system flag, or None if absent."""
    conn = _connect()
    cur = conn.cursor()
    try:
        cur.execute("SELECT value FROM system_flags WHERE name = %s", (name,))
        row = cur.fetchone()
        return row[0] if row else None
    except Exception as e:
        logger.error(f"system_flags read error: {e}")
        return None
    finally:
        cur.close()
        conn.close()


def set_system_flag(name: str, value) -> bool:
    """Upsert a system flag."""
    import json as _json
    conn = _connect()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            INSERT INTO system_flags (name, value, updated_at)
            VALUES (%s, %s::jsonb, now())
            ON CONFLICT (name) DO UPDATE
            SET value = EXCLUDED.value, updated_at = now()
            """,
            (name, _json.dumps(value)),
        )
        conn.commit()
        return True
    except Exception as e:
        logger.error(f"system_flags write error: {e}")
        conn.rollback()
        return False
    finally:
        cur.close()
        conn.close()


def get_party_line(topic_text, limit: int = 4, min_similarity: float = 0.08):
    """Найти прошлые опубликованные посты, релевантные теме новой срочной новости.

    В production-БД (postgres-local, alpine) pgvector не установлен, поэтому
    embedding-поиск заменён на pg_trgm.similarity по тексту поста. Порог 0.08
    подобран эмпирически: тематически близкие market_digest-посты дают 0.10–0.20,
    нерелевантные — < 0.05. Для коротких topic_text триграммы менее устойчивы,
    поэтому всегда вытаскиваем minimum один свежий пост, если ничего не пройдёт
    по порогу — это даёт модели хоть какую-то «прежнюю позицию».
    """
    conn = _connect()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    topic = topic_text[:4000]
    try:
        cur.execute(
            """
            SELECT
                COALESCE(final_text, smm_text) AS text,
                tg_message_id, tg_channel, published_at,
                similarity(LEFT(COALESCE(final_text, smm_text), 4000), %s) AS similarity
            FROM posts_queue
            WHERE status = 'PUBLISHED'
              AND COALESCE(final_text, smm_text) IS NOT NULL
              AND similarity(LEFT(COALESCE(final_text, smm_text), 4000), %s) > %s
            ORDER BY similarity DESC, published_at DESC NULLS LAST
            LIMIT %s
            """,
            (topic, topic, min_similarity, limit),
        )
        rows = cur.fetchall()
        out = []
        for r in rows:
            channel = (r["tg_channel"] or "").lstrip("@")
            url = (
                f"https://t.me/{channel}/{r['tg_message_id']}"
                if r["tg_message_id"] and channel
                else None
            )
            out.append({
                "similarity": round(float(r["similarity"] or 0), 3),
                "published_at": r["published_at"].date().isoformat() if r["published_at"] else None,
                "tg_message_id": r["tg_message_id"],
                "tg_channel": r["tg_channel"],
                "url": url,
                "text": (r["text"] or "")[:1500],
            })
        return out
    except Exception as e:
        logger.error(f"DB Search Error (party-line): {e}")
        return []
    finally:
        cur.close()
        conn.close()


def get_party_line_context(topic_text, limit: int = 2):
    """Backwards-compatible string версия — собирает party-line в простой текст.
    Новый код должен использовать get_party_line() напрямую."""
    items = get_party_line(topic_text, limit=limit)
    if not items:
        return ""
    out = "\n\nДополнительный контекст из наших прошлых публикаций:\n"
    for it in items:
        url = it["url"] or "(нет ссылки)"
        out += f"\n--- Прошлый пост ({url}) ---\n{it['text'][:1000]}...\n"
    return out
