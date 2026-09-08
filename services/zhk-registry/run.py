"""Точка входа крона: обнаружение → обогащение → отправка → сводка.

Три гарантии, ради которых это отдельный модуль, а не однострочный вызов
адаптеров:

1. **Изоляция на уровне источника.** Упавший источник целиком (недоступен
   `discover()`, отправка не восстановилась даже после ретраев) не должен
   мешать обходу остальных — если ляжет ЕРЗ, «Единство» обязано пройти
   как обычно. Дохлая ссылка ВНУТРИ одного источника изолирована ещё
   раньше, на уровне самого адаптера (`enrich()` ловит и сетевые ошибки,
   и неразборчивую вёрстку, возвращает `None`), и `run_source` добавляет
   к этому ещё один пояс на непредвиденные исключения из `enrich()`.
2. **Ретрай транзиентных сбоев отправки.** HTTP 5xx от вебхука (например
   не выставленный при деплое `ZHK_INGEST_TOKEN` — конфигурационный сбой
   сервера, а не отказ навсегда, см. докстринг `client.IngestClient`) и
   сетевые обрывы стоит повторить; HTTP 4xx (кроме 5xx) — нет: это либо
   вина текущего запроса, либо `invalid`-решение, которое уже принято на
   уровне отдельного наблюдения внутри самого вебхука и сюда долетать не
   должно вовсе.
3. **Сводка отправляется после обхода ВСЕХ источников**, независимо от
   того, сколько из них упало целиком — молчащий источник и есть тот
   случай, ради которого сводка вообще существует (см.
   `app/services/zhk/run_summary.rb`), и прятать его из-за собственного
   падения было бы противоположностью цели.
"""

from __future__ import annotations

import logging
import os
import time

import requests
from dotenv import load_dotenv

from client import IngestClient
from observation import Observation
from sources.edinstvo import EdinstvoSource
from sources.erz import ErzSource

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("zhk-registry")

# Сколько раз повторить отправку батча источника при транзиентном сбое,
# прежде чем сдаться и посчитать источник упавшим в этом прогоне.
MAX_SEND_RETRIES = 2
RETRY_DELAY_SECONDS = 30

# Сетевые исключения `requests`, которые считаем транзиентными: запрос не
# дошёл до сервера вовсе (обрыв, таймаут), а не сервер ответил отказом.
TRANSIENT_NETWORK_ERRORS = (requests.ConnectionError, requests.Timeout)


def is_transient(exc: Exception) -> bool:
    """Стоит ли повторить запрос, приведший к `exc`.

    HTTP 5xx — да (сервер поломан временно/по конфигурации, см. докстринг
    модуля). Любой другой `HTTPError` (4xx) — нет: 401/403 — протухший
    токен, 422 — батч не по контракту или длиннее лимита, оба на стороне
    ЭТОГО запроса и оба не самоисправятся простым повтором. `invalid` для
    отдельного наблюдения внутри батча — не исключение вовсе (см.
    `IngestClient._post`, там только `log.warning`), поэтому здесь для
    него нет и не может быть отдельной ветки: до `is_transient` такие
    наблюдения не долетают, отправка в целом остаётся успешной.
    """
    if isinstance(exc, TRANSIENT_NETWORK_ERRORS):
        return True
    if isinstance(exc, requests.HTTPError):
        status = exc.response.status_code if exc.response is not None else None
        return status is not None and 500 <= status < 600
    return False


def send_with_retry(client: IngestClient, observations: list[Observation], source_name: str) -> list[dict]:
    """Отправляет наблюдения источника, повторяя ВЕСЬ список при
    транзиентном сбое — не только не отправленный хвост.

    Так решается сразу два смежных вопроса задачи:

    - **транзиентный сбой** (сеть моргнула, сервер временно отвечает
      5xx) — очевидная причина ретраить;
    - **потеря частичного результата**, задокументированная в докстринге
      `IngestClient.send`: если исключение прилетает на чанке N > 1,
      результаты уже отправленных чанков 1..N-1 были применены на
      сервере, но вызывающий код (мы) их не увидит — до `return` дело не
      доходит. Переотправка ВСЕГО списка достаёт эти данные дешевле, чем
      переписывание `IngestClient`, чтобы он отдавал частичный результат
      наружу: чанк 1 на повторной попытке получит `duplicate` (не
      `created` второй раз — `Zhk::Ingest` идемпотентен, вреда нет), а
      чанки 2 и далее на этот раз дойдут до конца. Одного цикла ретрая
      достаточно, чтобы после успешной попытки `len(observations)`
      снова стало точным числом, а не нижней границей.

    Если транзиентные сбои повторяются и после `MAX_SEND_RETRIES`
    попыток — сдаёмся и поднимаем исключение дальше: `run_source`/
    `crawl` посчитают источник упавшим целиком в этом прогоне (count=0,
    нижняя граница — часть чанков могла успеть примениться на сервере
    раньше, но узнать точное число здесь уже неоткуда). Это единственный
    случай в данной задаче, где число, ушедшее в сводку, не гарантированно
    точное — задокументировано осознанно, а не как недосмотр.
    """
    attempt = 0
    while True:
        try:
            return client.send(observations)
        except Exception as exc:
            if attempt >= MAX_SEND_RETRIES or not is_transient(exc):
                raise
            attempt += 1
            log.warning(
                "%s: транзиентный сбой отправки (%s), попытка %d/%d через %ss",
                source_name, exc, attempt, MAX_SEND_RETRIES, RETRY_DELAY_SECONDS,
            )
            time.sleep(RETRY_DELAY_SECONDS)


def run_source(source, client: IngestClient) -> int:
    """Обходит один источник целиком, возвращает число отправленных
    наблюдений.

    Любое исключение из `source.discover()` или из `send_with_retry`
    (после исчерпания ретраев) НЕ ловится здесь — источник упал целиком,
    и решение «не мешать обходу остальных» принимает вызывающая сторона
    (`crawl`), а не эта функция: `run_source` описывает обход одного
    источника, а не политику изоляции между источниками.
    """
    refs = source.discover()

    observations: list[Observation] = []
    for ref in refs:
        try:
            obs = source.enrich(ref)
        except Exception:
            # Штатный адаптер сам ловит сетевые ошибки и неразборчивую
            # вёрстку внутри enrich() (см. sources/erz.py, edinstvo.py) —
            # это дополнительный пояс на непредвиденное исключение,
            # чтобы одна дохлая карточка не стоила остальных, уже
            # найденных на этом же источнике (урок 2 задачи).
            log.exception("%s: карточка не разобралась %s", source.name, ref.get("url"))
            continue
        if obs is not None:
            observations.append(obs)

    if not observations:
        # Пустой список слать незачем — вебхук трактует его как законный
        # (пустой отчёт), но лишний HTTP-запрос ради этого не нужен.
        return 0

    send_with_retry(client, observations, source.name)
    return len(observations)


def crawl(sources: list, client: IngestClient) -> dict[str, int]:
    """Обходит все источники по очереди, изолируя падение каждого от
    остальных. Возвращает `{имя источника: число отправленных наблюдений}`
    — этот словарь и есть `counts` для `POST /webhooks/zhk_ingest/summary`.
    """
    counts: dict[str, int] = {}
    for source in sources:
        try:
            counts[source.name] = run_source(source, client)
            log.info("%s: отправлено %d", source.name, counts[source.name])
        except Exception:
            log.exception("источник упал целиком: %s", source.name)
            counts[source.name] = 0
    return counts


def post_summary(base_url: str, token: str, counts: dict[str, int]) -> None:
    """Сводка — уведомление, а не источник истины: все наблюдения этого
    прогона уже применены (или не применены — и это тоже уже
    зафиксировано в `counts`) предыдущими вызовами `/webhooks/zhk_ingest`.
    Сбой самой отправки сводки (сеть, вебхук временно недоступен)
    логируется и не поднимается наружу — падать здесь уже не на чем
    экономить: обход всех источников закончен, работать дальше нечему.
    """
    try:
        response = requests.post(
            f"{base_url.rstrip('/')}/webhooks/zhk_ingest/summary",
            json={"counts": counts},
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )
        response.raise_for_status()
    except requests.RequestException:
        log.exception("не удалось отправить сводку прогона: %s", counts)


def main() -> None:
    base_url = os.environ["VICTORY_BASE_URL"]
    token = os.environ["ZHK_INGEST_TOKEN"]
    contact = os.environ.get("CRAWLER_CONTACT", "info@victory62.org")

    session = requests.Session()
    sources = [ErzSource(session, contact), EdinstvoSource(session, contact)]
    client = IngestClient(base_url, token)

    counts = crawl(sources, client)
    post_summary(base_url, token, counts)


if __name__ == "__main__":
    main()
