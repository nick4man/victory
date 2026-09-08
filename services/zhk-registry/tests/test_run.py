"""Оркестратор (`run.py`): изоляция источников и ретрай транзиентных
сбоев отправки. Транспорт (`client.send`) везде подменяется — сеть в этих
тестах не участвует.

Запуск:
    cd services/zhk-registry && python3 -m unittest discover -v
"""

import unittest
from unittest.mock import MagicMock, patch

import requests

from observation import Observation
from run import MAX_SEND_RETRIES, crawl, is_transient, run_source, send_with_retry

OBSERVATION = Observation(
    source="test", external_id="test:1", name="Тест", city="Рязань",
    fetched_at="2026-09-07T00:00:00Z",
)


def _http_error(status_code: int) -> requests.HTTPError:
    response = MagicMock()
    response.status_code = status_code
    return requests.HTTPError(f"{status_code} error", response=response)


class FakeSource:
    """Минимальная реализация протокола `Source` для тестов оркестратора —
    без сети, без BeautifulSoup, только то, что нужно `crawl`/`run_source`.
    """

    def __init__(self, name, refs=None, discover_error=None, enrich_error_on=None):
        self.name = name
        self.weight = 1
        self._refs = refs or []
        self._discover_error = discover_error
        # id ref'а (по 'external_id'), на котором enrich() бросит исключение —
        # проверка того, что одна дохлая карточка не топит остальные.
        self._enrich_error_on = enrich_error_on or set()

    def discover(self) -> list[dict]:
        if self._discover_error is not None:
            raise self._discover_error
        return self._refs

    def enrich(self, ref: dict) -> Observation | None:
        if ref["external_id"] in self._enrich_error_on:
            raise RuntimeError(f"карточка неразборчива: {ref['external_id']}")
        return Observation(
            source=self.name, external_id=ref["external_id"], name=ref.get("name", "ЖК"),
            city="Рязань", fetched_at="2026-09-07T00:00:00Z",
        )


class TestIsTransient(unittest.TestCase):
    def test_5xx_is_transient(self):
        self.assertTrue(is_transient(_http_error(503)))
        self.assertTrue(is_transient(_http_error(500)))

    def test_4xx_is_not_transient(self):
        # 422 — батч не по контракту / длиннее лимита, вина запроса, а не
        # временный сбой сервера. 401 — протухший токен, тоже не
        # самоисправится повтором того же запроса.
        self.assertFalse(is_transient(_http_error(422)))
        self.assertFalse(is_transient(_http_error(401)))

    def test_network_errors_are_transient(self):
        self.assertTrue(is_transient(requests.ConnectionError("reset")))
        self.assertTrue(is_transient(requests.Timeout("timed out")))

    def test_unrelated_exception_is_not_transient(self):
        self.assertFalse(is_transient(ValueError("boom")))


class TestSendWithRetry(unittest.TestCase):
    @patch("run.time.sleep")
    def test_5xx_is_retried_and_succeeds_on_second_attempt(self, mock_sleep):
        client = MagicMock()
        client.send.side_effect = [_http_error(503), [{"status": "created"}]]

        result = send_with_retry(client, [OBSERVATION], "erz")

        self.assertEqual(client.send.call_count, 2)
        self.assertEqual(result, [{"status": "created"}])
        mock_sleep.assert_called_once()

    def test_invalid_batch_4xx_is_not_retried(self):
        # 422 — "не примем этот батч", а не "попробуй ещё раз". Мутация
        # "ретраим вообще всё" ловится именно проверкой call_count == 1.
        client = MagicMock()
        client.send.side_effect = _http_error(422)

        with self.assertRaises(requests.HTTPError):
            send_with_retry(client, [OBSERVATION], "erz")

        self.assertEqual(client.send.call_count, 1)

    @patch("run.time.sleep")
    def test_persistent_5xx_gives_up_after_max_retries(self, mock_sleep):
        client = MagicMock()
        client.send.side_effect = _http_error(503)  # падает всегда

        with self.assertRaises(requests.HTTPError):
            send_with_retry(client, [OBSERVATION], "erz")

        # Первая попытка + MAX_SEND_RETRIES повторов, не бесконечно.
        self.assertEqual(client.send.call_count, MAX_SEND_RETRIES + 1)


class TestRunSourceIsolation(unittest.TestCase):
    def test_one_bad_card_does_not_lose_the_others_on_the_same_source(self):
        source = FakeSource(
            "erz",
            refs=[{"external_id": "erz:1"}, {"external_id": "erz:2"}, {"external_id": "erz:3"}],
            enrich_error_on={"erz:2"},
        )
        client = MagicMock()
        client.send.return_value = [{"status": "created"}] * 2

        sent = run_source(source, client)

        self.assertEqual(sent, 2)
        sent_ids = [o.external_id for o in client.send.call_args.args[0]]
        self.assertEqual(sent_ids, ["erz:1", "erz:3"])

    def test_empty_result_does_not_call_send(self):
        source = FakeSource("erz", refs=[])
        client = MagicMock()

        sent = run_source(source, client)

        self.assertEqual(sent, 0)
        client.send.assert_not_called()


class TestCrawlIsolation(unittest.TestCase):
    def test_one_source_failing_entirely_does_not_stop_the_other(self):
        broken = FakeSource("erz", discover_error=RuntimeError("сайт лёг"))
        healthy = FakeSource("developer_site", refs=[{"external_id": "edinstvo:1"}])
        client = MagicMock()
        client.send.return_value = [{"status": "created"}]

        counts = crawl([broken, healthy], client)

        self.assertEqual(counts, {"erz": 0, "developer_site": 1})
        # Второй источник обойдён ровно один раз — не пропущен и не задет
        # падением первого.
        client.send.assert_called_once()

    @patch("run.time.sleep")
    def test_source_failing_even_after_retries_is_isolated_too(self, mock_sleep):
        broken = FakeSource("erz", refs=[{"external_id": "erz:1"}])
        healthy = FakeSource("developer_site", refs=[{"external_id": "edinstvo:1"}])
        client = MagicMock()
        client.send.side_effect = [_http_error(503)] * (MAX_SEND_RETRIES + 1) + [
            [{"status": "created"}]
        ]

        counts = crawl([broken, healthy], client)

        self.assertEqual(counts, {"erz": 0, "developer_site": 1})


if __name__ == "__main__":
    unittest.main()
