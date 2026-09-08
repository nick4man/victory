"""Контракт наблюдения. Образец общий с Rails — если тест упал после правки
образца, значит контракт разъехался, и чинить надо обе стороны сразу.

Запуск:
    cd services/zhk-registry && python3 -m unittest discover -v
"""

import json
import os
import unittest

from observation import Observation

CONTRACT = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                        "spec", "fixtures", "zhk", "observation_example.json")


class TestObservationContract(unittest.TestCase):
    def test_parses_shared_contract_fixture(self):
        with open(CONTRACT, encoding="utf-8") as fh:
            raw = json.load(fh)

        obs = Observation(**raw)

        self.assertEqual(obs.source, "erz")
        self.assertEqual(obs.name, "Скобелев")
        self.assertEqual(obs.fields["developer"], "Единство")
        self.assertEqual(obs.price.price_per_sqm, 65000)

    def test_roundtrip_keeps_shape(self):
        with open(CONTRACT, encoding="utf-8") as fh:
            raw = json.load(fh)

        self.assertEqual(Observation(**raw).to_payload(), raw)

    def test_rejects_observation_without_source(self):
        from pydantic import ValidationError

        with self.assertRaises(ValidationError):
            Observation(external_id="x", name="Скобелев", city="Рязань",
                        fetched_at="2026-09-07T05:00:00Z", fields={})


if __name__ == "__main__":
    unittest.main()
