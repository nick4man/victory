"""Общее для адаптеров источников.

Вес источника живёт ЗДЕСЬ, в конфиге адаптера, и в базу не попадает
никогда: это свойство источника, а не строки данных. Надстройки (черновик
текста, досье) получат вес в промпт как контекст.
"""

import time
from typing import Protocol

from observation import Observation

# Вежливость обхода не факультативна: пауза между запросами и
# представленный User-Agent. Обходы последовательные (не параллельные) —
# внутри одного процесса это гарантирует сам факт синхронного вызова
# `discover`/`enrich` один за другим, здесь достаточно паузы перед каждым
# запросом.
DELAY_SECONDS = 12


class Source(Protocol):
    name: str
    weight: int

    def discover(self) -> list[dict]: ...

    def enrich(self, ref: dict) -> Observation | None: ...


def polite_get(session, url: str, contact: str) -> str:
    """GET с паузой и представленным User-Agent.

    `contact` попадает в User-Agent буквально — это единственный способ
    для владельца стороннего сайта понять, кто к нему ходит, и написать,
    если обход мешает. Не сокращать и не убирать из строки.
    """
    time.sleep(DELAY_SECONDS)
    response = session.get(
        url,
        headers={"User-Agent": f"victory62-registry ({contact})"},
        timeout=30,
    )
    response.raise_for_status()
    return response.text
