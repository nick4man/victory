"""Тесты чистой логики free_model_probe.py — без сети и БД.

    python3 -m unittest test_free_model_probe -v

Покрыто: эвристики брака генерации (латиница / выдуманные цифры / длина),
переходы probe_state (3 провала → disabled, 2 успеха → enabled) и обновление
chains.json (probe-записи добавляются/удаляются, ручные и платные не
трогаются, запись атомарна). Сетевые вызовы сюда не попадают — они за
complete_with_fallbacks, который тестируется отдельно.
"""
from __future__ import annotations

import json
import os
import tempfile
import unittest

import free_model_probe as probe
import pipeline_utils as p


FACTS = probe.GENERATION_FACTS  # внутри: 16%, 14,5%, 12,1%, 9 октября 2026


def _good_post() -> str:
    return (
        "<b>ЦБ снизил ключевую ставку до 14,5%</b>\n\n"
        "Банк России на заседании 9 октября 2026 года снизил ключевую ставку "
        "с 16% до 14,5% годовых. Это уже третье снижение подряд. Средняя ставка "
        "по рыночной ипотеке на новостройки составила 12,1%.\n\n"
        "Для покупателей премиум-сегмента это сигнал к пересмотру условий "
        "финансирования сделок в ближайшие месяцы."
    )


class TestGenerationDefects(unittest.TestCase):
    def test_clean_post_passes(self):
        self.assertEqual(probe.generation_defects(_good_post(), FACTS), [])

    def test_latin_mix_flagged(self):
        # История 13.09.26: nemotron мешал русский с английским.
        post = _good_post() + (
            " Analysts unanimously expect further easing of the monetary policy "
            "cycle across emerging markets next quarter."
        )
        defects = probe.generation_defects(post, FACTS)
        self.assertTrue(any(d.startswith("latin_mix:") for d in defects), defects)

    def test_hallucinated_numbers_flagged(self):
        # История 13.09.26: laguna придумывала «инфляция 4,3%, ВВП 0,8%».
        post = _good_post() + " Инфляция замедлилась до 4,3%, рост ВВП — 0,8%."
        defects = probe.generation_defects(post, FACTS)
        self.assertTrue(any(d.startswith("hallucinated_numbers:") for d in defects), defects)
        joined = " ".join(defects)
        self.assertIn("4.3", joined)
        self.assertIn("0.8", joined)

    def test_comma_and_dot_decimals_match(self):
        # «14,5» из фактуры и «14.5» в посте — одно число, не выдумка.
        post = _good_post().replace("14,5%", "14.5%")
        self.assertEqual(probe.generation_defects(post, FACTS), [])

    def test_hashtag_numbers_are_not_hallucinations(self):
        post = _good_post() + " #ипотека2026 #ставкаЦБ777"
        defects = probe.generation_defects(post, FACTS)
        self.assertFalse(any(d.startswith("hallucinated_numbers:") for d in defects), defects)

    def test_date_like_numbers_allowed(self):
        # День месяца и год модель вправе сформулировать сама.
        post = _good_post() + " Следующее заседание совета директоров — 20 ноября 2026 года."
        defects = probe.generation_defects(post, FACTS)
        self.assertFalse(any(d.startswith("hallucinated_numbers:") for d in defects), defects)

    def test_too_short_flagged(self):
        defects = probe.generation_defects("<b>ЦБ снизил ставку.</b>", FACTS)
        self.assertTrue(any(d.startswith("length_out_of_bounds:") for d in defects), defects)

    def test_too_long_flagged(self):
        post = _good_post() + " Слово " * 700  # явно за 1700 символов
        defects = probe.generation_defects(post, FACTS)
        self.assertTrue(any(d.startswith("length_out_of_bounds:") for d in defects), defects)

    def test_latin_ratio_below_threshold_passes(self):
        # Одно латинское слово в длинном тексте — не брак.
        post = _good_post() + " В материалах регулятора это названо soft landing."
        self.assertEqual(probe.generation_defects(post, FACTS), [])


class TestClassifyError(unittest.TestCase):
    def test_categories(self):
        self.assertEqual(probe.classify_error("HTTP 429: rate limit exceeded"), "rate_limit")
        self.assertEqual(probe.classify_error("HTTPSConnectionPool read timed out"), "timeout")
        self.assertEqual(probe.classify_error("SSLError: certificate verify failed"), "connection")
        self.assertEqual(probe.classify_error("missing relevance_tier in JSON"), "bad_json")
        self.assertEqual(probe.classify_error("HTTP 500: internal"), "other")


class TestStateTransitions(unittest.TestCase):
    def test_three_failures_disable(self):
        entry = None
        for _ in range(2):
            entry = probe.apply_probe_result(entry, success=False)
            self.assertFalse(entry["disabled"])
        entry = probe.apply_probe_result(entry, success=False)
        self.assertTrue(entry["disabled"])
        self.assertEqual(entry["consecutive_failures"], 3)

    def test_two_successes_reenable(self):
        entry = {"consecutive_failures": 5, "consecutive_successes": 0, "disabled": True}
        entry = probe.apply_probe_result(entry, success=True)
        self.assertTrue(entry["disabled"])  # одного успеха мало
        entry = probe.apply_probe_result(entry, success=True)
        self.assertFalse(entry["disabled"])
        self.assertEqual(entry["consecutive_failures"], 0)

    def test_success_resets_failure_streak(self):
        entry = {"consecutive_failures": 2, "consecutive_successes": 0, "disabled": False}
        entry = probe.apply_probe_result(entry, success=True)
        entry = probe.apply_probe_result(entry, success=False)
        self.assertEqual(entry["consecutive_failures"], 1)
        self.assertFalse(entry["disabled"])

    def test_failure_resets_success_streak(self):
        entry = {"consecutive_failures": 0, "consecutive_successes": 1, "disabled": True}
        entry = probe.apply_probe_result(entry, success=False)
        self.assertEqual(entry["consecutive_successes"], 0)
        self.assertTrue(entry["disabled"])


def _chains_raw() -> dict:
    return {
        "version": 1,
        "main": [
            {"provider": "google", "model": "gemini-2.5-flash", "timeout_s": 30},
            {"provider": "openrouter", "model": "probe/old-model:free",
             "timeout_s": 30, "added_by": "probe"},
            {"provider": "openrouter", "model": "anthropic/claude-sonnet-4",
             "timeout_s": 60, "paid": True},
        ],
        "classifier_extra": [
            {"provider": "openrouter", "model": "manual/clf:free", "timeout_s": 30},
        ],
    }


class TestUpdateChainsConfig(unittest.TestCase):
    def test_classifier_candidate_added_with_probe_mark(self):
        new, changes = probe.update_chains_config(
            _chains_raw(),
            add_classifier=[("openrouter", "new/clf:free", 30)],
            add_main=[],
            disabled_keys=set(),
        )
        extra = new["classifier_extra"]
        self.assertEqual(len(extra), 2)
        added = extra[-1]
        self.assertEqual(added["model"], "new/clf:free")
        self.assertEqual(added["added_by"], "probe")
        self.assertNotIn("paid", added)
        self.assertTrue(any("new/clf" in c for c in changes))

    def test_both_candidate_inserted_before_first_paid(self):
        new, _ = probe.update_chains_config(
            _chains_raw(),
            add_classifier=[],
            add_main=[("openrouter", "new/big:free", 45)],
            disabled_keys=set(),
        )
        main = new["main"]
        idx_new = next(i for i, it in enumerate(main) if it["model"] == "new/big:free")
        idx_paid = next(i for i, it in enumerate(main) if it.get("paid"))
        self.assertLess(idx_new, idx_paid)
        entry = main[idx_new]
        self.assertEqual(entry["added_by"], "probe")
        self.assertNotIn("paid", entry)

    def test_disabled_probe_entry_removed_but_manual_kept(self):
        raw = _chains_raw()
        raw["main"][0]["added_by"] = "manual"  # ручная запись той же «мёртвой» модели
        disabled = {"openrouter/probe/old-model:free", "google/gemini-2.5-flash"}
        new, changes = probe.update_chains_config(
            raw, add_classifier=[], add_main=[], disabled_keys=disabled,
        )
        models = [it["model"] for it in new["main"]]
        self.assertNotIn("probe/old-model:free", models)      # probe-запись убрана
        self.assertIn("gemini-2.5-flash", models)             # ручная — на месте
        self.assertIn("anthropic/claude-sonnet-4", models)    # платная — на месте
        self.assertTrue(any("old-model" in c for c in changes))

    def test_paid_entry_never_removed_even_if_probe_marked(self):
        # Патологический конфиг: paid + added_by="probe". Удалять нельзя.
        raw = _chains_raw()
        raw["main"][-1]["added_by"] = "probe"
        disabled = {"openrouter/anthropic/claude-sonnet-4"}
        new, _ = probe.update_chains_config(
            raw, add_classifier=[], add_main=[], disabled_keys=disabled,
        )
        self.assertIn("anthropic/claude-sonnet-4", [it["model"] for it in new["main"]])

    def test_no_duplicate_additions(self):
        raw = _chains_raw()
        new, changes = probe.update_chains_config(
            raw,
            add_classifier=[("openrouter", "manual/clf:free", 30)],  # уже есть
            add_main=[("google", "gemini-2.5-flash", 30)],           # уже есть
            disabled_keys=set(),
        )
        self.assertEqual(len(new["classifier_extra"]), 1)
        self.assertEqual(len(new["main"]), 3)
        self.assertEqual(changes, [])

    def test_disabled_candidate_not_added(self):
        new, _ = probe.update_chains_config(
            _chains_raw(),
            add_classifier=[("openrouter", "dead/clf:free", 30)],
            add_main=[],
            disabled_keys={"openrouter/dead/clf:free"},
        )
        self.assertEqual(len(new["classifier_extra"]), 1)

    def test_loader_tolerates_probe_fields(self):
        # Записи с added_by не должны ломать _load_chains_config.
        new, _ = probe.update_chains_config(
            _chains_raw(),
            add_classifier=[("openrouter", "new/clf:free", 30)],
            add_main=[("openrouter", "new/big:free", 45)],
            disabled_keys=set(),
        )
        fd, path = tempfile.mkstemp(suffix=".json")
        self.addCleanup(os.unlink, path)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(new, f)
        cfg = p._load_chains_config(path)
        self.assertIn(("openrouter", "new/clf:free", 30), cfg["free_classifier"])
        self.assertIn(("openrouter", "new/big:free", 45), cfg["main"])
        # paid-инвариант не пострадал.
        self.assertIn(("openrouter", "anthropic/claude-sonnet-4"), cfg["paid"])


class TestAtomicWrite(unittest.TestCase):
    def test_write_json_atomic_roundtrip_and_no_tmp(self):
        dirpath = tempfile.mkdtemp()
        path = os.path.join(dirpath, "chains.json")
        probe.write_json_atomic(path, {"version": 1, "main": [], "classifier_extra": []})
        with open(path, encoding="utf-8") as f:
            self.assertEqual(json.load(f)["version"], 1)
        self.assertFalse(os.path.exists(path + ".tmp"))
        # Перезапись тем же путём — атомарна и не оставляет мусора.
        probe.write_json_atomic(path, {"version": 2})
        with open(path, encoding="utf-8") as f:
            self.assertEqual(json.load(f)["version"], 2)
        self.assertEqual(sorted(os.listdir(dirpath)), ["chains.json"])


class TestMergeProbeList(unittest.TestCase):
    def test_dedup_prefers_candidate_role(self):
        candidates = [{"provider": "openrouter", "model": "x/y:free",
                       "timeout_s": 45, "role": "both", "origin": "candidate"}]
        current = [{"provider": "openrouter", "model": "x/y:free",
                    "timeout_s": 30, "role": "classifier", "origin": "chains:main"},
                   {"provider": "google", "model": "gemini", "timeout_s": 30,
                    "role": "both", "origin": "chains:main"}]
        merged = probe.merge_probe_list(candidates, current)
        self.assertEqual(len(merged), 2)
        xy = next(m for m in merged if m["model"] == "x/y:free")
        self.assertEqual(xy["role"], "both")
        self.assertEqual(xy["origin"], "candidate")


class TestLoadClassifierPrompt(unittest.TestCase):
    def test_extracts_real_prompt_from_urgent_collector(self):
        prompt = probe.load_classifier_prompt()
        # Признаки боевого промпта, а не запасного: таксономия и формат-поля.
        self.assertIn("CAPITAL_CONTROL", prompt)
        self.assertIn("{headline}", prompt)
        self.assertIn("{summary}", prompt)
        self.assertIn("{source_name}", prompt)


if __name__ == "__main__":
    unittest.main()
