"""Повторная классификация новостей, на которых упала LLM-цепочка.

До 13.09.26 новость, которую не удалось классифицировать, писалась в
urgent_events как NOISE. Строка там — отметка «уже видели»: already_seen
режет по source_url, и переклассифицировать новость больше нельзя. Любой сбой
цепочки (квота Google, протухший ключ, DNS) молча выбрасывал всё, что пришло
за это время, — включая срочные новости. Так 07.09.26 ушли 1950 новостей,
13.09.26 — 20 из 25 после трёхчасового обрыва DNS.

Теперь новость при сбое не пишется вовсе и остаётся в ленте на следующий
прогон. Две страховки от обратной крайности:

- RetryLedger помнит, когда новость впервые не классифицировалась. Если сбой
  тянется дольше GIVE_UP_AFTER_HOURS, новость уходит в NOISE по-старому.
  Иначе «ядовитая» запись, на которой стабильно ломается разбор ответа, гоняла
  бы цепочку (с платной моделью в конце) каждые полчаса вечно.
- ChainBreaker останавливает прогон после нескольких сбоев подряд: при
  упавшей цепочке нет смысла жечь квоту на остальные новости — они дождутся
  следующего прогона.

Модуль намеренно на одной stdlib — тесты гоняются системным python3 без venv.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta

# 6 ч — окно срочности: urgent_trigger понижает URGENT старше URGENT_MAX_AGE_HOURS.
# Дольше держать новость в очереди незачем, срочной она уже не станет.
GIVE_UP_AFTER_HOURS = 6

# Два подряд, а не один: одиночный сбой бывает и у «ядовитой» записи, и тогда
# остановка прогона застопорила бы все ленты после неё.
BREAKER_THRESHOLD = 2

# Записи старше этого срока выметаются: новость давно выпала из RSS.
PRUNE_AFTER_DAYS = 3


def retry_key(url: str | None, headline: str) -> str:
    """Ключ новости — как в already_seen: URL, а без него заголовок."""
    return url or f"headline:{headline}"


class RetryLedger:
    """JSON-файл {ключ: время первого сбоя в ISO}."""

    def __init__(self, path: str, give_up_after: timedelta = timedelta(hours=GIVE_UP_AFTER_HOURS)):
        self.path = path
        self.give_up_after = give_up_after
        self._first_failed: dict[str, str] = {}
        self._dirty = False

    def load(self) -> RetryLedger:
        try:
            with open(self.path, encoding="utf-8") as fh:
                data = json.load(fh)
            if isinstance(data, dict):
                self._first_failed = {str(k): str(v) for k, v in data.items()}
        except FileNotFoundError:
            pass
        except (OSError, ValueError):
            # Битый файл не должен ронять сбор: теряем только счётчики ожидания.
            self._first_failed = {}
            self._dirty = True
        return self

    def record_failure(self, key: str, now: datetime) -> bool:
        """Отметить сбой. True — ждать хватит, пора сдаваться в NOISE."""
        first = self._first_failed.get(key)
        if first is None:
            self._first_failed[key] = now.isoformat()
            self._dirty = True
            return False
        try:
            first_dt = datetime.fromisoformat(first)
        except ValueError:
            self._first_failed[key] = now.isoformat()
            self._dirty = True
            return False
        return now - first_dt >= self.give_up_after

    def forget(self, key: str) -> None:
        if self._first_failed.pop(key, None) is not None:
            self._dirty = True

    def pending(self) -> int:
        return len(self._first_failed)

    def prune(self, now: datetime, older_than: timedelta = timedelta(days=PRUNE_AFTER_DAYS)) -> None:
        for key, first in list(self._first_failed.items()):
            try:
                stale = now - datetime.fromisoformat(first) >= older_than
            except ValueError:
                stale = True
            if stale:
                del self._first_failed[key]
                self._dirty = True

    def save(self) -> None:
        if not self._dirty:
            return
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        tmp = f"{self.path}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self._first_failed, fh, ensure_ascii=False, indent=1, sort_keys=True)
        os.replace(tmp, self.path)
        self._dirty = False


class ChainBreaker:
    """Счётчик сбоев цепочки подряд в пределах одного прогона."""

    def __init__(self, threshold: int = BREAKER_THRESHOLD):
        self.threshold = threshold
        self.consecutive = 0

    def success(self) -> None:
        self.consecutive = 0

    def failure(self) -> None:
        self.consecutive += 1

    @property
    def tripped(self) -> bool:
        return self.consecutive >= self.threshold
