"""ГК «Единство» — первичный источник по своим комплексам.

Вес выше, чем у агрегатора (ЕРЗ, вес 2): застройщик знает про свой дом
больше, чем каталог. На «Единстве» висит семь из двенадцати засеянных
ЖК Рязани — это самая быстрая проверка того, что связка работает от
источника до карточки в админке.

Каталог живёт на самой домашней странице (`https://edinstvo62.ru/`), а
не на `/buildings` — такого адреса у сайта нет (проверено вручную
08.09.26 curl'ом: 404). Карточка ЖК отдаётся по числовому адресу
`/building/<id>`, но сайт 301-редиректит его на человекочитаемый slug
(`/building/83` → `/building/zhk-skobelev`) — `requests` идёт по
редиректу сам, а `external_id` и `url` в наблюдении остаются от
исходного числового адреса: это и есть надёжный ключ повторной
доставки, слаг под ним со временем может смениться.

О цене: карточка ЖК отдаёт только итоговую цену «от» за квартиру целиком
(«квартиры от 4,0 миллиона рублей», «от 0,0 миллиона рублей» — так
помечен ЖК, где раскуплено всё) — не цену за квадратный метр. Контракт
`Price.price_per_sqm` — именно за метр, и превратить общую цену в цену
за метр значило бы посчитать площадь, которой на этой странице нет
(площади лотов есть только на отдельной странице `/flat/<id>`, за
пределами одного запроса на карточку). Источник осознанно не заполняет
`price` вовсе вместо того, чтобы подставить туда посчитанное число:
отсутствие факта — не то же самое, что факт, который мы выдумали.
Проверено вручную 08.09.26 живыми запросами по шести карточкам
(`/building/83`, `/128`, `/122`, `/70`, `/49`, `/40`) и по одному
макроквартала (`/complex/64`, другая вёрстка) — везде одна и та же
формулировка, ни на одной странице нет цены за метр статикой.
"""

import logging
import re
from datetime import datetime, timezone

import requests
from bs4 import BeautifulSoup

from observation import Observation
from sources.base import polite_get

LIST_URL = "https://edinstvo62.ru/"
DEVELOPER = "Единство"
CITY = "Рязань"

log = logging.getLogger(__name__)


class EdinstvoSource:
    """Реализация протокола `Source`, см. `sources/base.py`."""

    # Имя источника — ИДЕНТИЧНОСТЬ, а не роль. Идентичность `ZhkFact`
    # это `(complex, field, source)`, поэтому второй сайт застройщика
    # под общим именем «developer_site» перетирал бы факты первого, и
    # настоящее расхождение стало бы невидимым — ровно то, ради чего
    # таблица заведена. К этому же имени привязан журнал `ZhkIngestRun`
    # (детектор молчащего источника), так что переименование позже
    # стоило бы обнуления его истории.
    name = "edinstvo"
    weight = 3

    def __init__(self, session, contact: str):
        self.session = session
        self.contact = contact

    def discover(self) -> list[dict]:
        """Ссылки на карточки ЖК с домашней страницы.

        Один и тот же `/building/<id>` встречается в вёрстке несколько
        раз (плитка в каталоге + маркер на карте) — дедуп по
        `external_id` обязателен, иначе один ЖК уйдёт в очередь
        несколько раз за один обход.
        """
        html = polite_get(self.session, LIST_URL, self.contact)
        soup = BeautifulSoup(html, "html.parser")

        seen: set[str] = set()
        refs = []
        for link in soup.select("a[href*='/building/']"):
            href = link.get("href", "")
            match = re.search(r"/building/(\d+)", href)
            if not match:
                continue

            external_id = f"edinstvo:{match.group(1)}"
            if external_id in seen:
                continue
            seen.add(external_id)

            refs.append({
                "url": href if href.startswith("http") else f"https://edinstvo62.ru{href}",
                "external_id": external_id,
                "name": self._list_name(link),
            })
        return refs

    def enrich(self, ref: dict) -> Observation | None:
        """Наблюдение по одной карточке.

        `None` — штатный исход, не ошибка, и это касается двух разных
        причин, ни одна из которых не повод уронить весь обход
        остальных ЖК:

        - карточка недоступна (404 на протухшую ссылку, таймаут, 5xx) —
          сетевая ошибка `requests`;
        - карточка отдалась, но неразборчива (редизайн, A/B-вариант
          вёрстки) — `parse_card()` не нашёл даже заголовка.
        """
        try:
            html = polite_get(self.session, ref["url"], self.contact)
        except requests.RequestException as exc:
            log.warning("карточка ЖК недоступна %s: %s", ref.get("url"), exc)
            return None

        try:
            obs = self.parse_card(html, url=ref["url"])
        except ValueError as exc:
            log.warning("карточка ЖК неразборчива %s: %s", ref.get("url"), exc)
            return None

        # `external_id` у discover() и parse_card() — оба вычисляют его
        # одним и тем же регэкспом по одному и тому же url, разойтись им
        # неоткуда. Но авторитетный источник — ref из discover(): под
        # этим id сервер будет матчить повторную доставку, и явная
        # перезапись защищает от расхождения, если регэкспы позже
        # поправят порознь.
        if ref.get("external_id"):
            obs.external_id = ref["external_id"]

        return obs

    def parse_card(self, html: str, url: str) -> Observation:
        """Разбирает карточку ЖК на `/building/<id>`.

        Бросает `ValueError`, если на странице не нашлось даже
        заголовка — значит, вёрстка разошлась с ожидаемой настолько,
        что строить наблюдение не из чего. `enrich()` превращает это
        исключение в `None`, как и предписывает протокол `Source`.
        """
        soup = BeautifulSoup(html, "html.parser")

        name = self._name(soup)
        if not name:
            raise ValueError("не нашли заголовок ЖК — карточка неразборчива")

        return Observation(
            source=self.name,
            external_id=self._external_id(url),
            url=url,
            name=name,
            city=CITY,
            fetched_at=self._now(),
            # Застройщик на своём сайте себя не подписывает — это и так
            # известно из того, чей это сайт, разбирать нечего.
            fields={"developer": DEVELOPER},
            # Цену намеренно не заполняем — см. docstring модуля: карточка
            # отдаёт только итоговую цену «от» за квартиру, не за м².
            price=None,
        )

    # --- вспомогательное -------------------------------------------------

    @staticmethod
    def _name(soup: BeautifulSoup) -> str | None:
        """Имя ЖК из `<h1>`.

        Заголовки на сайте не единообразны: `ЖК «Скобелев»`,
        `Макроквартал «Свобода»`, `ЖК «Видный» (дом 4)` — общее у всех
        трёх только текст в кавычках-«», его и берём. Без кавычек (на
        случай другой вёрстки) — запасной путь: снимаем типовой префикс.
        """
        heading = soup.find("h1")
        if not heading:
            return None
        text = heading.get_text(" ", strip=True)
        if not text:
            return None

        match = re.search(r"«([^»]+)»", text)
        if match:
            return match.group(1).strip() or None

        fallback = re.sub(r"^\s*(ЖК|Жилой комплекс|Макроквартал)\s+", "", text).strip()
        return fallback or None

    @staticmethod
    def _list_name(link) -> str:
        """Короткое имя для `ref` — в итоговое наблюдение не попадает
        (`parse_card()` берёт имя из заголовка самой карточки), нужно
        только для читаемости лога обхода.
        """
        text = link.get_text(" ", strip=True)
        match = re.search(r"«([^»]+)»", text)
        return match.group(1).strip() if match else text[:60]

    @staticmethod
    def _external_id(url: str) -> str:
        match = re.search(r"/building/(\d+)", url)
        return f"edinstvo:{match.group(1)}" if match else f"edinstvo:{url}"

    @staticmethod
    def _now() -> str:
        return datetime.now(timezone.utc).isoformat()
