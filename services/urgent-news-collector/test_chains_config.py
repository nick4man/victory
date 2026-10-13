"""Тесты загрузчика chains.json: без сети и БД.

    python3 -m unittest test_chains_config -v

Загрузчик вызываем напрямую с явным путём (_load_chains_config(path)) —
без importlib.reload, который хрупок из-за модульных кэшей.
"""
from __future__ import annotations

import json
import os
import tempfile
import unittest

try:
    import pipeline_utils as p
except ModuleNotFoundError as e:  # pragma: no cover
    p = None
    SKIP_REASON = f"pipeline_utils не импортируется: {e}"
else:
    SKIP_REASON = ""


@unittest.skipIf(p is None, SKIP_REASON)
class TestChainsConfig(unittest.TestCase):
    def _write(self, data) -> str:
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data if isinstance(data, str) else json.dumps(data))
        self.addCleanup(os.unlink, path)
        return path

    def test_broken_json_falls_back_to_defaults(self):
        cfg = p._load_chains_config(self._write("{not json"))
        self.assertEqual(cfg["main"], p._DEFAULT_MAIN_CHAIN)
        self.assertEqual(cfg["free_classifier"], p._DEFAULT_FREE_CLASSIFIER_MODELS)
        self.assertEqual(cfg["paid"], p._DEFAULT_PAID_MODELS)

    def test_missing_file_falls_back_to_defaults(self):
        cfg = p._load_chains_config("/nonexistent-dir-9f3b/chains.json")
        self.assertEqual(cfg["main"], p._DEFAULT_MAIN_CHAIN)
        self.assertEqual(cfg["paid"], p._DEFAULT_PAID_MODELS)

    def test_custom_paid_flag_lands_in_paid_models(self):
        cfg = p._load_chains_config(self._write({
            "version": 1,
            "main": [
                {"provider": "google", "model": "gemini-2.5-flash", "timeout_s": 30},
                {"provider": "openrouter", "model": "some/paid-model",
                 "timeout_s": 45, "paid": True},
            ],
            "classifier_extra": [
                {"provider": "openrouter", "model": "x/y:free", "timeout_s": 30},
            ],
        }))
        self.assertIn(("openrouter", "some/paid-model"), cfg["paid"])
        self.assertNotIn(("google", "gemini-2.5-flash"), cfg["paid"])
        self.assertEqual(cfg["main"][-1], ("openrouter", "some/paid-model", 45))
        self.assertEqual(cfg["free_classifier"], [("openrouter", "x/y:free", 30)])

    def test_invalid_entries_are_skipped(self):
        cfg = p._load_chains_config(self._write({
            "version": 1,
            "main": [
                {"provider": "google", "model": "ok-model", "timeout_s": 30},
                {"provider": "google"},                                   # нет model
                {"model": "no-provider"},                                 # нет provider
                {"provider": "google", "model": "zero-timeout", "timeout_s": 0},
                {"provider": "google", "model": "str-timeout", "timeout_s": "30"},
                "просто строка",
            ],
            "classifier_extra": [],
        }))
        self.assertEqual(cfg["main"], [("google", "ok-model", 30)])

    def test_default_timeout_applied_when_omitted(self):
        cfg = p._load_chains_config(self._write({
            "version": 1,
            "main": [{"provider": "google", "model": "m1"}],
            "classifier_extra": [],
        }))
        self.assertEqual(cfg["main"], [("google", "m1", 30)])

    def test_empty_main_falls_back_to_defaults(self):
        cfg = p._load_chains_config(self._write({
            "version": 1,
            "main": [{"provider": "google"}],  # единственная запись невалидна
            "classifier_extra": [],
        }))
        self.assertEqual(cfg["main"], p._DEFAULT_MAIN_CHAIN)

    def test_paid_entry_in_classifier_extra_excluded_from_classifier(self):
        # Инвариант «в классификаторе платных нет» важнее конфига: такая
        # запись уходит в PAID_MODELS, но не в free_classifier.
        cfg = p._load_chains_config(self._write({
            "version": 1,
            "main": [{"provider": "google", "model": "m1", "timeout_s": 30}],
            "classifier_extra": [
                {"provider": "openrouter", "model": "sneaky/paid",
                 "timeout_s": 30, "paid": True},
                {"provider": "openrouter", "model": "x/y:free", "timeout_s": 30},
            ],
        }))
        self.assertIn(("openrouter", "sneaky/paid"), cfg["paid"])
        self.assertEqual(cfg["free_classifier"], [("openrouter", "x/y:free", 30)])

    def test_bundled_chains_json_matches_builtin_defaults(self):
        # chains.json, лежащий рядом с pipeline_utils.py и деплоящийся с кодом,
        # обязан точно повторять встроенные дефолты — иначе прод и тесты разъедутся.
        cfg = p._load_chains_config(p._bundled_chains_json_path())
        self.assertEqual(cfg["main"], p._DEFAULT_MAIN_CHAIN)
        self.assertEqual(cfg["free_classifier"], p._DEFAULT_FREE_CLASSIFIER_MODELS)
        self.assertEqual(cfg["paid"], p._DEFAULT_PAID_MODELS)


@unittest.skipIf(p is None, SKIP_REASON)
class TestChainsPathResolution(unittest.TestCase):
    """Порядок resolve_chains_json_path / resolve_chains_json_write_path (13.10.26).

    env читается в момент вызова — reload не нужен, достаточно подменить
    CONVEYOR_HOME/CHAINS_JSON_PATH и восстановить после теста.
    """

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in ("CONVEYOR_HOME", "CHAINS_JSON_PATH")}
        os.environ.pop("CONVEYOR_HOME", None)
        os.environ.pop("CHAINS_JSON_PATH", None)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(self._restore_env)
        self.home = self._tmp.name
        os.environ["CONVEYOR_HOME"] = self.home

    def _restore_env(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def _touch(self, *parts) -> str:
        path = os.path.join(self.home, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write("{}")
        return path

    def test_state_override_shadows_conveyor_and_bundled(self):
        state_cfg = self._touch("state", "chains.json")
        self._touch("chains.json")
        self.assertEqual(p.resolve_chains_json_path(), state_cfg)

    def test_conveyor_cfg_when_no_state_override(self):
        conveyor_cfg = self._touch("chains.json")
        self.assertEqual(p.resolve_chains_json_path(), conveyor_cfg)

    def test_bundled_when_conveyor_has_no_configs(self):
        self.assertEqual(p.resolve_chains_json_path(), p._bundled_chains_json_path())

    def test_write_path_is_state_volume_even_without_existing_override(self):
        # В docker бандленный chains.json лежит в слое образа — писать туда
        # бессмысленно (стирается rollout'ом), поэтому цель записи — state/.
        self.assertEqual(
            p.resolve_chains_json_write_path(),
            os.path.join(self.home, "state", "chains.json"),
        )

    def test_explicit_env_path_wins_for_read_and_write(self):
        explicit = self._touch("explicit.json")
        os.environ["CHAINS_JSON_PATH"] = explicit
        self.assertEqual(p.resolve_chains_json_path(), explicit)
        self.assertEqual(p.resolve_chains_json_write_path(), explicit)


if __name__ == "__main__":
    unittest.main()
