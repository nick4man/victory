"""Детерминированный гейт релевантности для срочных новостей.

Единственная точка правды о том, что имеет право уйти в @rznvictory с меткой
⚡СРОЧНО. Вызывается из двух мест (см. спеку
IT/docs/specs/2026-08-08-urgent-news-relevance-design.md):

  • urgent_collector.process_feed — сразу после ответа LLM, чтобы мусор не
    садился в базу с relevance_tier='URGENT';
  • urgent_trigger.check_urgent_events — перед генерацией поста, как
    страховка от ошибки классификатора и от строк, уже лежащих в очереди.

Здесь только чистые функции: ни БД, ни сети, ни LLM. Это осознанно — слой
должен оставаться проверяемым в отрыве от инфраструктуры и не зависеть от
того, какая модель победила в fallback-цепочке.

Замер, из которого выросли правила (30 дней, до 2026-08-08): 84 публикации
с меткой СРОЧНО, из них 3 из профильных лент недвижимости. Основной мусор —
геополитика (MACRO_ECONOMICS, 77 событий), курсы валют внутри RATE_CHANGE и
индексы бюллетеней ЦБ без содержания.
"""

from __future__ import annotations

import re

# Типы событий, имеющие право на публикацию как URGENT.
#
# MACRO_ECONOMICS сознательно отсутствует: тип сохраняется для хранения и
# дайджеста, но за 30 дней дал 77 URGENT-событий, из которых до недвижимости
# не относилось практически ничего (санкции, Иран, биржевые индексы).
# FX_RATE отсутствует по той же причине — курс валют не является событием
# рынка недвижимости.
URGENT_ELIGIBLE_TYPES = frozenset({
    "KEY_RATE",
    "LAW_UPDATE",
    "TAX_CHANGE",
    "MORTGAGE_POLICY",
    "CAPITAL_CONTROL",
})

# Все типы, которые классификатор вправе вернуть. Нужен, чтобы отличать
# «известный, но не публикуемый» от «модель выдумала значение».
KNOWN_EVENT_TYPES = URGENT_ELIGIBLE_TYPES | frozenset({
    "FX_RATE",
    "MACRO_ECONOMICS",
    "EXPERT_ANALYSIS",
    "MARKET_TREND",
    "OFF_TOPIC",
    "NONE",
})

# Структурный мусор: формально это новости ЦБ или деловых лент, но в
# заголовке нет события — только реквизиты документа или сводка за день.
# Примеры из выборки: «Указание Банка России от 22.06.2026 № 7373-У»,
# «Вестник Банка России № 24 (2613) от 29 июля 2026 года», «Что произошло за
# день: четверг, 23 июля».
_NON_EVENT_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    # Голая ссылка на реквизиты НПА. Содержательный заголовок про то же
    # указание описывал бы суть («ЦБ ограничил …»), а не начинался с формы
    # документа, поэтому якоримся на начало строки.
    (re.compile(r"^\s*(указание|положение|информационное\s+письмо|инструкция)\s+"
                r"банка\s+россии\b.*№", re.IGNORECASE), "cbr_document_citation"),
    (re.compile(r"вестник\s+банка\s+россии", re.IGNORECASE), "cbr_bulletin"),
    (re.compile(r"проект\w*\s+нормативн\w+\s+(документ\w*|акт\w*)", re.IGNORECASE),
     "draft_regulation_index"),
    (re.compile(r"^\s*что\s+произошло\s+за\s+день", re.IGNORECASE), "daily_roundup"),
    (re.compile(r"\bдайджест\b", re.IGNORECASE), "roundup_digest"),
    (re.compile(r"^\s*(главное|итоги)\s+(за|дня|недели)\b", re.IGNORECASE), "roundup_digest"),
]

# Движения валютного курса. Отдельная проверка нужна даже при отсутствии
# FX_RATE в белом списке: в исходном замере курс доллара приезжал в канал под
# типом RATE_CHANGE, то есть ошибка классификатора здесь системная.
_FX_NOISE_PATTERN = re.compile(
    r"курс\w*\s+(доллар\w*|евро|юан\w*|валют\w*|рубл\w*)"
    r"|официальн\w+\s+курс"
    r"|(доллар|евро|юань)\w*\s+(выше|ниже|дороже|дешевле|до)\s+\d",
    re.IGNORECASE,
)


# Фондовый рынок. Как и с курсом валют, проверка нужна отдельно от белого
# списка: в бэктесте «Рынок акций РФ завершил неделю ростом» приехал под
# типом KEY_RATE, то есть модель тянет биржевые сюжеты в ставку.
_EQUITY_NOISE_PATTERN = re.compile(
    r"рын\w+\s+акци\w+"
    r"|индекс\w*\s+(мосбирж\w+|ртс|мб)"
    r"|котировк\w+"
    r"|дивиденд\w+"
    r"|\bакци\w+\s+(компан\w+|выросл\w+|упал\w+)",
    re.IGNORECASE,
)


def is_equity_noise(headline: str) -> bool:
    """True, если заголовок про фондовый рынок, а не про недвижимость."""
    if not headline:
        return False
    return bool(_EQUITY_NOISE_PATTERN.search(headline))


def is_non_event(headline: str) -> str | None:
    """Вернуть код причины, если заголовок — не событие, иначе None."""
    if not headline:
        return None
    for pattern, reason in _NON_EVENT_PATTERNS:
        if pattern.search(headline):
            return reason
    return None


def is_fx_noise(headline: str) -> bool:
    """True, если заголовок про движение валютного курса."""
    if not headline:
        return False
    return bool(_FX_NOISE_PATTERN.search(headline))


def gate_urgent(event_type: str, headline: str) -> tuple[bool, str]:
    """Решить, имеет ли событие право уйти в канал как URGENT.

    Возвращает (passes, reason). reason — машиночитаемый код, он пишется в
    urgent_pipeline.log, чтобы потом было видно, что именно резал гейт.
    """
    headline = (headline or "").strip()
    if not headline:
        return False, "empty_headline"

    normalized = (event_type or "").strip().upper()
    if normalized not in KNOWN_EVENT_TYPES:
        return False, "unknown_event_type"
    if normalized not in URGENT_ELIGIBLE_TYPES:
        return False, f"ineligible_type:{normalized}"

    if is_fx_noise(headline):
        return False, "fx_rate_noise"

    if is_equity_noise(headline):
        return False, "equity_market_noise"

    non_event = is_non_event(headline)
    if non_event:
        return False, f"non_event:{non_event}"

    return True, "ok"
