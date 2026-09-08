"""Отправка наблюдений в Rails. Единственный способ службы что-либо
записать: прямого доступа к базе у неё нет и быть не должно.

Контракт — `POST /webhooks/zhk_ingest`
(`app/controllers/webhooks/zhk_ingest_controller.rb`):

- батч режется по `MAX_BATCH` **на стороне клиента** — сервер отвергает
  батч длиннее 50 целиком (422), поэтому здесь режем заранее и никогда
  до этого не доводим;
- `Authorization: Bearer <token>` строго с префиксом — голое значение
  токена сервер отвергает (401);
- ответ содержит `results` с построчным статусом
  `created|updated|duplicate|invalid` на каждое наблюдение батча.

Смысл кодов важен для вызывающей стороны, а не только для нас:

- `invalid` (в теле, для конкретного наблюдения) — «не примем никогда»,
  ретраить бессмысленно;
- `duplicate` — «уже есть, всё хорошо», это не ошибка;
- 4xx на уровне HTTP-ответа (весь батч не по контракту, неверный токен) —
  вина вызывающей стороны, ретрай без исправления входа не поможет;
- 503 — секрет `ZHK_INGEST_TOKEN` не выставлен на сервере, это
  конфигурационный сбой Rails-стороны, а не отказ навсегда: такой запрос
  стоит повторить позже. `raise_for_status()` подскажет это через
  `requests.HTTPError`, дальнейшую политику ретраев решает вызывающий код
  (здесь её нет — служба сбора вне рамок этой задачи).
"""

from __future__ import annotations

import logging

import requests

from observation import Observation

MAX_BATCH = 50
TIMEOUT = 30

log = logging.getLogger(__name__)


class IngestClient:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def send(self, observations: list[Observation]) -> list[dict]:
        """Отправляет наблюдения, разбив их на батчи по `MAX_BATCH`.

        Список материализуется заранее (а не потребляется лениво), чтобы
        `range(0, len(observations), MAX_BATCH)` мог посчитать длину —
        генератор здесь не годится.

        Известный смежный эффект, сознательно не чинится сейчас: если
        `_post` бросает исключение на чанке N (N > 1), результаты уже
        отправленных чанков 1..N-1 накоплены в локальной `results`, но до
        `return` дело не доходит — вызывающий код их не увидит, хотя на
        сервере они уже применились (данные не теряются, `Zhk::Ingest`
        идемпотентен). То есть после сбоя середины батча звонящий не
        узнаёт, какая часть на самом деле прошла. Чинить это — забота
        ретраера/сборщика из задач 9-11, которому и решать, что делать с
        частично успешным батчем; здесь только фиксация факта.
        """
        results: list[dict] = []

        for start in range(0, len(observations), MAX_BATCH):
            chunk = observations[start:start + MAX_BATCH]
            results.extend(self._post(chunk))

        return results

    def _post(self, batch: list[Observation]) -> list[dict]:
        response = requests.post(
            f"{self.base_url}/webhooks/zhk_ingest",
            json={"observations": [o.to_payload() for o in batch]},
            headers={"Authorization": f"Bearer {self.token}"},
            timeout=TIMEOUT,
        )
        response.raise_for_status()

        rows = response.json().get("results", [])
        for row in rows:
            if row.get("status") == "invalid":
                log.warning(
                    "наблюдение отвергнуто навсегда: %s — %s",
                    row.get("external_id"), row.get("reasons"),
                )
        return rows
