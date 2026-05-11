"""EI (Efficiency Index) calculators, полиморфные по `PropertyType`.

Публичный API:
    from audit_engine.ei import calculate_ei
    result = calculate_ei(property_input)  # dispatch по property_type

Каждый модуль этого пакета реализует свой способ расчёта EI:
* `apartment` — классические 3 стратегии (cash / mortgage / deposit).
* `house`     — те же стратегии + земельная компонента + коммуналка.
* `land`      — простая формула «рост цены vs депозит».
* `business`  — DCF по FCF + terminal value.
"""
from __future__ import annotations

from typing import Union

from audit_engine.models import (
    AuditInput,
    BusinessEIDetails,
    BusinessInput,
    HouseEIDetails,
    HouseInput,
    LandEIDetails,
    LandInput,
    PropertyType,
)

from audit_engine.ei import apartment as _apartment
from audit_engine.ei import business as _business
from audit_engine.ei import house as _house
from audit_engine.ei import land as _land


EIResult = Union[
    "AuditResultLike",  # для APARTMENT — используем существующий scenario_builder
    HouseEIDetails,
    LandEIDetails,
    BusinessEIDetails,
]


def calculate_ei(
    input_data: AuditInput | HouseInput | LandInput | BusinessInput,
):
    """Диспатчер: вычислить EI под конкретный тип объекта.

    Для APARTMENT возвращает стандартный набор (MortgageDetails, CashDetails,
    DepositDetails) через `apartment.calculate_apartment_ei`. Для остальных —
    свои специфические DTO.
    """
    ptype = input_data.property_type
    if ptype == PropertyType.APARTMENT:
        return _apartment.calculate_apartment_ei(input_data)  # type: ignore[arg-type]
    if ptype == PropertyType.HOUSE:
        return _house.calculate_house_ei(input_data)  # type: ignore[arg-type]
    if ptype == PropertyType.LAND:
        return _land.calculate_land_ei(input_data)  # type: ignore[arg-type]
    if ptype == PropertyType.BUSINESS:
        return _business.calculate_business_ei(input_data)  # type: ignore[arg-type]
    raise ValueError(f"Unsupported property_type: {ptype!r}")


__all__ = ["calculate_ei"]
