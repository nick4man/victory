"""Tests for EI Calculator (ported from v1.0)."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.models import AuditInput
from audit_engine.ei_calculator import (
    calculate_monthly_payment,
    calculate_mortgage_scenario,
    calculate_cash_scenario,
    calculate_deposit_scenario,
    determine_verdict,
)
from audit_engine.scenario_builder import run_full_audit


def make_test_input() -> AuditInput:
    return AuditInput(
        complex_name="Тестовый ЖК",
        apartment_type="2BR",
        area_sqm=65.0,
        price_total=12_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        mortgage_term_years=20,
        down_payment_pct=20.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
        cash_discount_pct=10.0,
    )


def test_monthly_payment():
    """Annuity payment calculation."""
    # Known values: 10M at 12% for 20 years
    payment = calculate_monthly_payment(10_000_000, 12.0, 20)
    assert 100_000 < payment < 130_000, f"Payment {payment} out of expected range"


def test_monthly_payment_zero_rate():
    """Zero rate should divide evenly."""
    payment = calculate_monthly_payment(12_000_000, 0, 20)
    assert payment == 50_000


def test_mortgage_scenario():
    """Mortgage EI should be positive."""
    inp = make_test_input()
    result = calculate_mortgage_scenario(inp)
    assert result.ei > 0
    assert result.down_payment > 0
    assert result.loan_amount > 0
    assert result.monthly_payment > 0
    assert result.total_payments > result.loan_amount  # Overpayment exists


def test_cash_scenario():
    """Cash EI should be positive."""
    inp = make_test_input()
    result = calculate_cash_scenario(inp)
    assert result.ei > 0
    assert result.price_with_discount < inp.price_total
    assert result.discount_amount > 0


def test_deposit_scenario():
    """Deposit EI should be positive."""
    inp = make_test_input()
    result = calculate_deposit_scenario(inp)
    assert result.ei > 0
    assert result.capital_after_horizon > inp.price_total  # Deposit grows


def test_verdict():
    """Verdict should be one of BUY/WAIT/NEUTRAL."""
    from audit_engine.models import Verdict
    v, explanation = determine_verdict(1.5, 0.8, 1.0)
    assert v == Verdict.BUY
    assert len(explanation) > 0


def test_full_audit():
    """Full audit should produce 3 scenarios and valid result."""
    inp = make_test_input()
    result = run_full_audit(inp, inflation=5.9)

    assert len(result.scenarios) == 3
    assert result.verdict in ("BUY", "WAIT", "NEUTRAL")
    assert len(result.sensitivity_table) > 0
    assert len(result.risks) >= 0
    assert len(result.assumptions) > 0

    # Check scenario names
    names = [s.scenario_name for s in result.scenarios]
    assert "Оптимистичный" in names
    assert "Реалистичный" in names
    assert "Пессимистичный" in names


if __name__ == "__main__":
    test_monthly_payment()
    print("✅ test_monthly_payment passed")

    test_monthly_payment_zero_rate()
    print("✅ test_monthly_payment_zero_rate passed")

    test_mortgage_scenario()
    print("✅ test_mortgage_scenario passed")

    test_cash_scenario()
    print("✅ test_cash_scenario passed")

    test_deposit_scenario()
    print("✅ test_deposit_scenario passed")

    test_verdict()
    print("✅ test_verdict passed")

    test_full_audit()
    print("✅ test_full_audit passed")

    print("\n🎉 All EI Calculator tests passed!")
