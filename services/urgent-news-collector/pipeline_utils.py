"""Shared utilities for urgent + weekly digest pipelines.

Содержит общую логику форматирования постов, выноs из urgent_trigger.py,
чтобы weekly_digest_trigger.py мог использовать те же стандарты:
- BRAND_TAGS / BRAND_TAG_RE — фиксированные теги «Виктори_*» + регекс для фильтра.
- sanitize_body_html — defensive cleanup от markdown-остатков.
- filter_topic_hashtags — фильтр LLM-тегов (отбрасывает «Виктори*», дубли, лимит 6).
- format_prior_positions — текстовый блок «наши прошлые позиции» для промпта.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from typing import Callable

import requests

logger = logging.getLogger(__name__)


def fmt_ddmmyy(d) -> str:
    """Format a date/datetime/ISO-string as dd.MM.yy (project standard).

    Accepts datetime.date, datetime.datetime, ISO-string ('2026-05-18'),
    or None. Empty/None → '?'. Unparseable strings → returned as-is so
    bugs are visible rather than silently masked.
    """
    if not d:
        return "?"
    if hasattr(d, "strftime"):
        return d.strftime("%d.%m.%y")
    try:
        return datetime.fromisoformat(str(d)).strftime("%d.%m.%y")
    except (ValueError, TypeError):
        return str(d)

# Пути боевого каталога считаются ПРИ ВЫЗОВЕ, а не при импорте: вызывающие
# скрипты подтягивают .env уже после `import pipeline_utils`, и константа,
# вычисленная на импорте, не увидела бы CONVEYOR_HOME из файла.
def conveyor_home() -> str:
    return os.environ.get("CONVEYOR_HOME", "/opt/victory-conveyor")


# Зеркало на сайт. Скрипт живёт в victory (services/chat-host-cron/) и
# деплоится рядом с конвейером; путь наружу снят 11.09.26.
def mirror_script_path() -> str:
    return os.environ.get(
        "MIRROR_SCRIPT", os.path.join(conveyor_home(), "post_news_to_victory.sh")
    )
SITE_BASE_URL = "https://victory62.org"

BRAND_TAGS = ["#Виктори_Главное", "#Виктори_Молния", "#Виктори_Аналитика"]

# Любой авто-тег, начинающийся со слова «Виктори» (любой регистр), отбрасывается —
# бренд-теги мы добавляем сами через BRAND_TAGS.
BRAND_TAG_RE = re.compile(r"^викто[р]и", re.IGNORECASE)


_HTML_TAG_RE = re.compile(r"<[^>]+>")


def _shield_html_tags(text: str):
    """Временно заменить все HTML-теги на плейсхолдеры, чтобы markdown-замены
    не лезли внутрь атрибутов (<a href="...">) и тел тегов. Возвращает
    (shielded_text, mapping placeholders→original)."""
    placeholders = {}

    def repl(m):
        token = f"\x00H{len(placeholders):04d}\x00"
        placeholders[token] = m.group(0)
        return token

    shielded = _HTML_TAG_RE.sub(repl, text)
    return shielded, placeholders


def _unshield_html_tags(text: str, placeholders: dict) -> str:
    for token, original in placeholders.items():
        text = text.replace(token, original)
    return text


def sanitize_body_html(html: str) -> str:
    """Перевести уцелевший markdown в Telegram HTML и убрать запрещённые конструкции.

    Срабатывает даже если модель проигнорировала промпт. Покрывает:
        **bold** / __bold__   → <b>bold</b>
        *italic* / _italic_   → <i>italic</i>
        # Header              → <b>Header</b>
        > blockquote          → <blockquote>blockquote</blockquote>
        #хэштеги в теле       → удаляются (уходят в topic_hashtags)
        <ul>/<li>/<p>/<div>/<br>/<h1-6>/<span> → вырезаются.

    Содержимое HTML-тегов (особенно href-атрибутов) защищено от markdown-замен —
    подчёркивания/звёздочки в URL не превращаются в <i>/<b>.
    """
    if not html:
        return ""

    # 1. Сначала вырезаем запрещённые HTML-теги — это они должны исчезнуть до
    # того, как мы будем шилдить теги для markdown-обработки.
    forbidden = ["ul", "ol", "li", "p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "span"]
    text = html
    for tag in forbidden:
        text = re.sub(rf"</?{tag}\b[^>]*>", "", text, flags=re.IGNORECASE)

    # 2. Защищаем разрешённые HTML-теги от markdown-обработки.
    text, placeholders = _shield_html_tags(text)

    # 3. Markdown bold **x** / __x__ → <b>x</b>
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text, flags=re.DOTALL)
    text = re.sub(r"__(.+?)__", r"<b>\1</b>", text, flags=re.DOTALL)

    # 4. Markdown italic *x* / _x_ → <i>x</i> (защита от смешения с маркерами).
    text = re.sub(r"(?<!\*)\*(\S[^*\n]*?\S?)\*(?!\*)", r"<i>\1</i>", text)
    # Границы по \w, а не по _: иначе «ставку_ЦБ_2026» превращалось в
    # «ставку<i>ЦБ</i>2026». Подчёркивание само входит в \w, так что старая
    # защита от __bold__ сохраняется.
    text = re.sub(r"(?<!\w)_(\S[^_\n]*?\S?)_(?!\w)", r"<i>\1</i>", text)

    # 5. Markdown headers: строки с #/##/### → <b>…</b>
    text = re.sub(r"(?m)^\s*#{1,6}\s+(.+?)\s*$", r"<b>\1</b>", text)

    # 6. Markdown blockquote: «> цитата» → <blockquote>цитата</blockquote>
    def _blockquote(match):
        body = re.sub(r"(?m)^>\s?", "", match.group(0)).rstrip()
        return f"<blockquote>{body}</blockquote>"

    text = re.sub(r"(?m)(?:^>.*(?:\n|$))+", _blockquote, text)

    # 7. Хэштеги в body_html не нужны — уходят в отдельный список.
    # Требование пробела перед # не работало: к этому моменту HTML-теги уже
    # заменены плейсхолдерами, поэтому «<b>#ипотека2026</b>» уходил в пост как
    # есть. Смотрим назад на \w и / — так остаются целыми якоря в URL
    # (…/page#anchor) и решётки внутри слов.
    text = re.sub(r"[ \t]*(?<![\w/])#[\wА-Яа-яЁё_]+", "", text)

    # 8. Восстанавливаем оригинальные HTML-теги.
    text = _unshield_html_tags(text, placeholders)

    # 8a. Тег, внутри которого был только хэштег, остаётся пустым — вычищаем,
    # чтобы не слать в Telegram <b></b>.
    text = re.sub(r"<(b|i|u|s|code)>\s*</\1>", "", text)

    # 9. Тримминг повторных пустых строк.
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    return text


def filter_topic_hashtags(raw):
    """Очистить LLM-список тематических тегов: убрать пустые, дубли, "Виктори*", лимит 6."""
    out = []
    seen = set()
    for t in raw or []:
        if not isinstance(t, str):
            continue
        clean = t.lstrip("#").strip()
        if not clean or BRAND_TAG_RE.match(clean):
            continue
        clean = re.sub(r"\s+", "", clean).strip("#.,;:!?")
        if not clean or clean.lower() in seen:
            continue
        seen.add(clean.lower())
        out.append("#" + clean)
        if len(out) >= 6:
            break
    return out


def notifications_dir() -> str:
    return os.environ.get(
        "NOTIFICATIONS_DIR", os.path.join(conveyor_home(), "notifications")
    )


def notify_failure(
    component: str,
    reason: str,
    detail: str = "",
    chat_id: str | None = None,
    bot_token: str | None = None,
) -> dict:
    """Сообщить о провале конвейера: файл-след и, если задан чат, Telegram.

    Файл кладётся в SHARED/notifications/<component>_failed_<ts>.json — тот же
    механизм и то же именование, что у heartbeat.sh, чтобы агентские сессии
    подбирали его уже существующим способом. Пишется всегда: это дёшево и не
    зависит от сети.

    Telegram — только если передан chat_id (обычно из DIGEST_ALERT_CHAT_ID) и
    есть токен. Без chat_id функция молча ограничивается файлом: технические
    ошибки в публичный канал слать нельзя, а блокировать выкатку ожиданием
    chat_id не хочется.

    Дедуп здесь НЕ делается — вызывающий сам решает, как часто звать (у
    дайджеста окно из 21 запуска в неделю, там дедуп по номеру ISO-недели).

    Возвращает {"file": path|None, "telegram": bool}.
    """
    now = datetime.now(timezone.utc)
    result: dict = {"file": None, "telegram": False}

    payload = {
        "ts": now.isoformat().replace("+00:00", "Z"),
        "component": component,
        "status": "failed",
        "reason": reason,
        "detail": detail[:2000],
    }
    try:
        notif_dir = notifications_dir()
        os.makedirs(notif_dir, exist_ok=True)
        path = os.path.join(
            notif_dir,
            f"{component}_failed_{now.strftime('%Y%m%dT%H%M%SZ')}.json",
        )
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2)
        result["file"] = path
    except Exception as e:
        logger.error(f"notify_failure: cannot write notification file: {e}")

    if not chat_id or not bot_token:
        return result

    text = (
        f"⚠️ <b>{component}</b> — сбой\n\n"
        f"<b>Причина:</b> {reason}\n"
        f"<code>{detail[:600]}</code>"
    )
    try:
        resp = requests.post(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            data={"chat_id": chat_id, "text": text, "parse_mode": "HTML",
                  "disable_web_page_preview": True},
            timeout=20,
        )
        result["telegram"] = resp.status_code == 200 and resp.json().get("ok", False)
        if not result["telegram"]:
            logger.warning(f"notify_failure: telegram {resp.status_code} {resp.text[:200]}")
    except Exception as e:
        logger.warning(f"notify_failure: telegram exception: {e}")

    return result


def mirror_to_victory(meta_path: str, text_path: str) -> str | None:
    """Зеркалит статью на victory62.org и возвращает канонический URL из ответа.

    Запускает post_news_to_victory.sh; скрипт пишет URL в stdout одной строкой
    (и человеческие логи в stderr). Возвращает None если зеркало недоступно,
    токен не задан, или сайт ответил ошибкой — вызывающий код использует
    fallback_site_url() в этом случае.
    """
    mirror_script = mirror_script_path()
    if not os.path.exists(mirror_script):
        logger.warning("[victory62-mirror] script missing: %s", mirror_script)
        return None
    if not os.environ.get("VICTORY_NEWS_TOKEN"):
        logger.warning("[victory62-mirror] VICTORY_NEWS_TOKEN not set; skipping")
        return None
    try:
        result = subprocess.run(
            [mirror_script, meta_path, text_path],
            capture_output=True, text=True, timeout=60, check=False,
        )
    except Exception as e:
        logger.warning("[victory62-mirror] exception: %s", e)
        return None
    if result.returncode != 0:
        logger.warning(
            "[victory62-mirror] rc=%s stderr=%s",
            result.returncode,
            (result.stderr or "").strip()[:300],
        )
        return None
    url = (result.stdout or "").strip().splitlines()
    url = url[-1].strip() if url else ""
    if not url.startswith("http"):
        logger.warning("[victory62-mirror] unexpected stdout: %r", result.stdout[:200])
        return None
    return url


def fallback_site_url(external_id) -> str:
    """Детерминированный URL по external_id — на случай если зеркало не ответило.

    Используется Rails-роутом /news/:slug (event_id для urgent, digest_<date>
    для weekly). Если паттерн на стороне сайта изменится, ссылки в TG могут
    стать битыми — основной путь идёт через mirror_to_victory().
    """
    slug = str(external_id) if external_id is not None else ""
    # Числовой id — это urgent_events.id, а не слаг статьи: /news/:id на стороне
    # Rails резолвится через Article.friendly.find, где слаг строится из
    # заголовка, а числовой fallback уходит в ПЕРВИЧНЫЙ КЛЮЧ articles. Ссылка
    # вела на посторонний материал или в 404. Угадать слаг мы не можем —
    # отдаём раздел новостей.
    if not slug or slug.isdigit():
        return f"{SITE_BASE_URL}/news"
    return f"{SITE_BASE_URL}/news/{slug}"


def build_site_footer(url: str) -> str:
    """Footer для TG-поста: '\\n\\nПодробнее у нас на сайте: <a href=...>...</a>'."""
    safe_url = url.replace('"', "%22")
    return f'\n\n<i>Подробнее у нас на сайте:</i> <a href="{safe_url}">{safe_url}</a>'


# ============================================================================
# LLM fallback chain — публикатор больше не зависит от одной модели в omniroute.
# Зеркалит main.fallbacks из openclaw.json (id="main"),
# но содержит только реально живые сейчас маршруты. Битые перечислены ниже
# в комментарии — вернуть, когда у провайдеров отпустит rate-limit.
# ============================================================================

OMNIROUTE_BASE = os.environ.get("OMNIROUTE_BASE_URL", "http://127.0.0.1:20128/v1")
OPENCLAW_JSON_PATH = os.environ.get(
    # Последняя (и только на чтение) связь с архивом openclaw: срабатывает,
    # лишь если OMNIROUTE_API_KEY не задан в .env. В проде задан — см. .env.example.
    "OPENCLAW_JSON_PATH",
    "/opt/.openclaw/.openclaw/openclaw.json",
)

MAIN_MODEL_CHAIN: list[tuple[str, str, int]] = [
    # provider,    model,                                                          timeout_s
    # Direct Google API — bypasses omniroute entirely. Free tier 1500 RPD/model/key.
    ("google",     "gemini-3-flash-preview",                                       30),
    ("google",     "gemini-2.5-flash",                                             30),
    ("google",     "gemini-2.5-flash-lite",                                        30),
    # Free fallbacks via omniroute (RPM-limited but non-zero quota).
    ("cloudflare", "@cf/meta/llama-3.3-70b-instruct-fp8-fast",                     30),
    ("omniroute",  "openrouter/google/gemini-2.0-flash-exp:free",                  45),
    # Direct Gemini Pro (more expensive but reliable).
    ("google",     "gemini-2.5-pro",                                               45),
    # PAID — last resort.
    ("openrouter", "anthropic/claude-sonnet-4",                                    60),
]
PAID_MODELS: set[tuple[str, str]] = {("openrouter", "anthropic/claude-sonnet-4")}

# Removed from chain 2026-05-14 (rate-limited / dead):
#   groq/llama-3.3-70b-versatile          — TPD exhausted, 8h+ cooldown
#   groq/openai/gpt-oss-120b              — same Groq TPD
#   openrouter/google/gemma-4-31b-it:free — RPM 429 spam
#   openrouter/z-ai/glm-4.5-air:free      — RPM 429
#   openrouter/nvidia/nemotron-3-super-120b-a12b:free — RPM 429
#   openrouter/openai/gpt-oss-120b:free   — RPM 429
#   cloudflare @cf/openai/gpt-oss-120b    — duplicate of llama-3.3 above
# Документация прочих "битых":
#   omniroute cerebras/qwen-3-235b-a22b-instruct-2507     — 429 rate limit
#   omniroute openrouter/qwen/qwen3-coder:free            — timeout > 30s
#   omniroute openrouter/meta-llama/llama-3.3-70b-instruct:free — timeout > 30s
#   omniroute cc/* и kr/*                                 — no credentials


_OPENCLAW_JSON_CACHE: dict | None = None


def _load_openclaw_json() -> dict:
    global _OPENCLAW_JSON_CACHE
    if _OPENCLAW_JSON_CACHE is None:
        try:
            with open(OPENCLAW_JSON_PATH, "r", encoding="utf-8") as f:
                _OPENCLAW_JSON_CACHE = json.load(f)
        except Exception as e:
            logger.warning("[llm-chain] cannot read %s: %s", OPENCLAW_JSON_PATH, e)
            _OPENCLAW_JSON_CACHE = {}
    return _OPENCLAW_JSON_CACHE


def _get_provider_creds(provider: str) -> dict:
    """Вернуть {api_key, base_url} для провайдера. ENV > openclaw.json."""
    if provider == "omniroute":
        key = os.environ.get("OMNIROUTE_API_KEY")
        if not key:
            key = _load_openclaw_json().get("models", {}).get("providers", {}).get("omniroute", {}).get("apiKey")
        return {"api_key": key, "base_url": OMNIROUTE_BASE}
    if provider == "openrouter":
        key = os.environ.get("OPENROUTER_API_KEY")
        base = os.environ.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
        if not key:
            cfg = _load_openclaw_json().get("models", {}).get("providers", {}).get("openrouter", {})
            key = cfg.get("apiKey")
            base = cfg.get("baseUrl") or base
        return {"api_key": key, "base_url": base}
    if provider == "cloudflare":
        key = os.environ.get("CLOUDFLARE_AI_API_KEY")
        base = os.environ.get("CLOUDFLARE_AI_BASE_URL")
        if not key or not base:
            cfg = _load_openclaw_json().get("models", {}).get("providers", {}).get("cloudflare", {})
            key = key or cfg.get("apiKey")
            base = base or cfg.get("baseUrl")
        return {"api_key": key, "base_url": base}
    if provider == "google":
        key = os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")
        base = os.environ.get("GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta")
        return {"api_key": key, "base_url": base}
    raise ValueError(f"unknown provider: {provider}")


def _call_google_direct(model: str, messages: list[dict], temperature: float, max_tokens: int, timeout: int) -> str:
    """Direct Gemini API call (bypasses omniroute). Free tier 1500 RPD per model per key.

    `model` argument can be 'gemini-2.5-flash' or 'gemini/gemini-2.5-flash' (strips prefix).
    """
    creds = _get_provider_creds("google")
    if not creds["api_key"]:
        raise RuntimeError("GEMINI_API_KEY missing")
    model_id = model.split("/", 1)[-1] if "/" in model else model
    url = f"{creds['base_url'].rstrip('/')}/models/{model_id}:generateContent"
    # Convert OpenAI-style messages → Gemini format.
    parts: list[dict] = []
    for m in messages:
        content = m.get("content")
        if isinstance(content, str) and content:
            parts.append({"text": content})
    if not parts:
        raise RuntimeError("empty messages for google direct")
    generation_config = {
        "temperature": temperature,
        "maxOutputTokens": max_tokens,
    }
    # thinkingBudget: 0 гасит «размышления» и экономит токены, но отключение
    # поддерживают не все модели: gemini-2.5-pro на ноль отвечает 400. Шаг
    # цепочки становился мёртвым, и каждый деградировавший прогон доезжал до
    # платного хвоста. Для pro-моделей параметр не отправляем.
    if "pro" not in model_id:
        generation_config["thinkingConfig"] = {"thinkingBudget": 0}
    payload = {
        "contents": [{"parts": parts}],
        "generationConfig": generation_config,
    }
    resp = requests.post(url, params={"key": creds["api_key"]}, json=payload, timeout=timeout)
    if resp.status_code != 200:
        body = (resp.text or "")[:300]
        raise RuntimeError(f"HTTP {resp.status_code}: {body}")
    data = resp.json()
    try:
        cand = data["candidates"][0]
        # parts may be missing when MAX_TOKENS — treat as empty.
        out_parts = cand.get("content", {}).get("parts") or []
        content = "".join(p.get("text", "") for p in out_parts).strip()
    except (KeyError, IndexError, TypeError):
        raise RuntimeError(f"unexpected gemini response: {str(data)[:200]}")
    if not content:
        finish = (cand.get("finishReason") or "unknown") if 'cand' in locals() else "?"
        raise RuntimeError(f"empty gemini content (finish={finish})")
    return content


def _call_omniroute_sse(model, messages, temperature, max_tokens, timeout) -> str:
    """omniroute требует stream:true — без него STREAM_READINESS_TIMEOUT даже на живых моделях."""
    creds = _get_provider_creds("omniroute")
    if not creds["api_key"]:
        raise RuntimeError("OMNIROUTE_API_KEY missing")
    url = f"{creds['base_url'].rstrip('/')}/chat/completions"
    headers = {
        "Authorization": f"Bearer {creds['api_key']}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
    }
    chunks: list[str] = []
    with requests.post(url, json=payload, headers=headers, timeout=timeout, stream=True) as resp:
        if resp.status_code != 200:
            resp.encoding = "utf-8"
            body = (resp.text or "")[:300]
            raise RuntimeError(f"HTTP {resp.status_code}: {body}")
        # text/event-stream без charset → requests падает на ISO-8859-1 (RFC 2616).
        # Декодируем bytes сами как UTF-8, иначе кириллица превращается в Ð-кашу.
        for raw_bytes in resp.iter_lines(decode_unicode=False):
            if not raw_bytes:
                continue
            raw_line = raw_bytes.decode("utf-8", errors="replace")
            if not raw_line.startswith("data:"):
                continue
            data_str = raw_line[5:].strip()
            if data_str == "[DONE]":
                break
            try:
                obj = json.loads(data_str)
            except Exception:
                continue
            try:
                delta = obj["choices"][0].get("delta") or {}
                piece = delta.get("content") or ""
                if piece:
                    chunks.append(piece)
            except (KeyError, IndexError, TypeError):
                continue
    content = "".join(chunks).strip()
    if not content:
        raise RuntimeError("empty content from omniroute SSE")
    return content


def _call_openai_compatible(provider, model, messages, temperature, max_tokens, timeout) -> str:
    """Non-stream POST для cloudflare и прямого openrouter."""
    creds = _get_provider_creds(provider)
    if not creds["api_key"] or not creds["base_url"]:
        raise RuntimeError(f"{provider} credentials missing")
    url = f"{creds['base_url'].rstrip('/')}/chat/completions"
    headers = {
        "Authorization": f"Bearer {creds['api_key']}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
    }
    resp = requests.post(url, json=payload, headers=headers, timeout=timeout)
    resp.encoding = "utf-8"
    if resp.status_code != 200:
        body = (resp.text or "")[:300]
        raise RuntimeError(f"HTTP {resp.status_code}: {body}")
    data = resp.json()
    try:
        content = (data["choices"][0]["message"]["content"] or "").strip()
    except (KeyError, IndexError, TypeError):
        raise RuntimeError(f"unexpected response shape: {str(data)[:200]}")
    if not content:
        raise RuntimeError("empty content")
    return content


def complete_with_fallbacks(
    messages: list[dict],
    *,
    temperature: float = 0.2,
    max_tokens: int = 1024,
    parse_fn: Callable[[str], object] | None = None,
    chain: list[tuple[str, str, int]] | None = None,
    overall_deadline_s: float | None = 120.0,
) -> tuple[str, str]:
    """Пройти по цепочке моделей и вернуть (model_label, content).

    overall_deadline_s — общий wall-clock потолок (None = без потолка). Если
    суммарное время попыток превысило бюджет, бросаем RuntimeError, не дожидаясь
    остатка цепочки. Это страховка от пирамидальных таймаутов (7 моделей × 30 с).
    """
    use_chain = chain if chain is not None else MAIN_MODEL_CHAIN
    last_err: Exception | None = None
    attempts: list[str] = []
    t0 = time.monotonic()
    for provider, model, timeout in use_chain:
        if overall_deadline_s is not None:
            elapsed = time.monotonic() - t0
            if elapsed > overall_deadline_s:
                logger.warning(
                    "[llm-chain] overall deadline %.1fs exceeded after %.1fs — bail (tried: %s)",
                    overall_deadline_s, elapsed, ", ".join(attempts) or "—",
                )
                raise RuntimeError(
                    f"all models failed (overall deadline {overall_deadline_s}s exceeded); "
                    f"last error: {last_err}"
                )
        label = f"{provider}/{model}"
        if (provider, model) in PAID_MODELS:
            logger.warning("[llm-chain] falling back to PAID model %s after: %s", label, ", ".join(attempts[-3:]) or "—")
        try:
            if provider == "omniroute":
                content = _call_omniroute_sse(model, messages, temperature, max_tokens, timeout)
            elif provider == "google":
                content = _call_google_direct(model, messages, temperature, max_tokens, timeout)
            else:
                content = _call_openai_compatible(provider, model, messages, temperature, max_tokens, timeout)
            if parse_fn is not None:
                parse_fn(content)
            logger.info("[llm-chain] %s ok", label)
            return label, content
        except Exception as e:
            err_short = str(e)[:200].replace("\n", " ")
            logger.warning("[llm-chain] %s skipped: %s", label, err_short)
            attempts.append(label)
            last_err = e
            continue
    raise RuntimeError(f"all models failed; last error: {last_err}")


def format_prior_positions(items: list) -> str:
    """Подготовить блок «Наши прошлые позиции» для промпта."""
    if not items:
        return (
            "Прошлых публикаций по этой теме нет — пиши с нуля, в спокойном экспертном тоне, "
            "без слишком категоричных утверждений."
        )
    lines = []
    for i, it in enumerate(items, 1):
        date = fmt_ddmmyy(it.get("published_at"))
        url = it.get("url") or "(нет URL)"
        msg_id = it.get("tg_message_id") or "—"
        sim = it.get("similarity")
        excerpt = (it.get("text") or "").strip().replace("\n", " ")
        if len(excerpt) > 800:
            excerpt = excerpt[:800] + "…"
        lines.append(
            f"[{i}] tg_message_id={msg_id} · {date} · sim={sim} · {url}\n    «{excerpt}»"
        )
    return "\n".join(lines)
