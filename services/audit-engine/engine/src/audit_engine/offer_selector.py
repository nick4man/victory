"""Eligibility filter для банковских офферов.

Принимает `AuditInput` + список `BankOffer` и возвращает только те офферы,
которые реально применимы к данному клиенту:

* сумма кредита (price_total × (1 − down_payment_pct/100)) не превышает
  `max_loan_amount`;
* доступный первый взнос (user.down_payment_pct) не ниже
  `down_payment_min_pct`;
* срок из `AuditInput.mortgage_term_years` попадает в [min, max];
* специальные программы (family / IT / subsidized) требуют соответствующий
  флаг в `AuditInput` (не поддержан пока — помечаем `ineligible`, но без
  хард-фильтра: эти флаги добавим вместе с Phase C, когда AuditInput станет
  полиморфным).
"""
from __future__ import annotations

from audit_engine.models import AuditInput, BankOffer, BankProductType


_SPECIAL_PRODUCTS = {
    BankProductType.FAMILY_MORTGAGE,
    BankProductType.IT_MORTGAGE,
    BankProductType.SUBSIDIZED,
}


def is_eligible(audit_input: AuditInput, offer: BankOffer) -> bool:
    """True, если оффер применим к данному аудиту."""
    # Первый взнос клиента
    if offer.down_payment_min_pct is not None:
        if audit_input.down_payment_pct < offer.down_payment_min_pct:
            return False

    # Срок кредита
    term = audit_input.mortgage_term_years
    if offer.term_years_min is not None and term < offer.term_years_min:
        return False
    if offer.term_years_max is not None and term > offer.term_years_max:
        return False

    # Сумма кредита
    loan = audit_input.price_total * (1.0 - audit_input.down_payment_pct / 100.0)
    if offer.max_loan_amount is not None and loan > offer.max_loan_amount:
        return False

    # Специальные программы: без дополнительных флагов в AuditInput — считаем,
    # что клиент их не запрашивал. Пропускаем из общего MC (оператор может
    # указать конкретный offer_id явно через compare-offers).
    if offer.product_type in _SPECIAL_PRODUCTS:
        # Допускаем оффер только если `requirements` пуст — т.е. программа
        # доступна всем (например, временные акции с широкими условиями).
        if offer.requirements:
            return False

    return True


def eligible_offers(
    audit_input: AuditInput, offers: list[BankOffer]
) -> list[BankOffer]:
    return [o for o in offers if is_eligible(audit_input, o)]


def effective_rate(offer: BankOffer) -> float:
    """Ставка, которую подставляем в Monte-Carlo.

    Если у оффера есть диапазон (rate_min, rate_max) — берём середину,
    что даёт более честную оценку «средней» заявки. Иначе — rate_min.
    """
    if offer.rate_max is not None and offer.rate_max > offer.rate_min:
        return (offer.rate_min + offer.rate_max) / 2.0
    return offer.rate_min
