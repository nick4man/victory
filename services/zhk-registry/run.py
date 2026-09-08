"""Точка входа крона: обнаружение → обогащение → отправка → сводка.

Четыре гарантии, ради которых это отдельный модуль, а не однострочный
вызов адаптеров:

1. **Изоляция на уровне источника.** Упавший источник целиком (недоступен
   `discover()`, отправка не восстановилась даже после ретраев) не должен
   мешать обходу остальных — если ляжет ЕРЗ, «Единство» обязано пройти
   как обычно. Дохлая ссылка ВНУТРИ одного источника изолирована ещё
   раньше, на уровне самого адаптера (`enrich()` ловит и сетевые ошибки,
   и неразборчивую вёрстку, возвращает `None`), и `run_source` добавляет
   к этому ещё один пояс на непредвиденные исключения из `enrich()`.

   Оговорка (найдена в круге правок 1, не устранена, а честно
   задокументирована): ретраится `discover()` целиком и отправка целиком
   — но НЕ отдельный `enrich()` одной карточки. Сетевой обрыв ровно на
   одной карточке молча уменьшит count на единицу — адаптер это глотает
   (см. `sources/erz.py`/`edinstvo.py`), и различить снаружи «карточка
   пропала транзиентно» от «карточка пропала навсегда» здесь неоткуда:
   исключение уже проглочено ВНУТРИ `enrich()`, наружу выходит только
   `None`. Ретрай на этом уровне потребовал бы либо менять контракт
   адаптеров (отдавать наружу тип ошибки вместо `None`), либо ретраить
   `enrich()` по URL заново — то и другое за пределами этой задачи.
   Влияние на детектор молчащего источника ограничено: один потерянный
   URL из десятков заметно не сдвигает count относительно предыдущего
   прогона (порог `SILENCE_RATIO` — 30%), поэтому единичный шум не
   вызывает ложную тревогу — но и не считается его пропуском.
2. **Ретрай транзиентных сбоев** — `discover()`, отправки батча и POST
   сводки. HTTP 5xx (например не выставленный при деплое
   `ZHK_INGEST_TOKEN` — конфигурационный сбой сервера, а не отказ
   навсегда, см. докстринг `client.IngestClient`) и сетевые обрывы стоит
   повторить; HTTP 4xx (кроме 5xx) — нет: это либо вина текущего запроса,
   либо `invalid`-решение, которое уже принято на уровне отдельного
   наблюдения внутри самого вебхука и сюда долетать не должно вовсе.
3. **Отвергнутые наблюдения (`status: invalid`) не считаются
   отправленными.** `run_source` вычитает их из count — иначе батч,
   который сервер отверг целиком (например после дрейфа контракта),
   уехал бы в сводку как полный успех (круг правок 1, находка ревью).
4. **Сводка отправляется после обхода ВСЕХ источников**, независимо от
   того, сколько из них упало целиком — молчащий источник и есть тот
   случай, ради которого сводка вообще существует (см.
   `app/services/zhk/run_summary.rb`), и прятать его из-за собственного
   падения было бы противоположностью цели. Если сама сводка не дошла
   (вебхук недоступен весь прогон, `TELEGRAM_STAFF_CHAT_ID` не настроен)
   — `main()` завершается ненулевым кодом, чтобы это заметил `MAILTO`
   крона: тревога о молчащем источнике едет тем же каналом (Telegram),
   который в этом случае и не работает, и без внешнего сигнала утрату
   недели данных не заметит никто (круг правок 1, находка ревью).
"""

from __future__ import annotations

import logging
import os
import time
from typing import Callable, TypeVar

import requests
from dotenv import load_dotenv

from client import IngestClient
from observation import Observation
from sources.edinstvo import EdinstvoSource
from sources.erz import ErzSource

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("zhk-registry")

# Сколько раз повторить операцию (обнаружение, отправка, сводка) при
# транзиентном сбое, прежде чем сдаться.
MAX_RETRIES = 2
RETRY_DELAY_SECONDS = 30

# Сетевые исключения `requests`, которые считаем транзиентными: запрос не
# дошёл до сервера вовсе (обрыв, таймаут), а не сервер ответил отказом.
TRANSIENT_NETWORK_ERRORS = (requests.ConnectionError, requests.Timeout)

T = TypeVar("T")


def is_transient(exc: Exception) -> bool:
    """Стоит ли повторить запрос, приведший к `exc`.

    HTTP 5xx — да (сервер поломан временно/по конфигурации, см. докстринг
    модуля). Любой другой `HTTPError` (4xx) — нет: 401/403 — протухший
    токен, 422 — батч не по контракту или длиннее лимита, оба на стороне
    ЭТОГО запроса и оба не самоисправятся простым повтором. `invalid` для
    отдельного наблюдения внутри батча — не исключение вовсе (см.
    `IngestClient._post`, там только `log.warning`), поэтому здесь для
    него нет и не может быть отдельной ветки: до `is_transient` такие
    наблюдения не долетают, отправка в целом остаётся успешной (их
    вычитает `run_source`, см. докстринг модуля, пункт 3).
    """
    if isinstance(exc, TRANSIENT_NETWORK_ERRORS):
        return True
    if isinstance(exc, requests.HTTPError):
        status = exc.response.status_code if exc.response is not None else None
        return status is not None and 500 <= status < 600
    return False


def call_with_retry(fn: Callable[[], T], description: str) -> T:
    """Общий ретрай-цикл для `discover()`, отправки батча и POST сводки —
    один и тот же критерий транзиентности (`is_transient`) и один и тот
    же бюджет попыток (`MAX_RETRIES`) для всех трёх, чтобы политика
    ретрая не разъезжалась по местам применения.
    """
    attempt = 0
    while True:
        try:
            return fn()
        except Exception as exc:
            if attempt >= MAX_RETRIES or not is_transient(exc):
                raise
            attempt += 1
            log.warning(
                "%s: транзиентный сбой (%s), попытка %d/%d через %ss",
                description, exc, attempt, MAX_RETRIES, RETRY_DELAY_SECONDS,
            )
            time.sleep(RETRY_DELAY_SECONDS)


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
      чанки 2 и далее на этот раз дойдут до конца.

    Если транзиентные сбои повторяются и после `MAX_RETRIES` попыток —
    сдаёмся и поднимаем исключение дальше: `run_source`/`crawl` посчитают
    источник упавшим целиком в этом прогоне (count=0, нижняя граница —
    часть чанков могла успеть примениться на сервере раньше, но узнать
    точное число здесь уже неоткуда).
    """
    return call_with_retry(lambda: client.send(observations), f"{source_name}: отправка")


def run_source(source, client: IngestClient, dry_run: bool = False) -> int:
    """Обходит один источник целиком, возвращает число ПРИМЕНЁННЫХ
    наблюдений — то есть тех, кого сервер НЕ отверг как `invalid`.

    `len(observations)` (сколько нашли и попытались отправить) — не то
    же самое, что число реально принятых: если контракт наблюдения
    разошёлся с ожиданиями сервера (например источник стал отдавать
    поле, которое `Zhk::Ingest` не узнаёт), сервер вправе отклонить
    каждый элемент батча как `invalid`, оставаясь в HTTP 200. Раньше
    `run_source` считал такой батч полным успехом — count == len(sent) —
    и сводка рапортовала бы «отправлено 50» при нуле реально применённых
    (круг правок 1, находка ревью).

    `dry_run=True` (см. `DRY_RUN` в `main()`) — первая проверка селекторов
    адаптера на ЖИВОЙ вёрстке источника, вне тестовых фикстур: находим и
    разбираем наблюдения как обычно, но вместо реальной отправки просто
    логируем их и возвращаем `len(observations)` как «нашли», а не
    «применили» (сервер вообще не участвует в этом прогоне) — число носит
    информационный характер, сравнивать его со сводкой боевого прогона
    нельзя.

    Любое исключение из `call_with_retry(source.discover, ...)` или из
    `send_with_retry` (после исчерпания ретраев) НЕ ловится здесь —
    источник упал целиком, и решение «не мешать обходу остальных»
    принимает вызывающая сторона (`crawl`), а не эта функция.
    """
    refs = call_with_retry(source.discover, f"{source.name}: discover")

    observations: list[Observation] = []
    for ref in refs:
        try:
            obs = source.enrich(ref)
        except Exception:
            # Штатный адаптер сам ловит сетевые ошибки и неразборчивую
            # вёрстку внутри enrich() (см. sources/erz.py, edinstvo.py) —
            # это дополнительный пояс на непредвиденное исключение,
            # чтобы одна дохлая карточка не стоила остальных, уже
            # найденных на этом же источнике (урок 2 задачи). Сетевой
            # обрыв внутри самого enrich() здесь НЕ ретраится — см.
            # оговорку в докстринге модуля, пункт 1.
            log.exception("%s: карточка не разобралась %s", source.name, ref.get("url"))
            continue
        if obs is not None:
            observations.append(obs)

    if not observations:
        # Пустой список слать незачем — вебхук трактует его как законный
        # (пустой отчёт), но лишний HTTP-запрос ради этого не нужен.
        return 0

    if dry_run:
        for obs in observations:
            # Имя и город — не украшение строки: DRY_RUN это
            # предпусковая проверка селекторов, и единственный её
            # вопрос — КАКИЕ карточки заведутся. `external_id` и
            # `fields` на него не отвечают: по «edinstvo:83» не
            # видно ни что это за ЖК, ни в том ли он городе.
            log.info(
                "DRY_RUN %s | %s (%s) — %s",
                obs.external_id, obs.name, obs.city, obs.to_payload()["fields"],
            )
        return len(observations)

    results = send_with_retry(client, observations, source.name)
    applied = sum(1 for row in results if row.get("status") != "invalid")
    if applied != len(observations):
        log.warning(
            "%s: сервер отверг %d из %d наблюдений как invalid",
            source.name, len(observations) - applied, len(observations),
        )
    return applied


def crawl(sources: list, client: IngestClient, dry_run: bool = False) -> dict[str, int]:
    """Обходит все источники по очереди, изолируя падение каждого от
    остальных. Возвращает `{имя источника: число применённых наблюдений}`
    — этот словарь и есть `counts` для `POST /webhooks/zhk_ingest/summary`
    (при `dry_run=True` этот словарь никуда не отправляется, см. `main()`
    — числа в нём означают «нашли», а не «применили»).
    """
    counts: dict[str, int] = {}
    for source in sources:
        try:
            counts[source.name] = run_source(source, client, dry_run=dry_run)
            log.info(
                "%s: %s %d",
                source.name,
                "нашли (DRY_RUN)" if dry_run else "применено",
                counts[source.name],
            )
        except Exception:
            log.exception("источник упал целиком: %s", source.name)
            counts[source.name] = 0
    return counts


def post_summary(base_url: str, token: str, counts: dict[str, int]) -> bool:
    """Возвращает `True`, только если сводка ГАРАНТИРОВАННО дошла до
    сотрудников: HTTP успешен И сервер подтвердил доставку в Telegram
    (`delivered: true` в ответе, см.
    `Webhooks::ZhkIngestController#summary`). `False` — сигнал `main()`
    завершиться ненулевым кодом (см. докстринг модуля, пункт 4).

    Приём принят сервером (HTTP 200), но НЕ доставлен в Telegram
    (`delivered: false`, например не настроен `TELEGRAM_STAFF_CHAT_ID`
    или сам Telegram недоступен) — это НЕ то же самое, что сбой запроса:
    различаем оба случая явно, а не приравниваем «сервер ответил» к
    «сотрудники узнали».
    """
    def _do() -> dict:
        response = requests.post(
            f"{base_url.rstrip('/')}/webhooks/zhk_ingest/summary",
            json={"counts": counts},
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )
        response.raise_for_status()
        return response.json()

    try:
        body = call_with_retry(_do, "сводка прогона")
    except Exception:
        log.exception("не удалось отправить сводку прогона (после ретраев): %s", counts)
        return False

    delivered = bool(body.get("delivered"))
    if not delivered:
        log.error(
            "сводка принята сервером, но НЕ доставлена в Telegram "
            "(проверь TELEGRAM_STAFF_CHAT_ID и доступность Telegram): %s", counts,
        )
    return delivered


def main() -> int:
    """`DRY_RUN=1` в окружении — прогон источников без единого похода на
    вебхук: ни батчи наблюдений, ни сводка не отправляются (см.
    `run_source`/`crawl`). Единственное назначение режима — проверить
    сами селекторы адаптеров на живой вёрстке источника ДО того, как
    результат уйдёт в Rails; поэтому `VICTORY_BASE_URL`/`ZHK_INGEST_TOKEN`
    в этом режиме необязательны (клиент создаётся, но ни разу не
    используется) — иначе прогон-проверку нельзя было бы запустить без
    боевых секретов, которых у проверяющего может и не быть под рукой.
    """
    dry_run = os.environ.get("DRY_RUN") == "1"
    contact = os.environ.get("CRAWLER_CONTACT", "info@victory62.org")

    if dry_run:
        base_url = os.environ.get("VICTORY_BASE_URL", "http://127.0.0.1:3001")
        token = os.environ.get("ZHK_INGEST_TOKEN", "dry-run")
    else:
        base_url = os.environ["VICTORY_BASE_URL"]
        token = os.environ["ZHK_INGEST_TOKEN"]

    session = requests.Session()
    sources = [ErzSource(session, contact), EdinstvoSource(session, contact)]
    client = IngestClient(base_url, token)

    counts = crawl(sources, client, dry_run=dry_run)

    if dry_run:
        log.info("DRY_RUN: сводка прогона не отправляется, итог по источникам: %s", counts)
        return 0

    delivered = post_summary(base_url, token, counts)

    return 0 if delivered else 1


if __name__ == "__main__":
    raise SystemExit(main())
