import os
import json
import logging
import re
import socket
import feedparser
import requests
from datetime import datetime
import psycopg2
from pydantic import BaseModel, Field
from dotenv import load_dotenv

from classify_retry import GIVE_UP_AFTER_HOURS, ChainBreaker, RetryLedger, retry_key
from pipeline_utils import CLASSIFIER_CHAIN, complete_with_fallbacks, conveyor_home
from urgent_relevance import KNOWN_EVENT_TYPES, gate_urgent

# feedparser использует urllib без таймаута; без socket-defaults один медленный
# RSS-источник (например, rbc.ru) виснет навсегда. 15 сек на запрос достаточно.
socket.setdefaulttimeout(15)

# Загружаем переменные из .env скриптов (рядом с этим файлом).
load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))

# --- Configuration ---
# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# RSS Sources for Real Estate and Financial News.
# weight = доверие к источнику для премиум-аудитории Виктори.
#   high   — профильные / первоисточники (ЦБ, недвижка-секции, Ведомости. Финансы).
#   medium — общеделовые новостные ленты с переменным сигналом.
#   low    — таблоидно-лайфстайл уклон, много шума типа ЧМ-билетов и брачных бумов.
RSS_SOURCES = [
    {"name": "Новости ЦБ РФ",      "url": "http://www.cbr.ru/rss/RssNews",                              "weight": "high"},
    {"name": "РБК Недвижимость",   "url": "https://realty.rbc.ru/rss/index.rss",                        "weight": "high"},
    {"name": "Ведомости. Финансы", "url": "https://www.vedomosti.ru/rss/rubric/finance.xml",            "weight": "high"},
    {"name": "РИА Недвижимость",   "url": "https://realty.ria.ru/export/rss2/index.xml",                "weight": "high"},
    {"name": "Интерфакс",          "url": "https://www.interfax.ru/rss.asp",                            "weight": "medium"},
    {"name": "РБК Экономика",      "url": "https://rssexport.rbc.ru/rbcnews/news/30/full.rss",          "weight": "medium"},
    {"name": "Forbes Россия",      "url": "https://www.forbes.ru/feeds/all",                            "weight": "low"},
]

ENTRY_LIMIT_PER_SOURCE = 15

# urgent_events живут в news-DB (audit-v2-postgres:5433) — там есть pgvector
# для embedding-дедупа. Production posts_queue для publisher_bot — в другой
# базе (postgres-local:5432) и подключается уже на стороне content_db_utils.
DB_HOST = os.environ.get("NEWS_DB_HOST") or os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("NEWS_DB_PORT") or "5433"
DB_NAME = os.environ.get("NEWS_DB_NAME") or os.environ.get("DB_NAME", "re_audit")
DB_USER = os.environ.get("NEWS_DB_USER") or os.environ.get("DB_USER", "audit_user")
DB_PASSWORD = os.environ.get("NEWS_DB_PASSWORD") or os.environ.get("DB_PASSWORD")

# LLM-вызов идёт через pipeline_utils.complete_with_fallbacks (in-process
# fallback-цепочка из бесплатных моделей groq/openrouter/cloudflare с платным
# anthropic/claude-sonnet-4 в самом конце). Если задан URGENT_COLLECTOR_MODEL —
# используется как единственная модель (override; полезно для отладки).
URGENT_COLLECTOR_MODEL_OVERRIDE = os.environ.get("URGENT_COLLECTOR_MODEL")


# --- Data Models ---
class NewsAnalysisResult(BaseModel):
    """Результат 4-bucket классификатора.

    relevance_tier:
      URGENT  — в TG-канал сейчас. Только недвижимость РФ либо прямое
                ограничение на капитал, и только свершившийся факт.
      DIGEST  — в еженедельный экспертный дайджест (аналитика, налоговая практика, премиум-тренды).
      ARCHIVE — хранится с embedding для будущего семантического поиска (off-topic, но осмысленное).
      NOISE   — не хранится вообще (реклама, погода, ЖКХ, криминал, спорт-результаты).
    """
    relevance_tier: str = Field(description="URGENT | DIGEST | ARCHIVE | NOISE")
    event_type: str = Field(description="Подтип события (KEY_RATE, TAX_CHANGE, EXPERT_ANALYSIS и т.п.)")
    audience_fit: str = Field(description="PREMIUM | MASS | UNKNOWN — соответствие премиум-аудитории Виктори")
    reasoning: str = Field(description="Краткое объяснение, почему именно это ведро")

    @property
    def is_urgent(self) -> bool:
        """Backward-compat: код, ожидающий булеан is_urgent, продолжает работать."""
        return self.relevance_tier == "URGENT"

# --- Database Operations ---
def get_db_connection():
    """Establish and return a connection to the PostgreSQL database."""
    try:
        conn = psycopg2.connect(
            host=DB_HOST,
            port=DB_PORT,
            dbname=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD
        )
        return conn
    except Exception as e:
        logger.error(f"Error connecting to database: {e}")
        return None

# Окно, в котором запись без <link> считается уже виденной. По URL такие
# записи не ловятся вовсе (source_url IS NULL), поэтому ключ — заголовок.
SEEN_HEADLINE_WINDOW_DAYS = int(os.environ.get("SEEN_HEADLINE_WINDOW_DAYS", "14"))


def already_seen(conn, url: str | None, headline: str) -> bool:
    """Cheap pre-LLM dedup: не платить за классификацию того, что уже видели.

    По URL — точное совпадение. Записи без <link> проходят мимо и URL-проверки,
    и частичного ON CONFLICT (он игнорирует NULL), поэтому для них ключом
    становится заголовок в окне SEEN_HEADLINE_WINDOW_DAYS. Без этого такая
    новость переклассифицируется каждый прогон и уходит в канал повторно, как
    только истечёт 48-часовой якорь дедупа.
    """
    try:
        with conn.cursor() as cur:
            if url:
                cur.execute("SELECT 1 FROM urgent_events WHERE source_url = %s LIMIT 1", (url,))
            elif headline:
                cur.execute(
                    "SELECT 1 FROM urgent_events "
                    "WHERE source_url IS NULL AND headline = %s "
                    "  AND created_at > NOW() - make_interval(days => %s) LIMIT 1",
                    (headline, SEEN_HEADLINE_WINDOW_DAYS),
                )
            else:
                return False
            return cur.fetchone() is not None
    except Exception as e:
        # Без rollback транзакция остаётся в aborted-состоянии и следующий
        # INSERT падает с InFailedSqlTransaction — одна битая проверка
        # обваливала всю оставшуюся ленту.
        logger.error(f"already_seen check failed: {e}")
        return False
    finally:
        # SELECT открыл транзакцию — её надо закрыть. Иначе соединение висит
        # idle-in-transaction всё время LLM-вызовов (минуты) и держит xmin
        # horizon, мешая autovacuum.
        try:
            conn.rollback()
        except Exception:
            pass


def _safe_embed(text: str) -> list[float] | None:
    """Сгенерить embedding или вернуть None при квоте/ошибке (запись всё равно создаётся)."""
    try:
        from content_db_utils import get_embedding
        vec = get_embedding(text)
        if vec is None:
            return None
        return vec
    except Exception as e:
        logger.warning(f"_safe_embed failed: {e}")
        return None


def insert_urgent_event(conn, event_type: str, headline: str, details: str,
                        source_url: str = None,
                        relevance_tier: str = "URGENT",
                        audience_fit: str = "UNKNOWN",
                        embedding: list[float] | None = None):
    """Insert news event into urgent_events. ON CONFLICT silently skips duplicates by source_url.

    relevance_tier — URGENT/DIGEST/ARCHIVE/NOISE. NOISE пишется без эмбеддинга
    и служит только отметкой «уже классифицировано» для already_seen.
    embedding — list[float] длины 3072 (gemini-embedding-001) или None.
    """
    try:
        with conn.cursor() as cur:
            insert_query = """
                INSERT INTO urgent_events
                    (event_type, headline, details, source_url,
                     relevance_tier, audience_fit, embedding)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (source_url) WHERE source_url IS NOT NULL DO NOTHING
            """
            cur.execute(insert_query, (
                event_type, headline, details, source_url,
                relevance_tier, audience_fit, embedding,
            ))
            conn.commit()
            has_emb = "+emb" if embedding is not None else "no-emb"
            logger.info(f"Inserted [{relevance_tier}/{event_type}/{has_emb}] {headline[:80]}")
    except Exception as e:
        logger.error(f"Failed to insert event into database: {e}")
        conn.rollback()

# --- Core Logic ---
# Единая таксономия живёт в urgent_relevance — там же, где решается, что из
# неё имеет право на публикацию. RATE_CHANGE (2026-08-08) разделён на
# KEY_RATE и FX_RATE: слитый тип отправлял курс доллара в канал как решение
# по ставке.
ALLOWED_EVENT_TYPES = KNOWN_EVENT_TYPES
ALLOWED_TIERS = {"URGENT", "DIGEST", "ARCHIVE", "NOISE"}
ALLOWED_AUDIENCE = {"PREMIUM", "MASS", "UNKNOWN"}

CLASSIFIER_PROMPT = """Ты — фильтр новостей для бренда «Виктори», работающего в премиум-сегменте
рынка недвижимости РФ. Аудитория: владельцы крупного капитала, рассматривают
недвижимость как инструмент сохранения и преумножения капитала. Цель — экспертный
контент, никакого мусора и «как у всех».

Распредели новость по одному из 4 ведер.

URGENT — публиковать НЕМЕДЛЕННО в TG-канал. Ставь этот тир, только если
выполнены ОБА условия сразу.

  УСЛОВИЕ 1 — ПРЕДМЕТ. Событие касается либо (а) рынка недвижимости РФ:
  сделки, жильё, ипотека, ДДУ/эскроу, КРТ, ИЖС, земля, налоги на
  недвижимость, аренда; либо (б) прямого ограничения на капитал владельца:
  валютный контроль по сделкам, налог на капитал, заморозка или конфискация
  активов, доступ к банковским инструментам расчёта.

  УСЛОВИЕ 2 — СОБЫТИЙНОСТЬ. Это свершившийся факт с конкретикой (принят,
  подписан, вступил в силу, ставка снижена/повышена). НЕ обзор, НЕ анонс,
  НЕ законопроект в первом чтении, НЕ реквизиты документа, НЕ сводка за день.

Не выполнено хотя бы одно условие — это НЕ URGENT. Сомневаешься — ставь DIGEST.

  ТОЧНОЕ ЗНАЧЕНИЕ ДВУХ ТИПОВ (их чаще всего растягивают):
  • KEY_RATE — ТОЛЬКО решение Банка России по ключевой ставке или официальный
    сигнал о её будущем уровне. Фондовый рынок, производство, комментарии о
    состоянии экономики — это MARKET_TREND или MACRO_ECONOMICS, не KEY_RATE.
  • CAPITAL_CONTROL — ТОЛЬКО ограничение, которое напрямую бьёт по частному
    владельцу капитала в РФ: его сделки, счета, валютные операции, владение
    активами. Меры против компаний, иностранного бизнеса, чужих государств,
    а также предупреждения и заявления о рисках сюда НЕ относятся.

НИКОГДА не URGENT, даже из источника высокого доверия:
  • геополитика, военные действия, удары, конфликты;
  • санкционные пакеты и голосования по ним — кроме случая, когда в самой
    новости есть прямое ограничение на сделки с недвижимостью или на капитал
    (тогда это CAPITAL_CONTROL);
  • биржевые индексы, котировки, дивиденды, отчётности компаний;
  • курсы валют (доллар, евро, юань) в любом виде — это FX_RATE, не ставка;
  • реквизиты НПА без описания сути («Указание … № 7373-У», «Вестник …»).

DIGEST — в еженедельный экспертный дайджест. Не срочно, но содержательно
для премиум-аудитории:
  • Экспертная аналитика и прогнозы по рынку RE / процентным ставкам.
  • Серьёзные макроэкономические обзоры (инфляция, ВВП, прогноз ставки).
  • Тренды в премиум-сегменте, эксклюзивные ЖК, инвест-объекты, ЗПИФы недвижимости.
  • Налоговая практика, кейсы, разъяснения ФНС/Минфина.
  • Аналитика рынка капитала (рубль, евробонды, золото, депозиты) в связке с RE.

ARCHIVE — не для публикации сейчас, но сохранить и проэмбеддить для будущего
семантического поиска. Это любые осмысленные мирские новости, которые могут
понадобиться при ретроспективе:
  • Глобальная экономика без прямого RE-эффекта (китайский ритейл, ЧМ по футболу,
    автомобильный рынок и т.п.).
  • Социальные тренды (демография, миграция, lifestyle премиум-сегмента).
  • Корп-новости девелоперов БЕЗ отраслевого эффекта (назначения, бренд-релизы).

NOISE — выбросить, НЕ хранить:
  • Реклама, маркетинговые объявления, спонсорский контент.
  • Погода, ЖКХ-аварии, криминал, ДТП, региональные ЧП.
  • Спорт-результаты, шоу-бизнес, гороскопы, рецепты.
  • Дубли мусорных пресс-релизов, мнения без новых фактов.

Источник новости: {source_name} (доверие к источнику: {source_weight}).
К source_weight=low относись скептичнее: для URGENT нужно очень явное СОБЫТИЕ.

Заголовок: {headline}
Краткое содержание: {summary}

Верни строго JSON-объект без пояснений:
{{
  "relevance_tier": "URGENT|DIGEST|ARCHIVE|NOISE",
  "event_type": "KEY_RATE|FX_RATE|LAW_UPDATE|TAX_CHANGE|MORTGAGE_POLICY|CAPITAL_CONTROL|MACRO_ECONOMICS|EXPERT_ANALYSIS|MARKET_TREND|OFF_TOPIC|NONE",
  "audience_fit": "PREMIUM|MASS|UNKNOWN",
  "reasoning": "<1-2 предложения почему именно это ведро>"
}}"""


def _parse_classifier_json(raw: str) -> dict:
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw, flags=re.IGNORECASE)
    # Иногда модель кладёт JSON внутри текста — попытаемся выцепить первый объект.
    if not raw.startswith("{"):
        m = re.search(r"\{.*\}", raw, flags=re.DOTALL)
        if m:
            raw = m.group(0)
    data = json.loads(raw)
    if "relevance_tier" not in data:
        raise ValueError("missing relevance_tier in JSON")
    return data


class ClassifierUnavailable(RuntimeError):
    """Цепочка моделей не дала разбираемого ответа."""


def analyze_news_item(headline: str, summary: str,
                       source_name: str = "Unknown", source_weight: str = "medium") -> NewsAnalysisResult:
    """Classify via fallback chain (см. pipeline_utils.CLASSIFIER_CHAIN).

    source_weight ∈ {high, medium, low} — hint классификатору о доверии к источнику.
    """
    prompt = CLASSIFIER_PROMPT.format(
        headline=headline,
        summary=summary[:1500],
        source_name=source_name,
        source_weight=source_weight,
    )
    chain_override = CLASSIFIER_CHAIN
    if URGENT_COLLECTOR_MODEL_OVERRIDE:
        chain_override = [("omniroute", URGENT_COLLECTOR_MODEL_OVERRIDE, 60)]
    try:
        _, raw = complete_with_fallbacks(
            messages=[{"role": "user", "content": prompt}],
            temperature=0.1,
            max_tokens=400,
            parse_fn=_parse_classifier_json,
            chain=chain_override,
            # 150, а не 90: три шага Google по 30 с таймаута съедали весь
            # бюджет, и зависший Google не пускал к бесплатным моделям OpenRouter.
            # 150 гарантирует попытку всех трёх; два сбоя подряд всё равно
            # останавливают прогон (classify_retry), так что худший прогон — ~5 мин.
            overall_deadline_s=150.0,
        )
        data = _parse_classifier_json(raw)
        tier = (data.get("relevance_tier") or "NOISE").upper()
        if tier not in ALLOWED_TIERS:
            tier = "NOISE"
        event_type = (data.get("event_type") or "NONE").upper()
        if event_type not in ALLOWED_EVENT_TYPES:
            event_type = "NONE"
        audience_fit = (data.get("audience_fit") or "UNKNOWN").upper()
        if audience_fit not in ALLOWED_AUDIENCE:
            audience_fit = "UNKNOWN"
        return NewsAnalysisResult(
            relevance_tier=tier,
            event_type=event_type,
            audience_fit=audience_fit,
            reasoning=str(data.get("reasoning", ""))[:500],
        )
    except Exception as e:
        # Не NOISE: строка в urgent_events навсегда закрыла бы новость для
        # повторной классификации. Решение, ждать или сдаваться, — в process_feed.
        raise ClassifierUnavailable(str(e)) from e


def _classifier_error_result(error: Exception) -> NewsAnalysisResult:
    # Безопасный дефолт: точно не публикуем как URGENT.
    return NewsAnalysisResult(
        relevance_tier="NOISE", event_type="NONE", audience_fit="UNKNOWN",
        reasoning=f"classifier_error: {error}",
    )


def process_feed(source: dict, conn, ledger: RetryLedger, breaker: ChainBreaker):
    """Fetch and process a single RSS feed.

    Новость, на которой упала цепочка, не пишется и ждёт следующего прогона
    (см. classify_retry). После BREAKER_THRESHOLD сбоев подряд лента бросается:
    main() увидит breaker.tripped и не пойдёт в остальные.
    """
    logger.info(f"Fetching feed: {source['name']}")
    
    try:
        feed = feedparser.parse(source["url"])
        
        if feed.bozo:
            logger.warning(f"Malformed feed from {source['name']}: {feed.bozo_exception}")
            # Continue processing as feedparser often recovers partial data
            
        for entry in feed.entries[:ENTRY_LIMIT_PER_SOURCE]:
            if breaker.tripped:
                return

            headline = getattr(entry, 'title', '')
            summary = getattr(entry, 'summary', '')
            # NULL, а не '': ON CONFLICT (source_url) WHERE source_url IS NOT NULL
            # игнорирует NULL, но '' для него — обычное значение. С пустой
            # строкой вторая же запись без <link> считалась дублем первой и
            # молча терялась — причём уже после оплаченного LLM-вызова.
            link = getattr(entry, 'link', '') or None

            if not headline:
                continue

            # URL-dedup до LLM-вызова — экономит токены на повторных RSS-записях
            # (раньше «ставка 14,5%» уходила к Gemini 3+ раза за полчаса).
            if already_seen(conn, link, headline):
                logger.debug(f"Skip (already seen): {headline}")
                continue

            logger.debug(f"Analyzing: {headline}")
            key = retry_key(link, headline)
            try:
                analysis = analyze_news_item(
                    headline, summary,
                    source_name=source["name"],
                    source_weight=source.get("weight", "medium"),
                )
            except ClassifierUnavailable as e:
                breaker.failure()
                if not ledger.record_failure(key, datetime.now()):
                    logger.warning(f"Classifier unavailable, retry next run: {headline[:80]} ({e})")
                    continue
                logger.error(
                    f"Classifier unavailable for {GIVE_UP_AFTER_HOURS}h, giving up → NOISE: "
                    f"{headline[:80]} ({e})"
                )
                analysis = _classifier_error_result(e)
                # Дальше already_seen увидит строку NOISE — ждать больше нечего.
                ledger.forget(key)
            else:
                breaker.success()
                ledger.forget(key)

            details = (
                f"Source: {source['name']}\nLink: {link or '—'}\nSummary: {summary}\n\n"
                f"AI Analysis ({analysis.relevance_tier}/{analysis.audience_fit}): "
                f"{analysis.reasoning}"
            )

            # NOISE пишем без эмбеддинга — строка нужна только как отметка
            # «уже классифицировано». Без неё запись, провисевшая в ленте трое
            # суток, стоила ~144 вызовов классификатора, а цепочка кончается
            # платной моделью. Дайджест эти строки не видит: он фильтрует
            # relevance_tier IN ('URGENT', 'DIGEST').
            if analysis.relevance_tier == "NOISE":
                logger.debug(f"NOISE [{analysis.event_type}]: {headline[:80]}")
                insert_urgent_event(
                    conn,
                    event_type=analysis.event_type,
                    headline=headline,
                    details=details,
                    source_url=link,
                    relevance_tier="NOISE",
                    audience_fit=analysis.audience_fit,
                    embedding=None,
                )
                continue

            # Детерминированная страховка поверх суждения модели: гейт режет
            # то, что классификатор ошибочно поднял до URGENT (курс валют под
            # видом ставки, реквизиты НПА, геополитика). Понижаем до DIGEST,
            # а не выбрасываем — событие ещё пригодится дайджесту.
            if analysis.relevance_tier == "URGENT":
                passes, gate_reason = gate_urgent(analysis.event_type, headline)
                if not passes:
                    logger.info(f"Gate demoted URGENT→DIGEST [{gate_reason}]: {headline[:80]}")
                    analysis.relevance_tier = "DIGEST"

            # URGENT/DIGEST/ARCHIVE — эмбеддим. details собран выше, но тир мог
            # смениться гейтом — пересобираем, чтобы в тексте стоял финальный.
            details = (
                f"Source: {source['name']}\nLink: {link or '—'}\nSummary: {summary}\n\n"
                f"AI Analysis ({analysis.relevance_tier}/{analysis.audience_fit}): "
                f"{analysis.reasoning}"
            )
            embedding = _safe_embed(headline + " — " + (summary or "")[:1500])
            insert_urgent_event(
                conn,
                event_type=analysis.event_type,
                headline=headline,
                details=details,
                source_url=link,
                relevance_tier=analysis.relevance_tier,
                audience_fit=analysis.audience_fit,
                embedding=embedding,
            )
            if analysis.relevance_tier == "URGENT":
                logger.warning(f"URGENT NEWS DETECTED: {headline} -> {analysis.event_type}")
                
    except Exception as e:
        logger.error(f"Failed to process feed {source['name']}: {e}")

def main():
    logger.info("Starting Urgent News Collector")
    
    # Initialize DB Connection
    conn = get_db_connection()
    if not conn:
        logger.error("Exiting due to database connection failure.")
        return

    ledger = RetryLedger(os.path.join(conveyor_home(), "state", "classifier_pending.json")).load()
    ledger.prune(datetime.now())
    breaker = ChainBreaker()

    # Process all configured feeds
    try:
        for source in RSS_SOURCES:
            process_feed(source, conn, ledger, breaker)
            if breaker.tripped:
                logger.error(
                    f"LLM chain down ({breaker.consecutive} failures in a row) — "
                    f"stopping run; {ledger.pending()} item(s) wait for the next one"
                )
                break
    finally:
        try:
            ledger.save()
        except OSError as e:
            logger.error(f"Failed to save classifier retry ledger: {e}")

    # Cleanup
    if conn:
        conn.close()
        logger.info("Database connection closed.")
        
    logger.info("Urgent News Collector finished.")

if __name__ == "__main__":
    main()
