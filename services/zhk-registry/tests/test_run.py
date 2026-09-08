"""Оркестратор (`run.py`): изоляция источников, ретрай транзиентных
сбоев, вычитание `invalid` из count и доставка сводки. Транспорт
(`client.send`, `requests.post`) везде подменяется — сеть в этих тестах
не участвует.

Запуск:
    cd services/zhk-registry && python3 -m unittest discover -v
"""

import os
import unittest
from unittest.mock import MagicMock, patch

import requests

from observation import Observation
from run import (
    MAX_RETRIES,
    crawl,
    is_transient,
    main,
    post_summary,
    run_source,
    send_with_retry,
)

OBSERVATION = Observation(
    source="test", external_id="test:1", name="Тест", city="Рязань",
    fetched_at="2026-09-07T00:00:00Z",
)


def _http_error(status_code: int) -> requests.HTTPError:
    response = MagicMock()
    response.status_code = status_code
    return requests.HTTPError(f"{status_code} error", response=response)


def _summary_response(delivered: bool) -> MagicMock:
    response = MagicMock()
    response.raise_for_status.return_value = None
    response.json.return_value = {"status": "ok", "delivered": delivered}
    return response


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

        # Первая попытка + MAX_RETRIES повторов, не бесконечно.
        self.assertEqual(client.send.call_count, MAX_RETRIES + 1)

    @patch("run.time.sleep")
    def test_retry_resends_the_full_list_not_a_partial_tail(self, mock_sleep):
        # Мутация "на повторе шлём только необработанный хвост"
        # (например observations[1:]) должна быть поймана: обе попытки
        # обязаны получить ВЕСЬ список — см. докстринг send_with_retry
        # про восстановление точного count через полный повтор.
        observations = [OBSERVATION, OBSERVATION, OBSERVATION]
        client = MagicMock()
        client.send.side_effect = [_http_error(503), [{"status": "created"}] * 3]

        send_with_retry(client, observations, "erz")

        first_call_list = client.send.call_args_list[0].args[0]
        second_call_list = client.send.call_args_list[1].args[0]
        self.assertEqual(len(first_call_list), 3)
        self.assertEqual(len(second_call_list), 3)
        self.assertIs(second_call_list, observations)


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

    def test_invalid_rows_are_not_counted_as_applied(self):
        # Сервер вправе отвергнуть часть (или весь) батч как invalid,
        # оставаясь в HTTP 200 — count обязан отражать РЕАЛЬНО применённые
        # строки, а не количество отправленных (круг правок 1, находка
        # ревью). Мутация "count = len(observations)" ловится этим тестом.
        source = FakeSource(
            "erz", refs=[{"external_id": "erz:1"}, {"external_id": "erz:2"}, {"external_id": "erz:3"}],
        )
        client = MagicMock()
        client.send.return_value = [
            {"status": "created"}, {"status": "invalid"}, {"status": "duplicate"},
        ]

        applied = run_source(source, client)

        self.assertEqual(applied, 2)

    def test_all_invalid_batch_counts_as_zero_not_as_sent(self):
        source = FakeSource("erz", refs=[{"external_id": "erz:1"}, {"external_id": "erz:2"}])
        client = MagicMock()
        client.send.return_value = [{"status": "invalid"}, {"status": "invalid"}]

        applied = run_source(source, client)

        self.assertEqual(applied, 0)

    @patch("run.time.sleep")
    def test_discover_5xx_is_retried(self, mock_sleep):
        source = FakeSource("erz", refs=[{"external_id": "erz:1"}])
        source.discover = MagicMock(side_effect=[_http_error(503), source._refs])
        client = MagicMock()
        client.send.return_value = [{"status": "created"}]

        applied = run_source(source, client)

        self.assertEqual(applied, 1)
        self.assertEqual(source.discover.call_count, 2)


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
        client.send.side_effect = [_http_error(503)] * (MAX_RETRIES + 1) + [
            [{"status": "created"}]
        ]

        counts = crawl([broken, healthy], client)

        self.assertEqual(counts, {"erz": 0, "developer_site": 1})


class TestPostSummary(unittest.TestCase):
    @patch("run.requests.post")
    def test_delivered_true_returns_true(self, mock_post):
        mock_post.return_value = _summary_response(delivered=True)

        self.assertTrue(post_summary("https://victory62.org", "token", {"erz": 3}))

    @patch("run.requests.post")
    def test_delivered_false_returns_false(self, mock_post):
        # Сервер принял запрос (HTTP 200), но НЕ доставил в Telegram
        # (например TELEGRAM_STAFF_CHAT_ID не настроен) — мутация
        # "return True всегда, раз HTTP ок" ловится этим тестом.
        mock_post.return_value = _summary_response(delivered=False)

        self.assertFalse(post_summary("https://victory62.org", "token", {"erz": 3}))

    @patch("run.time.sleep")
    @patch("run.requests.post")
    def test_5xx_is_retried_and_eventually_delivered(self, mock_post, mock_sleep):
        bad_response = MagicMock()
        bad_response.raise_for_status.side_effect = _http_error(503)
        mock_post.side_effect = [bad_response, _summary_response(delivered=True)]

        self.assertTrue(post_summary("https://victory62.org", "token", {"erz": 3}))
        self.assertEqual(mock_post.call_count, 2)

    @patch("run.time.sleep")
    @patch("run.requests.post")
    def test_persistent_failure_returns_false_not_raises(self, mock_post, mock_sleep):
        bad_response = MagicMock()
        bad_response.raise_for_status.side_effect = _http_error(503)
        mock_post.return_value = bad_response

        # Не должно поднимать исключение наружу — main() читает возврат,
        # а не ловит исключение из post_summary.
        self.assertFalse(post_summary("https://victory62.org", "token", {"erz": 3}))
        self.assertEqual(mock_post.call_count, MAX_RETRIES + 1)


class TestMainExitCode(unittest.TestCase):
    def setUp(self):
        self._env_patch = patch.dict(
            os.environ, {"VICTORY_BASE_URL": "https://victory62.org", "ZHK_INGEST_TOKEN": "t"},
        )
        self._env_patch.start()
        self.addCleanup(self._env_patch.stop)

    @patch("run.post_summary")
    @patch("run.crawl")
    def test_exit_code_zero_when_summary_delivered(self, mock_crawl, mock_post_summary):
        mock_crawl.return_value = {"erz": 3}
        mock_post_summary.return_value = True

        self.assertEqual(main(), 0)

    @patch("run.post_summary")
    @patch("run.crawl")
    def test_exit_code_nonzero_when_summary_not_delivered(self, mock_crawl, mock_post_summary):
        # Полный отказ сводки — единственный внешний сигнал о том, что
        # тревога о молчащем источнике никуда не дошла (см. докстринг
        # модуля, пункт 4). Мутация "return 0 всегда" должна быть поймана.
        mock_crawl.return_value = {"erz": 0}
        mock_post_summary.return_value = False

        self.assertNotEqual(main(), 0)

    @patch("run.post_summary")
    @patch("run.crawl")
    def test_summary_is_posted_even_when_a_source_failed(self, mock_crawl, mock_post_summary):
        # Мутация "сводка не отправляется вовсе" (пропуск вызова
        # post_summary) должна быть поймана — раньше в этом файле не было
        # ни одного теста, который бы это заметил (находка ревью).
        mock_crawl.return_value = {"erz": 0, "developer_site": 5}
        mock_post_summary.return_value = True

        main()

        mock_post_summary.assert_called_once()
        self.assertEqual(mock_post_summary.call_args.args[2], {"erz": 0, "developer_site": 5})


if __name__ == "__main__":
    unittest.main()
