"""EI для APARTMENT — делегирует существующему `ei_calculator`."""
from __future__ import annotations

from audit_engine.ei_calculator import (
    calculate_cash_scenario,
    calculate_deposit_scenario,
    calculate_mortgage_scenario,
)
from audit_engine.models import AuditInput, CashDetails, DepositDetails, MortgageDetails


def calculate_apartment_ei(inp: AuditInput) -> dict:
    """Квартирный сценарий: 3 стратегии + best.

    Возвращает dict с ключами `mortgage`, `cash`, `deposit`, `best_strategy`,
    `ei` (EI лучшей стратегии) — единообразно с другими типами.
    """
    mortgage: MortgageDetails = calculate_mortgage_scenario(inp)
    cash: CashDetails = calculate_cash_scenario(inp)
    deposit: DepositDetails = calculate_deposit_scenario(inp)

    eis = {"mortgage": mortgage.ei, "cash": cash.ei, "deposit": deposit.ei}
    best = max(eis, key=eis.get)

    return {
        "property_type": "APARTMENT",
        "mortgage": mortgage,
        "cash": cash,
        "deposit": deposit,
        "best_strategy": best,
        "ei": eis[best],
    }
