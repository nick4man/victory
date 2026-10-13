"""Еженедельный автопробер бесплатных LLM-моделей (13.10.26).

Проверяет кандидатов из probe_candidates.json и живость бесплатных звеньев
текущего chains.json, обновляя цепочки без ручной возни: у провайдеров
бесплатные лимиты плавают неделя к неделе (см. историю «Removed from chain»
в pipeline_utils.py), и выяснять это боевым прогоном — значит жечь таймауты
каждого запуска коллектора.

Что делает:
  - классификатор: 2 эталонных кейса (ставка ЦБ → URGENT/KEY_RATE, спорт →
    NOISE) реальным промптом из urgent_collector.py;
  - генерация (role=both): короткий срочный пост по мини-фактуре с эвристиками
    брака — латиница в русском тексте, выдуманные цифры, длина (мотивы:
    nemotron мешал русский с английским, laguna выдумывала цифры);
  - state: $CONVEYOR_HOME/state/probe_state.json — 3 подряд провала → disabled,
    2 подряд успеха → enabled;
  - chains.json: добавляет прошедших (только с пометкой added_by="probe"),
    удаляет только свои probe-записи; платные и ручные не трогает никогда.

Денег не тратит: платные записи chains.json пропускает, платный флаг новым
записям не ставит.

Запуск:
    python3 free_model_probe.py                    # полный прогон
    python3 free_model_probe.py --dry-run          # решения в stdout, ничего не пишет
    python3 free_model_probe.py --only openrouter/z-ai/glm-4.5-air:free
    python3 free_model_probe.py --limit 3
"""

from __future__ import annotations

import argparse
import ast
import json
import logging
import os
import re
import sys
import time
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from pipeline_utils import (  # noqa: E402
    _load_chains_config,
    complete_with_fallbacks,
    conveyor_home,
    resolve_chains_json_path,
    resolve_chains_json_write_path,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# --- Пороги (13.10.26) ---
# 3 подряд провала → модель исключается из chains.json; 2 подряд успеха
# возвращают disabled-модель. Не 1 успех: единичный проход сквозь rate-limit
# ещё не значит, что модель ожила.
FAIL_DISABLE_THRESHOLD = 3
SUCCESS_ENABLE_THRESHOLD = 2

# Эвристики брака генерации. Латиницы больше 15% слов — модель мешает языки
# (как nemotron с «unanimously»). Длина поста — в рамках боевого лимита
# Telegram ≤1700 (urgent_trigger.py), с нижней границей от пустых/однострочных
# ответов.
LATIN_RATIO_THRESHOLD = 0.15
POST_MIN_LEN = 100
POST_MAX_LEN = 1700

DEFAULT_DEADLINE_S = 900  # 15 минут wall-clock на весь прогон


# --- Пути (env читаем В МОМЕНТ ВЫЗОВА — .env подтягивается после импортов) ---

def probe_state_path() -> str:
    return os.environ.get(
        "PROBE_STATE_PATH", os.path.join(conveyor_home(), "state", "probe_state.json")
    )


def probe_report_path() -> str:
    return os.path.join(os.path.dirname(probe_state_path()), "probe_report.json")


def candidates_path() -> str:
    return os.environ.get(
        "PROBE_CANDIDATES_PATH", os.path.join(SCRIPT_DIR, "probe_candidates.json")
    )


# --- Эталонные кейсы классификатора ---
# Реальные формулировки из боевой ленты (адаптация фикстур бэктеста).
# Ожидаем строго URGENT/KEY_RATE и NOISE — это те две границы, на которых
# классификатор ломался чаще всего.
CLASSIFIER_CASES = [
    {
        "name": "key_rate",
        "headline": "Банк России снизил ключевую ставку до 14,5% годовых",
        "summary": (
            "Совет директоров Банка России на заседании принял решение снизить "
            "ключевую ставку с 16% до 14,5% годовых. Решение вступает в силу "
            "с понедельника. Регулятор отметил устойчивое замедление инфляции."
        ),
        "expected_tier": "URGENT",
        "expected_type": "KEY_RATE",
    },
    {
        "name": "sport",
        "headline": "«Спартак» обыграл «Зенит» в дерби и вышел на второе место",
        "summary": (
            "Московский «Спартак» на домашнем стадионе победил петербургский "
            "«Зенит» со счётом 2:1 в матче чемпионата России по футболу. "
            "Победный гол забил на 89-й минуте."
        ),
        "expected_tier": "NOISE",
        "expected_type": None,  # у NOISE тип не фиксируем — хватит вердикта
    },
]

# Мини-фактура для проверки генерации: цифры намеренно «неудобные»
# (14,5 с запятой, 12,1) — laguna-style модели любят приплести свои.
GENERATION_FACTS = (
    "Банк России на заседании 9 октября 2026 года снизил ключевую ставку "
    "с 16% до 14,5% годовых. Это третье снижение подряд. Средняя ставка "
    "по рыночной ипотеке на новостройки составила 12,1%."
)

GENERATION_PROMPT = """Ты — экспертный SMM-редактор АН «Виктори» (премиум-недвижимость, РФ).
По фактуре ниже напиши короткий срочный пост для Telegram-канала на русском языке.

Требования:
- только русский язык, никаких английских слов;
- только факты и цифры из фактуры, ничего не выдумывать;
- 3–6 предложений, без заголовков и списков;
- форматирование Telegram HTML: допустимы только <b> и <i>.

Фактура: {facts}

Верни строго JSON-объект без пояснений:
{{"body_html": "<текст поста>"}}"""


# Короткий запасной промпт на случай, если извлечь боевой из
# urgent_collector.py не выйдет (файл переименуют и т.п.). Проверка всё равно
# останется содержательной: JSON-вердикт по той же таксономии.
_FALLBACK_CLASSIFIER_PROMPT = """Ты — фильтр новостей для бренда «Виктори» (премиум-недвижимость РФ).
Распредели новость по ведрам: URGENT (немедленная публикация: решение ЦБ по
ключевой ставке, законы о недвижимости/капитале — только свершившийся факт),
DIGEST (аналитика), ARCHIVE (осмысленное off-topic), NOISE (спорт, реклама,
погода, криминал).

Заголовок: {headline}
Краткое содержание: {summary}

Верни строго JSON-объект без пояснений:
{{"relevance_tier": "URGENT|DIGEST|ARCHIVE|NOISE", "event_type": "KEY_RATE|NONE",
  "audience_fit": "PREMIUM|MASS|UNKNOWN", "reasoning": "<1 предложение>"}}"""


def load_classifier_prompt() -> str:
    """Достать CLASSIFIER_PROMPT из urgent_collector.py, НЕ импортируя модуль:
    он тянет psycopg2/feedparser/pydantic, которых в окружении пробера может
    не быть (да и не нужны). Разбираем исходник через ast и берём константу.
    Так пробер гоняет ровно боевой промпт и не расходится с ним при правках.
    """
    path = os.path.join(SCRIPT_DIR, "urgent_collector.py")
    try:
        with open(path, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if not isinstance(node, ast.Assign):
                continue
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "CLASSIFIER_PROMPT":
                    return ast.literal_eval(node.value)
        logger.warning("[probe] CLASSIFIER_PROMPT не найден в %s — запасной промпт", path)
    except Exception as e:
        logger.warning("[probe] не могу извлечь промпт из %s: %s — запасной", path, e)
    return _FALLBACK_CLASSIFIER_PROMPT


def _parse_classifier_json(raw: str) -> dict:
    """Клон parse_fn из urgent_collector.py (_parse_classifier_json).
    Держим свою копию по той же причине, что и промпт: без импорта модуля."""
    raw = raw.strip()
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw, flags=re.IGNORECASE)
    if not raw.startswith("{"):
        m = re.search(r"\{.*\}", raw, flags=re.DOTALL)
        if m:
            raw = m.group(0)
    data = json.loads(raw)
    if "relevance_tier" not in data:
        raise ValueError("missing relevance_tier in JSON")
    return data


# ============================================================================
# Чистая логика (без сети) — то, что покрыто test_free_model_probe.py
# ============================================================================

_HTML_TAG_RE = re.compile(r"<[^>]+>")
_WORD_RE = re.compile(r"[A-Za-zА-Яа-яЁё]+")
_LATIN_WORD_RE = re.compile(r"^[A-Za-z]+$")
_NUM_RE = re.compile(r"\d+(?:[.,]\d+)?%?")
_HASHTAG_RE = re.compile(r"#[\wА-Яа-яЁё]+")
# Числа, которые разумно встретить в посте, даже если их нет в фактуре:
# дни месяца (целые 1–31 без «%») и годы 19xx/20xx — даты модель имеет право
# сформулировать сама. Проценты так не освобождаем: «инфляция 4,3%» — это
# именно laguna-style выдумка, ради которой проверка и существует (13.09.26).
_DATE_LIKE_MIN, _DATE_LIKE_MAX = 1, 31


def _strip_html(text: str) -> str:
    return _HTML_TAG_RE.sub(" ", text)


def latin_word_ratio(text: str) -> float:
    """Доля латинских слов среди всех слов текста (HTML уже снят)."""
    words = _WORD_RE.findall(text)
    if not words:
        return 0.0
    latin = sum(1 for w in words if _LATIN_WORD_RE.match(w))
    return latin / len(words)


def _numbers_of(text: str) -> set[float]:
    """Числа текста как float-множество; '14,5' и '14.5' — одно число."""
    out = set()
    for token in _NUM_RE.findall(text):
        try:
            out.add(float(token.rstrip("%").replace(",", ".")))
        except ValueError:
            continue
    return out


def _post_numbers(text: str) -> set[float]:
    """Числа поста, подозрительные на выдумку: без хэштегов, дат и годов."""
    candidates = []
    for token in _NUM_RE.findall(_HASHTAG_RE.sub(" ", text)):
        is_percent = token.endswith("%")
        try:
            value = float(token.rstrip("%").replace(",", "."))
        except ValueError:
            continue
        if not is_percent:
            if value == int(value) and _DATE_LIKE_MIN <= value <= _DATE_LIKE_MAX:
                continue
            if 1900 <= value <= 2100:
                continue
        candidates.append(value)
    return set(candidates)


def generation_defects(post_html: str, facts: str) -> list[str]:
    """Эвристики брака срочного поста. Пустой список = пост годный.

    Три проверки по мотивам реальных отказов (комментарий 13.09.26 в
    pipeline_utils.py): латиница в русском тексте (nemotron), выдуманные
    цифры (laguna), неразумная длина. Числа из хэштегов и датоподобные
    (1–31, годы 19xx/20xx) не считаются выдумкой.
    """
    defects: list[str] = []
    text = _strip_html(post_html).strip()

    if not (POST_MIN_LEN <= len(text) <= POST_MAX_LEN):
        defects.append(f"length_out_of_bounds:{len(text)}")

    ratio = latin_word_ratio(text)
    if ratio > LATIN_RATIO_THRESHOLD:
        defects.append(f"latin_mix:{ratio:.0%}")

    # Хэштеги, даты и годы вырезаем до сравнения: #ипотека2026 и «20 ноября» —
    # не выдуманные цифры.
    invented = sorted(_post_numbers(text) - _numbers_of(facts))
    if invented:
        shown = ", ".join(f"{n:g}" for n in invented[:5])
        defects.append(f"hallucinated_numbers:{shown}")
    return defects


def classify_error(err_str: str) -> str:
    """Текст исключения → короткая категория для отчёта и state."""
    s = err_str.lower()
    if "429" in s or "rate limit" in s or "rate_limit" in s or "too many" in s:
        return "rate_limit"
    if "timeout" in s or "timed out" in s or "deadline" in s:
        return "timeout"
    if "ssl" in s or "tls" in s or "connection" in s or "connect" in s:
        return "connection"
    if "json" in s or "relevance_tier" in s or "expecting value" in s:
        return "bad_json"
    return "other"


def fresh_model_state() -> dict:
    return {"consecutive_failures": 0, "consecutive_successes": 0, "disabled": False}


def apply_probe_result(entry: dict | None, success: bool) -> dict:
    """Переход state одной модели по итогу прогона.

    3 подряд провала → disabled (выбывает из chains.json, если там есть
    probe-запись); 2 подряд успеха → disabled снимается (модель возвращается).
    Любой успех обнуляет счётчик провалов и наоборот.
    """
    e = fresh_model_state()
    if entry:
        e.update({k: entry.get(k, e[k]) for k in e})
    if success:
        e["consecutive_successes"] += 1
        e["consecutive_failures"] = 0
        if e["consecutive_successes"] >= SUCCESS_ENABLE_THRESHOLD:
            e["disabled"] = False
    else:
        e["consecutive_failures"] += 1
        e["consecutive_successes"] = 0
        if e["consecutive_failures"] >= FAIL_DISABLE_THRESHOLD:
            e["disabled"] = True
    return e


def model_key(provider: str, model: str) -> str:
    return f"{provider}/{model}"


def update_chains_config(
    raw: dict,
    add_classifier: list[tuple[str, str, int]],
    add_main: list[tuple[str, str, int]],
    disabled_keys: set[str],
) -> tuple[dict, list[str]]:
    """Применить решения пробера к распарсенному chains.json.

    Правила (13.10.26):
      - удаляются ТОЛЬКО записи с added_by="probe" по моделям, ушедшим в
        disabled; платные и ручные (без added_by или "manual") — никогда;
      - прошедший классификатор-кандидат → classifier_extra;
      - both-кандидат, прошедший обе проверки, → main СТРОГО перед первым
        paid-звеном: после платного бесплатное звено мёртвое, а платный
        флаг ему не положен;
      - все добавленные записи получают added_by="probe".

    Возвращает (новый raw, список человекочитаемых изменений).
    """
    new_raw = dict(raw)
    changes: list[str] = []

    for section in ("main", "classifier_extra"):
        kept = []
        for item in raw.get(section) or []:
            if (isinstance(item, dict)
                    and item.get("added_by") == "probe"
                    and not item.get("paid")
                    and model_key(item.get("provider", ""), item.get("model", "")) in disabled_keys):
                changes.append(
                    f"- {section}: убрана {item['provider']}/{item['model']} (disabled)"
                )
                continue
            kept.append(item)
        new_raw[section] = kept

    extra = new_raw["classifier_extra"]
    have_extra = {
        model_key(i.get("provider", ""), i.get("model", ""))
        for i in extra if isinstance(i, dict)
    }
    for provider, model, timeout_s in add_classifier:
        key = model_key(provider, model)
        if key in have_extra or key in disabled_keys:
            continue
        extra.append({
            "provider": provider, "model": model,
            "timeout_s": timeout_s, "added_by": "probe",
        })
        have_extra.add(key)
        changes.append(f"+ classifier_extra: {key}")

    main = new_raw["main"]
    have_main = {
        model_key(i.get("provider", ""), i.get("model", ""))
        for i in main if isinstance(i, dict)
    }
    for provider, model, timeout_s in add_main:
        key = model_key(provider, model)
        if key in have_main or key in disabled_keys:
            continue
        entry = {
            "provider": provider, "model": model,
            "timeout_s": timeout_s, "added_by": "probe",
        }
        first_paid = next(
            (i for i, it in enumerate(main)
             if isinstance(it, dict) and it.get("paid")),
            len(main),
        )
        main.insert(first_paid, entry)
        have_main.add(key)
        changes.append(f"+ main (перед платным хвостом): {key}")

    return new_raw, changes


def read_json_file(path: str) -> dict | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except FileNotFoundError:
        return None
    except Exception as e:
        logger.warning("[probe] не могу прочитать %s: %s", path, e)
        return None


def write_json_atomic(path: str, data: dict) -> None:
    """tmp-файл + rename, как _write_paid_budget в pipeline_utils: параллельный
    читатель (боевой прогон коллектора) не должен увидеть половину JSON."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


# ============================================================================
# Сетевая часть
# ============================================================================

def probe_classifier(provider: str, model: str, timeout_s: int,
                     prompt_template: str) -> dict:
    """Два эталонных кейса боевым промптом. ok = оба вердикта верные."""
    errors: list[str] = []
    latencies: list[float] = []
    for case in CLASSIFIER_CASES:
        prompt = prompt_template.format(
            headline=case["headline"],
            summary=case["summary"],
            source_name="Новости ЦБ РФ",
            source_weight="high",
        )
        t0 = time.monotonic()
        try:
            _, raw = complete_with_fallbacks(
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
                max_tokens=400,
                parse_fn=_parse_classifier_json,
                chain=[(provider, model, timeout_s)],
                # Однозвенная цепочка: общий дедлайн чуть шире таймаута звена,
                # чтобы не резать попытку посреди ответа.
                overall_deadline_s=timeout_s + 10,
            )
            data = _parse_classifier_json(raw)
        except Exception as e:
            errors.append(f"{case['name']}:{classify_error(str(e))}")
            continue
        latencies.append(round(time.monotonic() - t0, 1))
        tier = (data.get("relevance_tier") or "").upper()
        etype = (data.get("event_type") or "").upper()
        if tier != case["expected_tier"]:
            errors.append(f"{case['name']}:вердикт {tier} вместо {case['expected_tier']}")
        elif case["expected_type"] and etype != case["expected_type"]:
            errors.append(f"{case['name']}:тип {etype} вместо {case['expected_type']}")
    return {"ok": not errors, "errors": errors, "latency_s": latencies}


def probe_generation(provider: str, model: str, timeout_s: int) -> dict:
    """Короткий пост по мини-фактуре + эвристики брака."""
    prompt = GENERATION_PROMPT.format(facts=GENERATION_FACTS)
    t0 = time.monotonic()
    try:
        _, raw = complete_with_fallbacks(
            messages=[{"role": "user", "content": prompt}],
            temperature=0.3,
            max_tokens=900,
            chain=[(provider, model, timeout_s)],
            overall_deadline_s=timeout_s + 10,
        )
    except Exception as e:
        return {"ok": False, "errors": [f"gen:{classify_error(str(e))}"], "latency_s": []}
    latency = round(time.monotonic() - t0, 1)
    body = raw.strip()
    try:
        data = json.loads(re.sub(r"^```(?:json)?\s*|\s*```$", "", body).strip())
        if isinstance(data, dict) and isinstance(data.get("body_html"), str):
            body = data["body_html"]
    except Exception:
        # Не JSON — проверяем сам текст как пост: брак-эвристики сработают
        # и на нём; отдельно JSON не требуем, пост — не вердикт.
        pass
    defects = generation_defects(body, GENERATION_FACTS)
    return {
        "ok": not defects,
        "errors": [f"gen:{d}" for d in defects],
        "latency_s": [latency],
    }


def load_candidates() -> list[dict]:
    """Кандидаты из probe_candidates.json; битые записи пропускаем с warning."""
    data = read_json_file(candidates_path()) or {}
    out = []
    for i, item in enumerate(data.get("candidates") or []):
        if (not isinstance(item, dict)
                or not item.get("provider") or not item.get("model")
                or item.get("role") not in ("classifier", "both")):
            logger.warning("[probe] candidates: запись #%d невалидна — пропускаю", i)
            continue
        timeout_s = item.get("timeout_s", 30)
        if isinstance(timeout_s, bool) or not isinstance(timeout_s, int) or timeout_s <= 0:
            timeout_s = 30
        out.append({
            "provider": item["provider"], "model": item["model"],
            "timeout_s": timeout_s, "role": item["role"], "origin": "candidate",
        })
    return out


def current_free_links(chains_path: str) -> list[dict]:
    """Бесплатные звенья действующего chains.json — их пробер проверяет на
    живость. Платные пропускаем: деньги пробер не тратит ни на один вызов.
    main → проверка генерацией (их боевая работа), classifier_extra →
    классификатором."""
    cfg = _load_chains_config(chains_path)
    paid = cfg["paid"]
    links = []
    for provider, model, timeout_s in cfg["main"]:
        if (provider, model) in paid:
            continue
        links.append({"provider": provider, "model": model, "timeout_s": timeout_s,
                      "role": "both", "origin": "chains:main"})
    for provider, model, timeout_s in cfg["free_classifier"]:
        links.append({"provider": provider, "model": model, "timeout_s": timeout_s,
                      "role": "classifier", "origin": "chains:classifier"})
    return links


def merge_probe_list(candidates: list[dict], current: list[dict]) -> list[dict]:
    """Кандидаты + бесплатные звенья chains.json без дублей: если модель уже
    в цепочке, проверяем один раз, но с ролью из probe_candidates (она
    строже/точнее отражает, куда модель претендует)."""
    merged: dict[str, dict] = {}
    for item in candidates + current:
        key = model_key(item["provider"], item["model"])
        if key not in merged or item["origin"] == "candidate":
            merged[key] = item
    return list(merged.values())


# ============================================================================
# main
# ============================================================================

def _load_env(path: str) -> None:
    """Подтянуть .env рядом со скриптом (ключи провайдеров). setdefault:
    реальное окружение cron важнее файла. Своя реализация вместо dotenv —
    как в backtest_urgent_relevance.py: пробер должен работать и в
    минимальном окружении, где из зависимостей стоит только requests."""
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
    parser.add_argument("--dry-run", action="store_true",
                        help="печатать решения, ничего не писать (state/chains/report)")
    parser.add_argument("--only", metavar="PROVIDER/MODEL",
                        help="проверить одну модель")
    parser.add_argument("--limit", type=int, default=0,
                        help="не больше N моделей за прогон (0 — все)")
    parser.add_argument("--deadline-s", type=float, default=DEFAULT_DEADLINE_S,
                        help=f"общий wall-clock дедлайн, сек (по умолчанию {DEFAULT_DEADLINE_S})")
    args = parser.parse_args()

    _load_env(os.path.join(SCRIPT_DIR, ".env"))
    t_start = time.monotonic()
    chains_path = resolve_chains_json_path()
    # Читаем действующий конфиг, пишем — на постоянный том state/ (в docker
    # бандленный chains.json лежит в слое образа и стирается rollout'ом).
    chains_write_path = resolve_chains_json_write_path()
    logger.info("[probe] chains.json: читаю %s, пишу %s", chains_path, chains_write_path)

    probe_list = merge_probe_list(load_candidates(), current_free_links(chains_path))
    if args.only:
        probe_list = [m for m in probe_list
                      if model_key(m["provider"], m["model"]) == args.only]
        if not probe_list:
            print(f"модель {args.only} не найдена ни среди кандидатов, ни в chains.json")
            return 2
    if args.limit > 0:
        probe_list = probe_list[: args.limit]

    state = read_json_file(probe_state_path()) or {}
    models_state = state.setdefault("models", {})
    prompt_template = load_classifier_prompt()

    results: list[dict] = []
    deadline_hit = False
    for item in probe_list:
        if time.monotonic() - t_start > args.deadline_s:
            deadline_hit = True
            logger.warning("[probe] общий дедлайн %.0fs — останавливаюсь", args.deadline_s)
            break
        key = model_key(item["provider"], item["model"])
        logger.info("[probe] проверяю %s (%s, %s)", key, item["role"], item["origin"])

        cls_res = probe_classifier(item["provider"], item["model"],
                                   item["timeout_s"], prompt_template)
        gen_res = None
        if item["role"] == "both" and time.monotonic() - t_start <= args.deadline_s:
            gen_res = probe_generation(item["provider"], item["model"], item["timeout_s"])

        success = cls_res["ok"] and (gen_res is None or gen_res["ok"])
        entry = apply_probe_result(models_state.get(key), success)
        models_state[key] = entry
        results.append({
            "key": key, "role": item["role"], "origin": item["origin"],
            "timeout_s": item["timeout_s"],
            "classifier": cls_res, "generation": gen_res,
            "success": success,
            "state": entry,
        })
        logger.info("[probe] %s → %s (fails=%d succ=%d disabled=%s)",
                    key, "OK" if success else "FAIL",
                    entry["consecutive_failures"], entry["consecutive_successes"],
                    entry["disabled"])

    # Решения по chains.json.
    disabled_keys = {k for k, v in models_state.items() if v.get("disabled")}
    add_classifier = [
        (r["key"].split("/", 1)[0], r["key"].split("/", 1)[1], r["timeout_s"])
        for r in results
        if r["classifier"]["ok"] and not r["state"]["disabled"]
        # both-кандидату место в классификаторе тоже даём, если прошёл хотя бы
        # классификатор: вердикты он ставить умеет, даже если пост не вышел.
    ]
    add_main = [
        (r["key"].split("/", 1)[0], r["key"].split("/", 1)[1], r["timeout_s"])
        for r in results
        if r["role"] == "both" and r["classifier"]["ok"]
        and r["generation"] and r["generation"]["ok"]
        and not r["state"]["disabled"]
    ]

    raw_chains = read_json_file(chains_path)
    changes: list[str] = []
    new_chains = None
    if raw_chains is not None:
        new_chains, changes = update_chains_config(
            raw_chains, add_classifier, add_main, disabled_keys,
        )
    else:
        logger.warning("[probe] %s не читается — chains.json не обновляю", chains_path)

    # Отчёт в stdout.
    print(f"\n=== Автопробер бесплатных моделей · {datetime.now(timezone.utc):%d.%m.%y %H:%M} UTC"
          f"{' · DRY-RUN' if args.dry_run else ''} ===")
    print(f"{'Модель':50} {'Роль':11} {'Классиф.':14} {'Генерация':18} State")
    for r in results:
        cls = "ok" if r["classifier"]["ok"] else ",".join(r["classifier"]["errors"])[:12]
        if r["generation"] is None:
            gen = "—"
        else:
            gen = "ok" if r["generation"]["ok"] else ",".join(r["generation"]["errors"])[:16]
        st = r["state"]
        state_str = ("DISABLED" if st["disabled"]
                     else f"f{st['consecutive_failures']}/s{st['consecutive_successes']}")
        print(f"{r['key']:50} {r['role']:11} {cls:14} {gen:18} {state_str}")

    print("\n--- Решения по chains.json ---")
    if changes:
        for c in changes:
            print(f"  {c}")
    else:
        print("  без изменений")
    if deadline_hit:
        print(f"  !! прогон остановлен по дедлайну {args.deadline_s:.0f}s — часть моделей не проверена")

    if args.dry_run:
        print("\n(dry-run: state, chains.json и отчёт не записаны)")
        return 0

    state["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    try:
        write_json_atomic(probe_state_path(), state)
    except Exception as e:
        logger.error("[probe] не могу записать state %s: %s", probe_state_path(), e)

    if new_chains is not None and changes:
        try:
            write_json_atomic(chains_write_path, new_chains)
            logger.info("[probe] chains.json обновлён (%s): %d изменений",
                        chains_write_path, len(changes))
        except Exception as e:
            logger.error("[probe] не могу записать %s: %s", chains_write_path, e)

    report = {
        "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "dry_run": args.dry_run,
        "deadline_hit": deadline_hit,
        "chains_path": chains_path,
        "chains_write_path": chains_write_path,
        "changes": changes,
        "results": results,
    }
    try:
        write_json_atomic(probe_report_path(), report)
    except Exception as e:
        logger.error("[probe] не могу записать отчёт %s: %s", probe_report_path(), e)

    return 0


if __name__ == "__main__":
    sys.exit(main())
