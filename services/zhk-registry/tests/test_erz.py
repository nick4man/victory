"""Разбор ЕРЗ на зафиксированных страницах. Сети здесь нет намеренно —
`session` подменяется моком, `time.sleep` из `sources.base` тоже
подменяется, чтобы тесты не ждали настоящую 12-секундную паузу вежливости.

Фикстуры (`fixtures/erz_list.html`, `fixtures/erz_card.html`) — реальные
страницы erzrf.ru, снятые 08.09.26 curl'ом с представленным User-Agent:
список ЖК Рязанской области и карточка ЖК «Манхэттен».

Запуск:
    cd services/zhk-registry && python3 -m unittest discover -v
"""

import os
import unittest
from unittest.mock import MagicMock, patch

import requests

from sources.erz import ErzSource

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")

CARD_URL = "https://erzrf.ru/novostroyki/zhk-mankhetten-21004202001"


def fixture(name: str) -> str:
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return fh.read()


def _fake_session(html: str) -> MagicMock:
    """Мок `requests.Session` — единственная точка, где реальный сетевой
    клиент подменяется: `.get(...)` возвращает зафиксированный HTML вместо
    похода в сеть.
    """
    session = MagicMock()
    response = MagicMock()
    response.text = html
    response.raise_for_status.return_value = None
    session.get.return_value = response
    return session


def _error_session(status_code: int) -> MagicMock:
    """Мок сессии, у которой карточка отвечает HTTP-ошибкой — 404 на
    протухшую ссылку, 5xx на стороне ЕРЗ и т.п. `raise_for_status()`
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


class TestErzDiscover(unittest.TestCase):
    """`discover()` — страница списка региона. Этажность и срок сдачи по
    ЖК видны статикой только здесь (erzrf.ru — Angular SPA, карточка их
    без JS не отдаёт), поэтому именно `discover()`, а не `parse_card()`,
    и есть место, где эти два факта проверяются.
    """

    @patch("sources.base.time.sleep")
    def test_discover_finds_zhk_on_saved_list(self, mock_sleep):
        session = _fake_session(fixture("erz_list.html"))
        refs = ErzSource(session=session, contact="test@example.com").discover()

        # Реальный список Рязани на момент снятия фикстуры — 10 ЖК.
        self.assertEqual(len(refs), 10)

        manhattan = next(ref for ref in refs if ref["name"] == "ЖК Манхэттен")
        self.assertEqual(manhattan["external_id"], "erz:21004202001")
        self.assertEqual(manhattan["url"], CARD_URL)
        # Год сдачи пишут по-разному: здесь — "от IV кв. 2026". У другого
        # ЖК в этом же списке (ниже) — "Сдан". Берём ровно то, что на
        # странице, без нормализации в код здесь.
        self.assertEqual(manhattan["commissioning"], "от IV кв. 2026")
        self.assertEqual(manhattan["floors"], "11 - 20")

        finished = next(ref for ref in refs if "Парковый квартал" in ref["name"])
        self.assertEqual(finished["commissioning"], "Сдан")

    @patch("sources.base.time.sleep")
    def test_discover_leaves_missing_commissioning_absent(self, mock_sleep):
        # На реальной фикстуре у "ЖК ITower" на странице списка нет ни
        # этажности, ни срока сдачи вовсе — ключей быть не должно, а не
        # пустой строки на их месте.
        session = _fake_session(fixture("erz_list.html"))
        refs = ErzSource(session=session, contact="test@example.com").discover()

        itower = next(ref for ref in refs if "ITower" in ref["name"])
        self.assertNotIn("commissioning", itower)
        self.assertNotIn("floors", itower)

    @patch("sources.base.time.sleep")
    def test_user_agent_contains_contact(self, mock_sleep):
        session = _fake_session(fixture("erz_list.html"))
        ErzSource(session=session, contact="ops@victory62.org").discover()

        headers = session.get.call_args.kwargs["headers"]
        self.assertIn("ops@victory62.org", headers["User-Agent"])

    @patch("sources.base.time.sleep")
    def test_discover_pauses_between_requests(self, mock_sleep):
        # Вежливость обхода не факультативна: пауза перед запросом должна
        # реально стоять в коде, а не быть решением по факту сети.
        session = _fake_session(fixture("erz_list.html"))
        ErzSource(session=session, contact="test@example.com").discover()

        mock_sleep.assert_called_once()


class TestErzCard(unittest.TestCase):
    def setUp(self):
        self.source = ErzSource(session=None, contact="test@example.com")

    def test_extracts_facts_from_card(self):
        obs = self.source.parse_card(fixture("erz_card.html"), url=CARD_URL)

        self.assertEqual(obs.source, "erz")
        self.assertEqual(obs.name, "Манхэттен")
        self.assertEqual(obs.city, "Рязань")
        self.assertEqual(obs.fields["developer"], "ООО СЗ Возрождение")

    def test_missing_field_is_absent_not_guessed(self):
        obs = self.source.parse_card(fixture("erz_card.html"), url=CARD_URL)

        # Чего на странице нет — того нет в наблюдении. Пустая строка или
        # «н/д» в fields превратились бы на стороне Rails в факт.
        for key, value in obs.fields.items():
            self.assertNotIn(value, ("", "н/д", "—"), key)

    def test_blank_marker_value_treated_as_absent(self):
        # Синтетический обрубок (не фикстура) — проверяет только защиту
        # `_labelled` от заглушки сайта; на реальной странице «Манхэттен»
        # такого поля нет вовсе, так что этот путь код-ревью иначе не
        # увидит.
        html = (
            '<h1 class="house__title">ЖК Тест</h1>'
            "<table><tr><td><b>Застройщик</b></td><td>н/д</td></tr></table>"
        )
        obs = self.source.parse_card(html, url="https://erzrf.ru/novostroyki/zhk-test-1")

        self.assertNotIn("developer", obs.fields)

    def test_card_without_expected_block_yields_none_not_exception(self):
        # Минимальная страница без «паспортной» таблицы и без заголовка —
        # ровно то, что происходит, если сайт отдал 404-заглушку или
        # незнакомую вёрстку. Это штатный исход (`None`), а не исключение.
        broken_html = "<html><body><p>Страница не найдена</p></body></html>"
        session = _fake_session(broken_html)

        with patch("sources.base.time.sleep"):
            obs = ErzSource(session=session, contact="test@example.com").enrich(
                {"url": "https://erzrf.ru/novostroyki/zhk-mystery-000"}
            )

        self.assertIsNone(obs)

    def test_enrich_merges_floors_and_commissioning_from_ref(self):
        # `enrich()` не ищет этажность/срок сдачи на карточке (там их нет
        # статикой) — переносит то, что `discover()` уже нашёл в ref.
        session = _fake_session(fixture("erz_card.html"))
        ref = {
            "url": CARD_URL,
            "external_id": "erz:21004202001",
            "name": "ЖК Манхэттен",
            "floors": "11 - 20",
            "commissioning": "от IV кв. 2026",
        }

        with patch("sources.base.time.sleep"):
            obs = ErzSource(session=session, contact="test@example.com").enrich(ref)

        self.assertIsNotNone(obs)
        self.assertEqual(obs.external_id, "erz:21004202001")
        self.assertEqual(obs.fields["floors"], "11 - 20")
        self.assertEqual(obs.fields["commissioning"], "от IV кв. 2026")
        self.assertEqual(obs.fields["developer"], "ООО СЗ Возрождение")

    def test_enrich_prefers_ref_external_id_over_recomputed_one(self):
        # `discover()` берёт external_id из gkId в href, `parse_card()` —
        # регэкспом по хвосту url. В реальности они совпадают (слаг ЕРЗ
        # оканчивается тем же id), но здесь намеренно разведены, чтобы
        # доказать: итоговое наблюдение берёт значение из ref, а не
        # пересчитывает его заново по url. По этому полю сервер отличает
        # повторную доставку от новой — молчаливое расхождение здесь
        # было бы дефектом дедупликации, а не мелочью.
        session = _fake_session(fixture("erz_card.html"))
        ref = {"url": CARD_URL, "external_id": "erz:OVERRIDE", "name": "ЖК Манхэттен"}

        with patch("sources.base.time.sleep"):
            obs = ErzSource(session=session, contact="test@example.com").enrich(ref)

        self.assertEqual(obs.external_id, "erz:OVERRIDE")

    def test_enrich_returns_none_on_http_error_not_raising(self):
        # Протухшая ссылка (404) или временный сбой ЕРЗ (5xx) на одном ЖК
        # не должны прерывать обход остальных — это тот же штатный `None`,
        # что и неразборчивая вёрстка, только причина сетевая, а не
        # парсинговая.
        session = _error_session(404)

        with patch("sources.base.time.sleep"):
            obs = ErzSource(session=session, contact="test@example.com").enrich(
                {"url": "https://erzrf.ru/novostroyki/zhk-protuhshij-000", "external_id": "erz:000"}
            )

        self.assertIsNone(obs)

    def test_enrich_returns_none_on_connection_error_not_raising(self):
        # Тот же контракт для сбоя ниже уровня HTTP-статуса — таймаут или
        # обрыв соединения. `session.get` сам бросает исключение, до
        # `raise_for_status()` дело не доходит.
        session = MagicMock()
        session.get.side_effect = requests.ConnectionError("обрыв соединения")

        with patch("sources.base.time.sleep"):
            obs = ErzSource(session=session, contact="test@example.com").enrich(
                {"url": "https://erzrf.ru/novostroyki/zhk-protuhshij-000", "external_id": "erz:000"}
            )

        self.assertIsNone(obs)

    def test_enrich_does_not_invent_floors_when_ref_lacks_them(self):
        # Симметрично предыдущему: если в ref не было этажности (как у
        # реального "ITower"), в итоговом наблюдении её тоже быть не
        # должно — не появляется "0" или пустая строка вместо отсутствия.
        session = _fake_session(fixture("erz_card.html"))
        ref = {"url": CARD_URL, "external_id": "erz:21004202001", "name": "ЖК Манхэттен"}

        with patch("sources.base.time.sleep"):
            obs = ErzSource(session=session, contact="test@example.com").enrich(ref)

        self.assertIsNotNone(obs)
        self.assertNotIn("floors", obs.fields)
        self.assertNotIn("commissioning", obs.fields)


if __name__ == "__main__":
    unittest.main()
