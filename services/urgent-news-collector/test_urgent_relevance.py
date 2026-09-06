"""Тесты гейта релевантности.

Запуск:
    IT/venv/bin/python3 -m unittest test_urgent_relevance -v

Все заголовки — реальные, из выборки опубликованного за 30 дней до
2026-08-08. pytest в боевой venv не ставим, поэтому stdlib unittest.
"""

import unittest

from urgent_relevance import gate_urgent, is_equity_noise, is_fx_noise, is_non_event


class TestPasses(unittest.TestCase):
    """То, ради чего конвейер существует, — должно проходить."""

    def test_key_rate_decision_passes(self):
        ok, reason = gate_urgent("KEY_RATE", "Банк России снизил ключевую ставку до 14% вопреки ожиданиям рынка")
        self.assertTrue(ok, reason)

    def test_housing_law_passes(self):
        ok, reason = gate_urgent("LAW_UPDATE", "СФ одобрил закон о возмещении за жилье при комплексном развитии территорий")
        self.assertTrue(ok, reason)

    def test_property_tax_passes(self):
        ok, reason = gate_urgent("TAX_CHANGE", "ФНС начала спрашивать безработных об источниках денег на квартиры и яхты")
        self.assertTrue(ok, reason)

    def test_mortgage_policy_passes(self):
        ok, reason = gate_urgent("MORTGAGE_POLICY", "Минфин ужесточил условия семейной ипотеки")
        self.assertTrue(ok, reason)

    def test_capital_control_passes(self):
        ok, reason = gate_urgent("CAPITAL_CONTROL", "В ЕС предложили забрать замороженные активы России у Euroclear")
        self.assertTrue(ok, reason)


class TestFxNoise(unittest.TestCase):
    """Курс валют — главный источник ложных СРОЧНО (5 постов из 45 в выборке)."""

    FX_HEADLINES = [
        "ЦБ поднял курс доллара выше 81 рубля",
        "Банк России поднял официальный курс доллара выше 81 рубля",
        "ЦБ опустил курс доллара и евро, но поднял – юаня",
        "ЦБ поднял курс доллара до 80 рублей",
        "ЦБ поднял курс доллара выше 79 рублей впервые с начала апреля",
    ]

    def test_detected_as_fx(self):
        for headline in self.FX_HEADLINES:
            with self.subTest(headline=headline):
                self.assertTrue(is_fx_noise(headline))

    def test_blocked_even_when_misclassified_as_key_rate(self):
        # Ровно этот случай и наблюдался: курс приезжал под типом ставки.
        for headline in self.FX_HEADLINES:
            with self.subTest(headline=headline):
                ok, reason = gate_urgent("KEY_RATE", headline)
                self.assertFalse(ok)
                self.assertEqual(reason, "fx_rate_noise")

    def test_key_rate_is_not_fx(self):
        self.assertFalse(is_fx_noise("Банк России снизил ключевую ставку до 14%"))


class TestEquityNoise(unittest.TestCase):
    """Биржевые сюжеты. В бэктесте приезжали под типом KEY_RATE."""

    EQUITY_HEADLINES = [
        "Рынок акций РФ завершил неделю ростом впервые после 19 недель снижения",
        "Индекс Мосбиржи упал ниже 2100 пунктов в преддверии решения ЦБ по ставке",
        "Индексы МосБиржи и РТС открыли основную сессию снижением на 1,8%",
        "Ключевая ставка ЦБ, рынок акций и дивиденды «Русагро»",
    ]

    def test_detected(self):
        for headline in self.EQUITY_HEADLINES:
            with self.subTest(headline=headline):
                self.assertTrue(is_equity_noise(headline))

    def test_blocked_even_when_misclassified_as_key_rate(self):
        ok, reason = gate_urgent("KEY_RATE", self.EQUITY_HEADLINES[0])
        self.assertFalse(ok)
        self.assertEqual(reason, "equity_market_noise")

    def test_key_rate_decision_is_not_equity(self):
        # «вопреки ожиданиям рынка» не должно ловиться как «рынок акций».
        self.assertFalse(is_equity_noise("Банк России снизил ключевую ставку до 14% вопреки ожиданиям рынка"))

    def test_housing_headline_is_not_equity(self):
        self.assertFalse(is_equity_noise("СФ одобрил закон о возмещении за жилье при КРТ"))


class TestNonEvents(unittest.TestCase):
    """Реквизиты документов и сводки — не события."""

    def test_cbr_document_citation(self):
        self.assertEqual(is_non_event("Указание Банка России от 22.06.2026 № 7373-У"), "cbr_document_citation")

    def test_cbr_bulletin(self):
        self.assertEqual(is_non_event("«Вестник Банка России» № 24 (2613) от 29 июля 2026 года"), "cbr_bulletin")

    def test_draft_regulation_index(self):
        self.assertEqual(is_non_event("Проекты нормативных документов Банка России для публичного обсуждения"),
                         "draft_regulation_index")

    def test_daily_roundup(self):
        self.assertEqual(is_non_event("Что произошло за день: четверг, 23 июля"), "daily_roundup")

    def test_digest_roundup(self):
        self.assertEqual(is_non_event("Ключевая ставка ЦБ, рынок акций и дивиденды «Русагро»: дайджест"),
                         "roundup_digest")

    def test_substantive_law_is_not_non_event(self):
        self.assertIsNone(is_non_event("Принят закон о справедливой компенсации за жилье, выкупаемое под проекты КРТ"))

    def test_blocked_by_gate(self):
        ok, reason = gate_urgent("LAW_UPDATE", "Указание Банка России от 22.06.2026 № 7373-У")
        self.assertFalse(ok)
        self.assertEqual(reason, "non_event:cbr_document_citation")


class TestIneligibleTypes(unittest.TestCase):
    def test_macro_economics_blocked(self):
        ok, reason = gate_urgent("MACRO_ECONOMICS", "Иран нанес удар по базе Пятого флота ВМС США в Бахрейне")
        self.assertFalse(ok)
        self.assertEqual(reason, "ineligible_type:MACRO_ECONOMICS")

    def test_fx_rate_type_blocked(self):
        ok, reason = gate_urgent("FX_RATE", "ЦБ поднял курс доллара выше 81 рубля")
        self.assertFalse(ok)
        self.assertEqual(reason, "ineligible_type:FX_RATE")

    def test_legacy_rate_change_blocked(self):
        # Старые строки в БД. Гейт обязан их резать — на этом держится
        # разовая миграция 89 необработанных URGENT-строк.
        ok, reason = gate_urgent("RATE_CHANGE", "Банк России снизил ключевую ставку до 14%")
        self.assertFalse(ok)
        self.assertEqual(reason, "unknown_event_type")


class TestDegenerateInput(unittest.TestCase):
    def test_empty_headline(self):
        self.assertEqual(gate_urgent("KEY_RATE", ""), (False, "empty_headline"))

    def test_none_headline(self):
        self.assertEqual(gate_urgent("KEY_RATE", None), (False, "empty_headline"))

    def test_none_event_type(self):
        ok, reason = gate_urgent(None, "Банк России снизил ключевую ставку")
        self.assertFalse(ok)
        self.assertEqual(reason, "unknown_event_type")

    def test_type_is_case_insensitive(self):
        ok, _ = gate_urgent("key_rate", "Банк России снизил ключевую ставку до 14%")
        self.assertTrue(ok)


if __name__ == "__main__":
    unittest.main()
