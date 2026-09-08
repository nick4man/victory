"""Разбор карточки застройщика «Единство» на зафиксированных страницах.
Сети здесь нет намеренно — `session` подменяется моком, `time.sleep` из
`sources.base` тоже подменяется, чтобы тесты не ждали настоящую
12-секундную паузу вежливости.

Фикстуры (`fixtures/edinstvo_list.html`, `fixtures/edinstvo_card.html`)
— реальные страницы edinstvo62.ru, снятые 08.09.26 curl'ом с
представленным User-Agent: домашняя страница (каталог ЖК) и карточка
ЖК «Скобелев» (`/building/83`, редиректит на `/building/zhk-skobelev`).

Запуск:
    cd services/zhk-registry && python3 -m unittest discover -v
"""

import os
import unittest
from unittest.mock import MagicMock, patch

import requests

from sources.edinstvo import EdinstvoSource

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")

CARD_URL = "https://edinstvo62.ru/building/83"


def fixture(name: str) -> str:
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return fh.read()


def _fake_session(html: str) -> MagicMock:
    """Мок `requests.Session` — единственная точка, где реальный сетевой
    клиент подменяется: `.get(...)` возвращает зафиксированный HTML
    вместо похода в сеть.
    """
    session = MagicMock()
    response = MagicMock()
    response.text = html
    response.raise_for_status.return_value = None
    session.get.return_value = response
    return session


def _error_session(status_code: int) -> MagicMock:
    """Мок сессии, у которой карточка отвечает HTTP-ошибкой — 404 на
    протухшую ссылку, 5xx на стороне сайта и т.п. `raise_for_status()`
    ведёт себя как у настоящего `requests.Response`.
    """
    session = MagicMock()
    response = MagicMock()
    response.status_code = status_code
    response.raise_for_status.side_effect = requests.HTTPError(
        f"{status_code} error", response=response
    )
    session.get.return_value = response
    return session


class TestEdinstvoDiscover(unittest.TestCase):
    """`discover()` — домашняя страница edinstvo62.ru. `/buildings` из
    черновика задачи не существует (404 на живом сайте, проверено
    вручную 08.09.26) — каталог ЖК живёт на самой домашней странице.
    """

    @patch("sources.base.time.sleep")
    def test_discover_dedupes_repeated_links(self, mock_sleep):
        # Один и тот же /building/<id> встречается в вёрстке несколько
        # раз (плитка в каталоге + маркер на карте) — без дедупа один ЖК
        # ушёл бы в очередь несколько раз за обход. На реальной фикстуре
        # это, например, /building/128 — он встречается 5 раз в сырой
        # разметке.
        session = _fake_session(fixture("edinstvo_list.html"))
        refs = EdinstvoSource(session=session, contact="test@example.com").discover()

        external_ids = [ref["external_id"] for ref in refs]
        self.assertEqual(len(external_ids), len(set(external_ids)))
        # Реальный каталог на момент снятия фикстуры — 46 уникальных ЖК.
        self.assertEqual(len(refs), 46)

    @patch("sources.base.time.sleep")
    def test_discover_builds_ref_for_known_zhk(self, mock_sleep):
        session = _fake_session(fixture("edinstvo_list.html"))
        refs = EdinstvoSource(session=session, contact="test@example.com").discover()

        skobelev = next(ref for ref in refs if ref["external_id"] == "edinstvo:83")
        self.assertEqual(skobelev["url"], CARD_URL)
        self.assertEqual(skobelev["name"], "Скобелев")

    @patch("sources.base.time.sleep")
    def test_user_agent_contains_contact(self, mock_sleep):
        session = _fake_session(fixture("edinstvo_list.html"))
        EdinstvoSource(session=session, contact="ops@victory62.org").discover()

        headers = session.get.call_args.kwargs["headers"]
        self.assertIn("ops@victory62.org", headers["User-Agent"])

    @patch("sources.base.time.sleep")
    def test_discover_pauses_between_requests(self, mock_sleep):
        # Вежливость обхода не факультативна: пауза перед запросом должна
        # реально стоять в коде, а не быть решением по факту сети.
        session = _fake_session(fixture("edinstvo_list.html"))
        EdinstvoSource(session=session, contact="test@example.com").discover()

        mock_sleep.assert_called_once()

    @patch("sources.base.time.sleep")
    def test_discover_requests_the_homepage_not_the_dead_buildings_path(self, mock_sleep):
        # Черновик задачи предполагал LIST_URL = ".../buildings" — такого
        # адреса на живом сайте нет (404, проверено вручную 08.09.26).
        # Каталог ЖК живёт на самой домашней странице. Мок сессии не
        # чувствителен к переданному url (отдаёт зафиксированный HTML
        # для любого адреса), поэтому без этой проверки регресс на
        # мёртвый путь остался бы незамеченным остальными тестами этого
        # класса.
        session = _fake_session(fixture("edinstvo_list.html"))
        EdinstvoSource(session=session, contact="test@example.com").discover()

        requested_url = session.get.call_args.args[0]
        self.assertEqual(requested_url, "https://edinstvo62.ru/")


class TestEdinstvoCard(unittest.TestCase):
    def setUp(self):
        self.html = fixture("edinstvo_card.html")
        self.source = EdinstvoSource(session=None, contact="test@example.com")

    def test_developer_is_hardcoded_not_scraped(self):
        # На своём сайте застройщик себя не подписывает — имя известно из
        # того, чей это сайт, и выдумывать его разбором не нужно.
        obs = self.source.parse_card(self.html, url=CARD_URL)

        self.assertEqual(obs.fields["developer"], "Единство")
        self.assertEqual(obs.source, "developer_site")

    def test_price_point_is_marked_as_from(self):
        obs = self.source.parse_card(self.html, url=CARD_URL)

        if obs.price:
            self.assertEqual(obs.price.kind, "from")
            self.assertGreater(obs.price.price_per_sqm, 10000)

    def test_price_absent_not_computed_from_total(self):
        # На карточке есть только итоговая цена «от» за квартиру целиком
        # ("квартиры от 0,0 миллиона рублей" — ЖК распродан) — не цена
        # за м². Price.price_per_sqm — контракт именно за метр; посчитать
        # его отсюда значило бы придумать площадь, которой на этой
        # странице нет. Явная проверка на None — чтобы будущая правка,
        # по ошибке трактующая общую цену как цену за метр, не прошла
        # тест молча.
        obs = self.source.parse_card(self.html, url=CARD_URL)

        self.assertIsNone(obs.price)

    def test_extracts_name_from_heading(self):
        obs = self.source.parse_card(self.html, url=CARD_URL)

        self.assertEqual(obs.name, "Скобелев")
        self.assertEqual(obs.city, "Рязань")
        self.assertEqual(obs.external_id, "edinstvo:83")

    def test_name_survives_non_quote_delimited_heading(self):
        # На реальных карточках заголовок не единообразен: у "Свободы"
        # это "Макроквартал «Свобода»" (не "ЖК ..."), у "Видного" —
        # "ЖК «Видный» (дом 4)" (хвост после кавычек). Общее у всех трёх
        # — текст в кавычках-«», его и берём вместо снятия префикса.
        html = '<h1 class="interactive-title">ЖК «Видный» (дом 4)</h1>'
        obs = self.source.parse_card(html, url="https://edinstvo62.ru/building/70")

        self.assertEqual(obs.name, "Видный")

    def test_name_falls_back_to_prefix_strip_without_guillemets(self):
        # Синтетический обрубок (не фикстура) — на всех живых карточках,
        # что мы видели, заголовок держит имя в кавычках-«». Запасной
        # путь на случай другой вёрстки код-ревью иначе не увидит.
        html = '<h1 class="interactive-title">ЖК Тест без кавычек</h1>'
        obs = self.source.parse_card(html, url="https://edinstvo62.ru/building/000")

        self.assertEqual(obs.name, "Тест без кавычек")

    def test_external_id_falls_back_to_raw_url_without_digits(self):
        # Синтетический обрубок — на реальных карточках `/building/<id>`
        # цифры в url есть всегда, но `parse_card()` может быть вызван и
        # напрямую (как в этих тестах) с произвольным url без них.
        obs = self.source.parse_card(self.html, url="https://edinstvo62.ru/building/zhk-skobelev")

        self.assertEqual(obs.external_id, "edinstvo:https://edinstvo62.ru/building/zhk-skobelev")

    def test_card_without_heading_raises_the_explicit_value_error(self):
        # `parse_card()` сама, напрямую (не через enrich()) — должна
        # бросать ИМЕННО заявленный ValueError с понятным сообщением, а
        # не полагаться на то, что `Observation(name=None, ...)` упадёт
        # с pydantic.ValidationError сама. `ValidationError` — подкласс
        # `ValueError`, и `except ValueError` в enrich() поймает любой из
        # двух одинаково — так что без этой отдельной проверки снятие
        # явного `raise` осталось бы незамеченным (обе ветки в итоге дают
        # `None` из enrich(), см. следующий тест).
        broken_html = "<html><body><p>Страница не найдена</p></body></html>"

        with self.assertRaises(ValueError) as ctx:
            self.source.parse_card(broken_html, url="https://edinstvo62.ru/building/000")

        self.assertIn("не нашли заголовок", str(ctx.exception))

    def test_card_without_heading_yields_none_not_exception(self):
        # Минимальная страница без заголовка — ровно то, что происходит,
        # если сайт отдал 404-заглушку или незнакомую вёрстку. Штатный
        # исход из enrich() (`None`), а не исключение наружу.
        broken_html = "<html><body><p>Страница не найдена</p></body></html>"
        session = _fake_session(broken_html)

        with patch("sources.base.time.sleep"):
            obs = EdinstvoSource(session=session, contact="test@example.com").enrich(
                {"url": "https://edinstvo62.ru/building/000", "external_id": "edinstvo:000"}
            )

        self.assertIsNone(obs)

    def test_enrich_returns_none_on_http_error_not_raising(self):
        # Протухшая ссылка (404) или временный сбой сайта (5xx) на одном
        # ЖК не должны прерывать обход остальных шести — это тот же
        # штатный `None`, что и неразборчивая вёрстка, только причина
        # сетевая, а не парсинговая.
        session = _error_session(404)

        with patch("sources.base.time.sleep"):
            obs = EdinstvoSource(session=session, contact="test@example.com").enrich(
                {"url": "https://edinstvo62.ru/building/000", "external_id": "edinstvo:000"}
            )

        self.assertIsNone(obs)

    def test_enrich_returns_none_on_connection_error_not_raising(self):
        # Тот же контракт для сбоя ниже уровня HTTP-статуса — таймаут или
        # обрыв соединения. `session.get` сам бросает исключение, до
        # `raise_for_status()` дело не доходит.
        session = MagicMock()
        session.get.side_effect = requests.ConnectionError("обрыв соединения")

        with patch("sources.base.time.sleep"):
            obs = EdinstvoSource(session=session, contact="test@example.com").enrich(
                {"url": "https://edinstvo62.ru/building/000", "external_id": "edinstvo:000"}
            )

        self.assertIsNone(obs)

    def test_enrich_prefers_ref_external_id_over_recomputed_one(self):
        # discover() и parse_card() вычисляют external_id одним и тем же
        # регэкспом по одному и тому же url — разойтись им неоткуда, но
        # ref из discover() всё равно авторитетный: по этому полю сервер
        # матчит повторную доставку, и явная перезапись в enrich()
        # защищает от расхождения, если оба регэкспа позже поправят
        # порознь (ровно так разъехались двойные external_id в ЕРЗ).
        session = _fake_session(self.html)
        ref = {"url": CARD_URL, "external_id": "edinstvo:OVERRIDE", "name": "Скобелев"}

        with patch("sources.base.time.sleep"):
            obs = EdinstvoSource(session=session, contact="test@example.com").enrich(ref)

        self.assertEqual(obs.external_id, "edinstvo:OVERRIDE")


if __name__ == "__main__":
    unittest.main()
