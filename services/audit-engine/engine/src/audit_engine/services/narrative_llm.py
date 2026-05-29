"""Генерация «нарратива» отчёта через Omniroute (Claude).

Цель: 3 секции, не сводимые к таблицам — `summary`, `why_so`, `final_recommendation`.
Структура и числа в отчёте остаются жёстко детерминированными (Jinja2),
LLM пишет только связный текст вокруг них.

Использование:
    from audit_engine.services.narrative_llm import generate_narrative

    narrative = await generate_narrative(result)
    # → {"summary": "...", "why_so": "...", "final_recommendation": "..."}

Конфиг (env):
    OMNIROUTE_BASE_URL          (default: http://127.0.0.1:20128/v1)
    OMNIROUTE_API_KEY           (REQUIRED для боевого вызова)
    AUDIT_NARRATIVE_MODEL       (default: kr/claude-sonnet-4.5)
    AUDIT_NARRATIVE_FALLBACKS   (comma-separated, default:
                                  cc/claude-sonnet-4-5-20250929,kr/claude-haiku-4.5)
    AUDIT_NARRATIVE_DISABLED    ("1" → возвращает None, никаких LLM-вызовов)

Если ключа нет или LLM лёг — возвращается `None`, шаблон рендерится
без LLM-секций.
"""
from __future__ import annotations

import json
import logging
import os
from typing import Any

import httpx

logger = logging.getLogger(__name__)

OMNIROUTE_BASE_URL = os.environ.get("OMNIROUTE_BASE_URL", "http://127.0.0.1:20128/v1")
OMNIROUTE_API_KEY = os.environ.get("OMNIROUTE_API_KEY", "")
NARRATIVE_MODEL = os.environ.get("AUDIT_NARRATIVE_MODEL", "kr/claude-sonnet-4.5")
NARRATIVE_FALLBACKS = [
    m.strip()
    for m in os.environ.get(
        "AUDIT_NARRATIVE_FALLBACKS",
        "cc/claude-sonnet-4-5-20250929,kr/claude-haiku-4.5",
    ).split(",")
    if m.strip()
]


PROMPT = """Ты — финансовый аналитик «Виктори». Опиши результаты аудита недвижимости
в трёх коротких связных секциях (русский, без воды, без эмодзи).

Данные аудита (JSON):
{result_json}

Верни СТРОГО JSON c полями:
- "summary": одно предложение (≤ 200 символов). Главный вывод.
- "why_so": 3–5 предложений. Объясни, почему EI получился именно такой
  (соотношение ставка/рост цен/инфляция/первоначальный взнос).
- "final_recommendation": 2–4 предложения. Что делать инвестору
  (покупать сейчас / ждать / комбинированная стратегия), с указанием
  ключевого триггера (например «при ставке ниже 14%»).

Только JSON, без markdown-обёртки.
"""


def _serialise_result(result: Any) -> dict[str, Any]:
    """Безопасно достаём поля из AuditResult в простой dict для промпта."""
    try:
        return {
            "complex_name": result.complex_name,
            "apartment_type": result.apartment_type,
            "area_sqm": result.area_sqm,
            "price_total": result.price_total,
            "price_per_sqm": result.price_per_sqm,
            "verdict": str(result.verdict),
            "verdict_explanation": result.verdict_explanation,
            "scenarios": [
                {
                    "name": s.scenario_name,
                    "ei_cash": s.cash.ei,
                    "ei_mortgage": s.mortgage.ei,
                    "ei_deposit": s.deposit.ei,
                    "best_strategy": s.best_strategy,
                    "mortgage_rate": s.params.mortgage_rate,
                    "deposit_rate": s.params.deposit_rate,
                    "price_growth": s.params.price_growth_annual,
                    "inflation": s.params.inflation,
                }
                for s in result.scenarios
            ],
            "risks": result.risks,
        }
    except AttributeError:
        return {}


async def generate_narrative(result: Any) -> dict[str, str] | None:
    """Генерируем нарратив. Любая ошибка → None (шаблон рендерится без секций)."""
    if os.environ.get("AUDIT_NARRATIVE_DISABLED", "").lower() in ("1", "true", "yes"):
        return None
    if not OMNIROUTE_API_KEY:
        logger.info("OMNIROUTE_API_KEY не задан — narrative пропускаем")
        return None

    payload_data = _serialise_result(result)
    if not payload_data:
        return None

    prompt = PROMPT.format(result_json=json.dumps(payload_data, ensure_ascii=False))
    url = f"{OMNIROUTE_BASE_URL.rstrip('/')}/chat/completions"
    headers = {
        "Authorization": f"Bearer {OMNIROUTE_API_KEY}",
        "Content-Type": "application/json",
    }
    model_chain = [NARRATIVE_MODEL, *NARRATIVE_FALLBACKS]

    async with httpx.AsyncClient(timeout=60.0) as client:
        for model_id in model_chain:
            try:
                resp = await client.post(
                    url,
                    headers=headers,
                    json={
                        "model": model_id,
                        "messages": [{"role": "user", "content": prompt}],
                        "temperature": 0.3,
                        "max_tokens": 800,
                        "stream": False,
                    },
                )
                resp.raise_for_status()
                content = (resp.json()["choices"][0]["message"]["content"] or "").strip()
                # Убираем потенциальное ```json ... ``` обрамление
                if content.startswith("```"):
                    content = content.strip("`")
                    if content.lower().startswith("json"):
                        content = content[4:].lstrip()
                parsed = json.loads(content)
                required = {"summary", "why_so", "final_recommendation"}
                if not required.issubset(parsed.keys()):
                    logger.warning("narrative %s: missing keys %s", model_id, required - parsed.keys())
                    continue
                return {k: str(parsed[k]) for k in required}
            except Exception as exc:
                logger.warning("narrative model=%s failed: %s", model_id, exc)
                continue
    return None
