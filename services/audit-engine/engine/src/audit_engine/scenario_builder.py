"""
Scenario Builder — Генератор 3 сценариев прогнозирования.

Создает матрицу 3×3: (optimistic, realistic, pessimistic) × (cash, deposit, mortgage).
"""

from __future__ import annotations
from datetime import date

from audit_engine.models import (
    AuditInput,
    AuditResult,
    ScenarioParams,
    ScenarioResult,
    Verdict,
)
from audit_engine.ei_calculator import (
    calculate_mortgage_scenario,
    calculate_cash_scenario,
    calculate_deposit_scenario,
    determine_verdict,
    identify_risks,
    list_assumptions,
)


def build_scenario_params(
    base_input: AuditInput,
    inflation: float = 8.0,
) -> list[ScenarioParams]:
    """
    Генерирует 3 набора параметров на основе базовых входных данных.
    
    Args:
        base_input: Базовые параметры аудита (реалистичный сценарий).
        inflation: Текущая инфляция (% годовых).
    
    Returns:
        Список из 3 ScenarioParams.
    """
    return [
        ScenarioParams(
            name="Оптимистичный",
            price_growth_annual=base_input.price_growth_annual * 1.5,
            mortgage_rate=base_input.mortgage_rate * 0.8,
            deposit_rate=base_input.deposit_rate * 0.9,
            inflation=inflation * 0.8,
        ),
        ScenarioParams(
            name="Реалистичный",
            price_growth_annual=base_input.price_growth_annual,
            mortgage_rate=base_input.mortgage_rate,
            deposit_rate=base_input.deposit_rate,
            inflation=inflation,
        ),
        ScenarioParams(
            name="Пессимистичный",
            price_growth_annual=base_input.price_growth_annual * 0.3,
            mortgage_rate=base_input.mortgage_rate * 1.2,
            deposit_rate=base_input.deposit_rate * 1.1,
            inflation=inflation * 1.3,
        ),
    ]


def run_scenario(
    base_input: AuditInput, params: ScenarioParams
) -> ScenarioResult:
    """
    Запускает расчёт EI для одного сценария по всем 3 стратегиям.
    
    Args:
        base_input: Базовые параметры аудита.
        params: Параметры конкретного сценария.
    
    Returns:
        ScenarioResult с детализацией по 3 стратегиям.
    """
    # Создаём модифицированный input для данного сценария
    scenario_input = base_input.model_copy(update={
        "price_growth_annual": params.price_growth_annual,
        "mortgage_rate": params.mortgage_rate,
        "deposit_rate": params.deposit_rate,
    })

    mortgage = calculate_mortgage_scenario(scenario_input)
    cash = calculate_cash_scenario(scenario_input)
    deposit = calculate_deposit_scenario(scenario_input)

    # Определяем лучшую стратегию
    strategies = {"Cash": cash.ei, "Deposit": deposit.ei, "Mortgage": mortgage.ei}
    best = max(strategies, key=strategies.get)

    return ScenarioResult(
        scenario_name=params.name,
        params=params,
        mortgage=mortgage,
        cash=cash,
        deposit=deposit,
        best_strategy=best,
    )


def run_full_audit(
    input_data: AuditInput,
    inflation: float = 8.0,
) -> AuditResult:
    """
    Запускает полный аудит: матрица 3 сценария × 3 стратегии.
    
    Args:
        input_data: Входные параметры аудита.
        inflation: Текущая инфляция (для генерации сценариев).
    
    Returns:
        AuditResult с полной матрицей, вердиктом и рисками.
    """
    scenarios_params = build_scenario_params(input_data, inflation)
    scenarios = [run_scenario(input_data, sp) for sp in scenarios_params]

    # EI из реалистичного сценария (index 1) для итогового вердикта
    realistic = scenarios[1]
    ei_cash = realistic.cash.ei
    ei_deposit = realistic.deposit.ei
    ei_mortgage = realistic.mortgage.ei

    verdict, explanation = determine_verdict(ei_cash, ei_deposit, ei_mortgage)
    
    # v2.0 Sensitivity Table
    sensitivity = []
    for rate in range(5, 31):
        temp_input = input_data.model_copy(update={"mortgage_rate": float(rate)})
        res = calculate_mortgage_scenario(temp_input)
        sensitivity.append({
            "rate": float(rate),
            "ei": res.ei,
            "is_profitable": res.ei >= 1.2
        })

    risks = identify_risks(input_data)
    assumptions = list_assumptions(input_data)

    return AuditResult(
        complex_name=input_data.complex_name,
        apartment_type=input_data.apartment_type,
        area_sqm=input_data.area_sqm,
        price_total=input_data.price_total,
        price_per_sqm=round(input_data.price_total / input_data.area_sqm, 2),
        audit_date=date.today().isoformat(),
        scenarios=scenarios,
        ei_cash=ei_cash,
        ei_deposit=ei_deposit,
        ei_mortgage=ei_mortgage,
        sensitivity_table=sensitivity,
        verdict=verdict,
        verdict_explanation=explanation,
        risks=risks,
        assumptions=assumptions,
    )
