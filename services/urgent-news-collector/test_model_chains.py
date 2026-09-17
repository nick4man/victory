"""Инварианты цепочек моделей: без сети и БД.

    python3 -m unittest test_model_chains -v

pipeline_utils тянет requests; без него тесты пропускаются, а не падают.
"""
from __future__ import annotations

import unittest

try:
    import pipeline_utils as p
except ModuleNotFoundError as e:  # pragma: no cover
    p = None
    SKIP_REASON = f"pipeline_utils не импортируется: {e}"
else:
    SKIP_REASON = ""


@unittest.skipIf(p is None, SKIP_REASON)
class TestChains(unittest.TestCase):
    def test_paid_model_is_last_everywhere(self):
        for chain in (p.MAIN_MODEL_CHAIN, p.CLASSIFIER_CHAIN):
            paid = [i for i, (prov, model, _) in enumerate(chain) if (prov, model) in p.PAID_MODELS]
            self.assertEqual(paid, [len(chain) - 1])

    def test_free_classifier_models_never_write_posts(self):
        main = {(prov, model) for prov, model, _ in p.MAIN_MODEL_CHAIN}
        for prov, model, _ in p.FREE_CLASSIFIER_MODELS:
            self.assertNotIn((prov, model), main)

    def test_free_classifier_models_are_free(self):
        for prov, model, _ in p.FREE_CLASSIFIER_MODELS:
            self.assertTrue(model.endswith(":free"), model)
            self.assertNotIn((prov, model), p.PAID_MODELS)

    def test_classifier_chain_keeps_every_main_step(self):
        classifier = [step for step in p.CLASSIFIER_CHAIN if step not in p.FREE_CLASSIFIER_MODELS]
        self.assertEqual(classifier, p.MAIN_MODEL_CHAIN)

    def test_google_goes_first_in_classifier(self):
        n = sum(1 for step in p.MAIN_MODEL_CHAIN if step[0] == "google")
        self.assertTrue(all(step[0] == "google" for step in p.CLASSIFIER_CHAIN[:n]))
        self.assertEqual(p.CLASSIFIER_CHAIN[n:n + len(p.FREE_CLASSIFIER_MODELS)], p.FREE_CLASSIFIER_MODELS)


if __name__ == "__main__":
    unittest.main()
