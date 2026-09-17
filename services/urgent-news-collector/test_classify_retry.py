"""Тесты classify_retry: без сети и БД, системным python3.

    python3 -m unittest test_classify_retry -v
"""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta

from classify_retry import ChainBreaker, RetryLedger, retry_key

T0 = datetime(2026, 9, 13, 1, 0, 0)


class TestRetryKey(unittest.TestCase):
    def test_url_wins(self):
        self.assertEqual(retry_key("https://x/1", "Заголовок"), "https://x/1")

    def test_headline_without_url(self):
        self.assertEqual(retry_key(None, "Заголовок"), "headline:Заголовок")


class TestRetryLedger(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "state", "pending.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_first_failure_waits(self):
        ledger = RetryLedger(self.path).load()
        self.assertFalse(ledger.record_failure("k", T0))
        self.assertEqual(ledger.pending(), 1)

    def test_keeps_waiting_inside_window(self):
        ledger = RetryLedger(self.path).load()
        ledger.record_failure("k", T0)
        self.assertFalse(ledger.record_failure("k", T0 + timedelta(hours=5, minutes=59)))

    def test_gives_up_after_window(self):
        ledger = RetryLedger(self.path).load()
        ledger.record_failure("k", T0)
        self.assertTrue(ledger.record_failure("k", T0 + timedelta(hours=6)))

    def test_repeated_failures_do_not_reset_first_time(self):
        ledger = RetryLedger(self.path).load()
        for h in range(6):
            ledger.record_failure("k", T0 + timedelta(hours=h))
        self.assertTrue(ledger.record_failure("k", T0 + timedelta(hours=6)))

    def test_forget_on_success(self):
        ledger = RetryLedger(self.path).load()
        ledger.record_failure("k", T0)
        ledger.forget("k")
        self.assertEqual(ledger.pending(), 0)
        self.assertFalse(ledger.record_failure("k", T0 + timedelta(hours=7)))

    def test_survives_between_runs(self):
        first = RetryLedger(self.path).load()
        first.record_failure("k", T0)
        first.save()
        second = RetryLedger(self.path).load()
        self.assertTrue(second.record_failure("k", T0 + timedelta(hours=6)))

    def test_missing_file_is_empty(self):
        self.assertEqual(RetryLedger(self.path).load().pending(), 0)

    def test_corrupt_file_does_not_raise(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("{не json")
        ledger = RetryLedger(self.path).load()
        self.assertEqual(ledger.pending(), 0)
        ledger.save()
        with open(self.path, encoding="utf-8") as fh:
            self.assertEqual(json.load(fh), {})

    def test_save_without_changes_writes_nothing(self):
        RetryLedger(self.path).load().save()
        self.assertFalse(os.path.exists(self.path))

    def test_prune_drops_old_entries(self):
        ledger = RetryLedger(self.path).load()
        ledger.record_failure("old", T0)
        ledger.record_failure("fresh", T0 + timedelta(days=3))
        ledger.prune(T0 + timedelta(days=3, hours=1))
        self.assertEqual(ledger.pending(), 1)
        self.assertFalse(ledger.record_failure("old", T0 + timedelta(days=3, hours=1)))


class TestChainBreaker(unittest.TestCase):
    def test_single_failure_does_not_trip(self):
        breaker = ChainBreaker()
        breaker.failure()
        self.assertFalse(breaker.tripped)

    def test_two_in_a_row_trip(self):
        breaker = ChainBreaker()
        breaker.failure()
        breaker.failure()
        self.assertTrue(breaker.tripped)

    def test_success_resets(self):
        breaker = ChainBreaker()
        breaker.failure()
        breaker.success()
        breaker.failure()
        self.assertFalse(breaker.tripped)


if __name__ == "__main__":
    unittest.main()
