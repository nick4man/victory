"""ЕРЗ.РФ — обнаружение новых ЖК Рязани и фактура средней достоверности.

Роль в реестре: находить комплексы, которых ещё нет в справочнике, и
снимать то немногое, что erzrf.ru отдаёт без выполнения JavaScript.
Первичным источником по фактам считается сайт застройщика (вес выше);
ЕРЗ — вторичный, вес ниже.

Важная особенность вёрстки erzrf.ru, из-за которой `discover()` и
`parse_card()` берут разные факты с разных страниц: это Angular-SPA, и
`<script id="serverApp-state">` (state для гидратации) на живых страницах
пуст (`{}`) — сервер не кладёт в него данные предметных виджетов. Из-за
этого:

- карточка ЖК (`/novostroyki/<slug>`) отдаёт статикой только «паспортную»
  таблицу: регион, населённый пункт, застройщик, улица и т.п. — это
  разбирает `parse_card()`;
- этажность и срок сдачи по ЖК видны статикой только на странице списка
  региона (`REGION_URL`) — их разбирает `discover()` и передаёт дальше
  через `ref`, не пытаясь искать на карточке то, чего там нет.

Проверено вручную 08.09.26 живым запросом (не в тестах — тесты сети не
трогают): подтверждено curl'ом с представленным User-Agent.
"""

import re
from datetime import datetime, timezone

from bs4 import BeautifulSoup

from observation import Observation
from sources.base import polite_get

REGION_URL = (
    "https://erzrf.ru/novostroyki"
    "?region=ryazanskaya-oblast&regionKey=144706001&viewModeDev=list"
)
CITY = "Рязань"

# Значения-заглушки, которыми сайт помечает пустую ячейку. Такое значение
# для нас равносильно отсутствию факта, а не факту "пустая строка".
_BLANK = {"", "н/д", "—", "-"}


class ErzSource:
    name = "erz"
    weight = 2

    def __init__(self, session, contact: str):
        self.session = session
        self.contact = contact

    def discover(self) -> list[dict]:
        """Ссылки на ЖК Рязани со страницы списка региона.

        Этажность и срок сдачи по ЖК показаны только здесь (см. docstring
        модуля) — кладём их в ref как есть, без нормализации: что
        написано на странице, то и наблюдение. Сравнивать разные записи
        формата "2026" / "IV кв. 2026" / "Сдан" между собой — забота
        стороны Rails, не этого адаптера.
        """
        html = polite_get(self.session, REGION_URL, self.contact)
        soup = BeautifulSoup(html, "html.parser")

        refs = []
        for card in soup.select("div.building"):
            link = card.select_one("h3.building__title a")
            href = link.get("href") if link else None
            if not href:
                continue

            gk_id = self._gk_id(href)
            slug = self._slug(href)
            if not gk_id or not slug:
                continue

            ref = {
                "url": f"https://erzrf.ru/novostroyki/{slug}",
                "external_id": f"erz:{gk_id}",
                "name": link.get_text(strip=True),
            }

            details = card.select_one("div.building__details")
            text = re.sub(r"\s+", " ", details.get_text(" ", strip=True)) if details else ""

            floors = self._between(text, "Этажей ЖК:", ("Срок сдачи", "Оценка ЕРЗ"))
            if floors:
                ref["floors"] = floors

            commissioning = self._between(text, "Срок сдачи по ЖК:", ("Оценка ЕРЗ",))
            if commissioning:
                ref["commissioning"] = commissioning

            refs.append(ref)

        return refs

    def enrich(self, ref: dict) -> Observation | None:
        """Наблюдение по одному ЖК: карточка + то, что уже нашли в discover.

        `None` — штатный исход, не ошибка: карточка бывает неразборчива
        (редизайн, A/B-вариант вёрстки), и в этом случае лучше пропустить
        ЖК в этом обходе, чем выдумать наблюдение из половины фактов.
        """
        html = polite_get(self.session, ref["url"], self.contact)
        try:
            obs = self.parse_card(html, url=ref["url"])
        except ValueError:
            return None

        for key in ("floors", "commissioning"):
            if ref.get(key):
                obs.fields[key] = ref[key]

        return obs

    def parse_card(self, html: str, url: str) -> Observation:
        """Разбирает «паспортную» таблицу карточки ЖК.

        Бросает `ValueError`, если на странице не нашлось даже заголовка —
        значит, вёрстка разошлась с ожидаемой настолько, что строить
        наблюдение не из чего. `enrich()` превращает это исключение в
        `None`, как и предписывает протокол `Source`.
        """
        soup = BeautifulSoup(html, "html.parser")

        name = self._title(soup)
        if not name:
            raise ValueError("не нашли заголовок ЖК — карточка неразборчива")

        fields = {}
        developer = self._labelled(soup, "Застройщик")
        if developer:
            fields["developer"] = developer

        return Observation(
            source=self.name,
            external_id=self._external_id(url),
            url=url,
            name=name,
            city=self._city(soup) or CITY,
            fetched_at=self._now(),
            fields=fields,
        )

    # --- вспомогательное -------------------------------------------------

    def _title(self, soup: BeautifulSoup) -> str | None:
        heading = soup.find("h1")
        text = heading.get_text(strip=True) if heading else ""
        text = re.sub(r"^\s*(ЖК|Жилой комплекс)\s+", "", text).strip('«»" ')
        return text or None

    def _city(self, soup: BeautifulSoup) -> str | None:
        value = self._labelled(soup, "Населенный пункт")
        if not value:
            return None
        return re.sub(r"^(город|г\.)\s+", "", value).strip() or None

    def _labelled(self, soup: BeautifulSoup, label: str) -> str | None:
        """Значение из строки паспортной таблицы вида
        `<tr><td><b>Label</b></td><td>Value</td></tr>`.

        Пустое значение или заглушка сайта (`н/д`, `—`) — это отсутствие
        факта, а не факт: на стороне Rails пустая строка стала бы записью
        в провенансе и породила бы ложное расхождение с другим
        источником.
        """
        node = soup.find("b", string=lambda s: bool(s) and s.strip() == label)
        if not node:
            return None
        row = node.find_parent("tr")
        if not row:
            return None
        cells = row.find_all("td")
        if len(cells) < 2:
            return None
        value = cells[1].get_text(" ", strip=True)
        return value if value not in _BLANK else None

    @staticmethod
    def _between(text: str, start: str, stop_markers: tuple[str, ...]) -> str | None:
        """Кусок нормализованного текста между меткой `start` и первым из
        `stop_markers`. Возвращает `None`, если метка не найдена или между
        ней и стоп-словом пусто — карточка/список не обязаны содержать
        каждый показатель для каждого ЖК (пример на реальной фикстуре:
        у "ITower" и "VELLCOM" на странице списка нет ни этажности, ни
        срока сдачи вовсе).
        """
        idx = text.find(start)
        if idx == -1:
            return None
        rest = text[idx + len(start):]
        stop = len(rest)
        for marker in stop_markers:
            pos = rest.find(marker)
            if pos != -1:
                stop = min(stop, pos)
        value = rest[:stop].strip(" .")
        return value or None

    @staticmethod
    def _gk_id(href: str) -> str | None:
        match = re.search(r"gkId=(\d+)", href)
        return match.group(1) if match else None

    @staticmethod
    def _slug(href: str) -> str | None:
        match = re.search(r"/novostroyki/([^?]+)", href)
        return match.group(1) if match else None

    @staticmethod
    def _external_id(url: str) -> str:
        match = re.search(r"-(\d+)$", url.rstrip("/"))
        return f"erz:{match.group(1)}" if match else f"erz:{url}"

    @staticmethod
    def _now() -> str:
        return datetime.now(timezone.utc).isoformat()
