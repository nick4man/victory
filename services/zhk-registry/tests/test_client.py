"""Клиент отправки наблюдений. Транспорт (`requests.post`) подменяется —
никакой сети и никакого похода к реальному Rails-серверу в этих тестах
быть не должно.

Запуск:
    cd services/zhk-registry && python3 -m unittest discover -v
"""

import json
import os
import unittest
from unittest.mock import MagicMock, patch

from client import MAX_BATCH, IngestClient
from observation import Observation

CONTRACT = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                        "spec", "fixtures", "zhk", "observation_example.json")


def _load_contract() -> dict:
    with open(CONTRACT, encoding="utf-8") as fh:
        return json.load(fh)


def _fake_response(result_count: int) -> MagicMock:
    response = MagicMock()
    response.raise_for_status.return_value = None
    response.json.return_value = {
        "results": [{"external_id": f"x{i}", "status": "created"} for i in range(result_count)]
    }
    return response


class TestIngestClientBatching(unittest.TestCase):
    def setUp(self):
        self.raw = _load_contract()

    def _observations(self, count: int) -> list[Observation]:
        observations = []
        for i in range(count):
            raw = dict(self.raw, external_id=f"erz:{i}")
            observations.append(Observation(**raw))
        return observations

    @patch("client.requests.post")
    def test_batch_of_120_splits_into_three_requests(self, mock_post):
        mock_post.side_effect = [_fake_response(50), _fake_response(50), _fake_response(20)]

        client = IngestClient("https://victory62.org", "secret-token")
        results = client.send(self._observations(120))

        # Мутация "режем по 60 вместо 50" не наблюдалась бы, если бы тест
        # проверял только call_count — поэтому проверяем ещё и размер
        # каждого отправленного батча.
        self.assertEqual(mock_post.call_count, 3)
        sent_sizes = [
            len(call.kwargs["json"]["observations"]) for call in mock_post.call_args_list
        ]
        self.assertEqual(sent_sizes, [MAX_BATCH, MAX_BATCH, 20])
        self.assertEqual(len(results), 120)

    @patch("client.requests.post")
    def test_batch_at_exact_limit_is_a_single_request(self, mock_post):
        # Граница: ровно MAX_BATCH не должно резаться на два запроса, один
        # из которых пустой — мутация "> вместо >=" в диапазоне даёт
        # именно это наблюдаемое расхождение.
        mock_post.side_effect = [_fake_response(MAX_BATCH)]

        client = IngestClient("https://victory62.org", "secret-token")
        client.send(self._observations(MAX_BATCH))

        self.assertEqual(mock_post.call_count, 1)

    @patch("client.requests.post")
    def test_token_is_sent_with_bearer_prefix(self, mock_post):
        mock_post.side_effect = [_fake_response(1)]

        client = IngestClient("https://victory62.org", "secret-token")
        client.send(self._observations(1))

        headers = mock_post.call_args.kwargs["headers"]
        # Голого значения токена недостаточно — сервер отвергает его без
        # префикса (см. zhk_ingest_controller_spec.rb, тест на 401 без
        # схемы). Мутация "забыли добавить 'Bearer '" ловится именно
        # проверкой равенства строки целиком, а не substring-проверкой.
        self.assertEqual(headers["Authorization"], "Bearer secret-token")

    @patch("client.requests.post")
    def test_observation_serializes_to_shared_contract_payload(self, mock_post):
        mock_post.side_effect = [_fake_response(1)]

        client = IngestClient("https://victory62.org", "secret-token")
        client.send([Observation(**self.raw)])

        sent_body = mock_post.call_args.kwargs["json"]
        self.assertEqual(sent_body, {"observations": [self.raw]})


if __name__ == "__main__":
    unittest.main()
