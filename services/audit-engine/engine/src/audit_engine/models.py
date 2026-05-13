"""Pydantic models for Audit Engine v2.0."""

from __future__ import annotations
from pydantic import BaseModel, Field
from datetime import date
from typing import Annotated, Any, Literal, Optional, Union
from enum import Enum


class Verdict(str, Enum):
    BUY = "BUY"
    WAIT = "WAIT"
    NEUTRAL = "NEUTRAL"


class BankProductType(str, Enum):
    MORTGAGE = "mortgage"
    FAMILY_MORTGAGE = "family_mortgage"
    IT_MORTGAGE = "it_mortgage"
    SUBSIDIZED = "subsidized"
    REFINANCE = "refinance"
    CONSUMER_LOAN = "consumer_loan"
    # Regional / specialty mortgage programs — already present in DB seed
    # but were missing from the enum, causing /bank-offers/ to 500.
    FAR_EAST_MORTGAGE = "far_east_mortgage"
    MILITARY_MORTGAGE = "military_mortgage"
    # Savings side — bank pays the customer. Used by the deposit table
    # on /services/mortgage_calculator and by the investment audit.
    DEPOSIT = "deposit"


class PropertyType(str, Enum):
    """Тип оцениваемого объекта.

    APARTMENT — квартира (классический набор EI-формул: cash/mortgage/deposit).
    HOUSE — частный дом (квартирная математика + коммуналка + отдельная
    земельная компонента в прогнозной стоимости).
    LAND — земельный участок (нет аренды и ипотеки; EI = рост цены vs депозит).
    BUSINESS — действующий бизнес (EI через DCF по FCF).
    """
    APARTMENT = "APARTMENT"
    HOUSE = "HOUSE"
    LAND = "LAND"
    BUSINESS = "BUSINESS"


# ========================
# Input Models
# ========================

class AuditInput(BaseModel):
    """Input parameters for apartment audit (legacy back-compat).

    Это дефолтный тип объекта (APARTMENT). Поле `property_type` с литералом
    `APARTMENT` добавлено для использования в discriminated union
    `PropertyInput`; существующие call-site без него работают как раньше.
    """

    property_type: Literal[PropertyType.APARTMENT] = Field(
        default=PropertyType.APARTMENT,
        description="Тип объекта — квартира.",
    )

    # Object
    complex_name: str = Field(..., description="Название ЖК")
    apartment_type: str = Field(..., description="Тип квартиры (Studio, 1BR, 2BR, 3BR)")
    area_sqm: float = Field(..., gt=0, description="Площадь квартиры (м²)")
    price_total: float = Field(..., gt=0, description="Текущая цена квартиры (руб)")
    monthly_rent: float = Field(..., gt=0, description="Аренда аналогичного жилья (руб/мес)")

    # Mortgage
    mortgage_rate: float = Field(..., gt=0, description="Ставка ипотеки (% годовых)")
    mortgage_term_years: int = Field(default=20, gt=0, description="Срок ипотеки (лет)")
    down_payment_pct: float = Field(default=20.0, gt=0, le=100, description="Первоначальный взнос (%)")

    # Alternatives
    deposit_rate: float = Field(..., gt=0, description="Ставка депозита (% годовых)")

    # Forecasts
    price_growth_annual: float = Field(..., description="Прогнозный рост цен (% годовых)")
    horizon_years: int = Field(default=5, gt=0, description="Горизонт оценки (лет)")

    # Cash discount
    cash_discount_pct: float = Field(default=10.0, ge=0, le=50, description="Скидка за 100% оплату (%)")

    # Геоданные (для фазы D — location scoring). Опциональны.
    lat: Optional[float] = None
    lon: Optional[float] = None
    cadastral_number: Optional[str] = None


class HouseInput(BaseModel):
    """Частный дом: квартирная ЕИ-математика + земля + коммуналка.

    Все финансовые поля (price, mortgage, deposit, rent) зеркалируют
    `AuditInput`. `land_area_sotka` участвует в прогнозной стоимости как
    отдельная компонента с собственным ростом.
    """
    property_type: Literal[PropertyType.HOUSE] = PropertyType.HOUSE

    # Object
    object_name: str = Field(..., description="Название / адрес дома")
    area_sqm: float = Field(..., gt=0, description="Жилая площадь дома (м²)")
    price_total: float = Field(..., gt=0, description="Текущая цена (руб)")
    monthly_rent: float = Field(..., gt=0, description="Аренда аналогичного дома (руб/мес)")

    land_area_sotka: float = Field(
        default=0.0, ge=0, description="Площадь участка (соток). 0 если земля оформлена отдельно."
    )
    land_price_per_sotka: float = Field(
        default=0.0, ge=0, description="Оценочная стоимость сотки (руб)."
    )
    land_growth_annual: float = Field(
        default=0.0, description="Рост цены земли (% годовых). Обычно ниже, чем дома."
    )
    annual_utilities_cost: float = Field(
        default=0.0, ge=0, description="Годовые эксплуатационные расходы (руб): отопление, газ, вода."
    )

    # Финансовые (идентично AuditInput)
    mortgage_rate: float = Field(..., gt=0)
    mortgage_term_years: int = Field(default=20, gt=0)
    down_payment_pct: float = Field(default=20.0, gt=0, le=100)
    deposit_rate: float = Field(..., gt=0)
    price_growth_annual: float = Field(..., description="Рост цены дома (%/год)")
    horizon_years: int = Field(default=5, gt=0)
    cash_discount_pct: float = Field(default=10.0, ge=0, le=50)

    # Геоданные
    lat: Optional[float] = None
    lon: Optional[float] = None
    cadastral_number: Optional[str] = None


class LandInput(BaseModel):
    """Земельный участок: нет аренды и (обычно) ипотеки.

    EI = будущая цена участка / (текущая цена + упущенная выгода депозита +
    суммарные налоги и расходы). Простая логика «купить-держать-продать».
    """
    property_type: Literal[PropertyType.LAND] = PropertyType.LAND

    object_name: str = Field(..., description="Кадастровый номер / описание")
    area_sotka: float = Field(..., gt=0, description="Площадь (соток)")
    price_total: float = Field(..., gt=0, description="Текущая цена (руб)")
    zoning: str = Field(
        default="ИЖС",
        description="ВРИ/зонирование: ИЖС, СНТ, ДНП, ЛПХ, сельхозназначения, промышленное и т.п.",
    )

    deposit_rate: float = Field(..., gt=0, description="Ставка депозита (% годовых)")
    price_growth_annual: float = Field(..., description="Рост цены участка (%/год)")
    horizon_years: int = Field(default=5, gt=0)
    annual_tax: float = Field(
        default=0.0, ge=0, description="Годовой земельный налог (руб)."
    )
    annual_maintenance: float = Field(
        default=0.0, ge=0, description="Годовое обслуживание (покос, охрана, взносы СНТ)."
    )

    lat: Optional[float] = None
    lon: Optional[float] = None
    cadastral_number: Optional[str] = None


class BusinessInput(BaseModel):
    """Готовый бизнес: EI через DCF.

    DCF даёт справедливую стоимость как сумму дисконтированных FCF за
    горизонт + терминальную стоимость по модели Гордона. EI — отношение
    этой справедливой стоимости к запрашиваемой цене; >1 — переплатят,
    <1 — недооценён.
    """
    property_type: Literal[PropertyType.BUSINESS] = PropertyType.BUSINESS

    object_name: str = Field(..., description="Название бизнеса")
    price_total: float = Field(..., gt=0, description="Запрашиваемая цена сделки (руб)")

    annual_revenue: float = Field(..., gt=0, description="Годовая выручка (руб)")
    ebitda: float = Field(..., description="EBITDA за последний год (руб)")
    ebitda_margin: Optional[float] = Field(
        default=None, description="EBITDA-маржа (%). Если не задана — вычисляется."
    )
    revenue_growth_annual: float = Field(
        default=5.0, description="Ожидаемый рост выручки (%/год)"
    )
    discount_rate: float = Field(
        default=20.0, gt=0, description="Ставка дисконтирования (%/год). WACC/cost of equity."
    )
    terminal_growth: float = Field(
        default=3.0, description="Долгосрочный рост для terminal value (%/год)."
    )
    tax_rate: float = Field(
        default=20.0, ge=0, le=100, description="Налог на прибыль (%)."
    )
    multiple_ebitda: Optional[float] = Field(
        default=None, description="EV/EBITDA для кросс-чека; не используется в EI напрямую."
    )
    capex_pct_of_revenue: Optional[float] = Field(
        default=0.0, description="CAPEX как % от выручки (положительное значение). Если не задано, предполагается 0."
    )
    working_capital_change_pct_of_revenue: Optional[float] = Field(
        default=0.0, description="Изменение оборотного капитала как % от выручки (может быть отрицательным). Если не задано, предполагается 0."
    )
    horizon_years: int = Field(default=5, gt=0, description="Горизонт DCF")

    lat: Optional[float] = None
    lon: Optional[float] = None


# Discriminated union: `property_type` как дискриминатор. FastAPI/Pydantic
# автоматически выберет подходящий класс при валидации входа.
PropertyInput = Annotated[
    Union[AuditInput, HouseInput, LandInput, BusinessInput],
    Field(discriminator="property_type"),
]


class ScenarioParams(BaseModel):
    """Parameters for a single forecast scenario."""
    name: str
    price_growth_annual: float
    mortgage_rate: float
    deposit_rate: float
    inflation: float


# ========================
# Output Models
# ========================

class MortgageDetails(BaseModel):
    """Detailed mortgage scenario breakdown."""
    down_payment: float = Field(description="Сумма ПВ (руб)")
    loan_amount: float = Field(description="Тело кредита (руб)")
    monthly_payment: float = Field(description="Ежемесячный платёж (руб)")
    total_payments: float = Field(description="Всего выплат за весь срок (руб)")
    total_interest: float = Field(description="Переплата по процентам (руб)")
    opportunity_cost_dp: float = Field(description="Упущенная выгода ПВ на депозите (руб)")
    projected_asset_value: float = Field(description="Прогнозная стоимость через N лет (руб)")
    rent_savings: float = Field(description="Экономия на аренде за N лет (руб)")
    ei: float = Field(description="Индекс Целесообразности")


class CashDetails(BaseModel):
    """Detailed cash purchase scenario breakdown."""
    price_with_discount: float = Field(description="Цена со скидкой (руб)")
    discount_amount: float = Field(description="Размер скидки (руб)")
    opportunity_cost: float = Field(description="Упущенная выгода депозита (руб)")
    projected_asset_value: float = Field(description="Прогнозная стоимость (руб)")
    rent_savings: float = Field(description="Экономия на аренде (руб)")
    ei: float = Field(description="Индекс Целесообразности")


class DepositDetails(BaseModel):
    """Detailed deposit+wait scenario breakdown."""
    capital_after_horizon: float = Field(description="Капитал через N лет на депозите (руб)")
    projected_price: float = Field(description="Прогнозная цена квартиры через N лет (руб)")
    total_rent_cost: float = Field(description="Затраты на аренду за N лет (руб)")
    net_position: float = Field(description="Чистая позиция: капитал - цена - аренда (руб)")
    ei: float = Field(description="Индекс Целесообразности")


class ScenarioResult(BaseModel):
    """Result for one scenario (optimistic/realistic/pessimistic)."""
    scenario_name: str
    params: ScenarioParams
    mortgage: MortgageDetails
    cash: CashDetails
    deposit: DepositDetails
    best_strategy: str = Field(description="Лучшая стратегия в этом сценарии")


# ========================
# Polymorphic EI results (Phase C)
# ========================

class LandEIDetails(BaseModel):
    """EI земельного участка: рост цены vs депозит + налоги."""
    projected_price: float = Field(description="Прогнозная цена через N лет (руб)")
    opportunity_cost_deposit: float = Field(description="Доход от депозита за этот же горизонт (руб)")
    total_tax_and_maintenance: float = Field(description="Суммарные налоги и обслуживание за горизонт (руб)")
    ei: float = Field(description="EI = projected_price / (price_total + opp_cost + tax)")


class BusinessEIDetails(BaseModel):
    """EI бизнеса через DCF."""
    fair_value_dcf: float = Field(description="Справедливая стоимость (NPV FCF + terminal value)")
    fcf_per_year: list[float] = Field(description="Прогнозный FCF по годам")
    terminal_value: float = Field(description="Терминальная стоимость по Гордону")
    discount_rate: float = Field(description="Применённая ставка дисконтирования (%)")
    ei: float = Field(description="EI = fair_value_dcf / price_total; >1 — недооценён")
    npv_explicit: float = Field(description="NPV явного периода (без терминальной стоимости)")
    terminal_growth_used: float = Field(description="Фактический долгосрочный рост, использованный для terminal value (%/год)")
    terminal_method: str = Field(description="Метод расчёта terminal value: 'gordon' или 'multiple'")
    sensitivity: Optional[dict] = Field(default=None, description="Результаты анализа чувствительности по ключевым параметрам")


class HouseEIDetails(BaseModel):
    """EI дома — расширение апартаментной логики: добавлены земля и утилиты."""
    mortgage: MortgageDetails
    cash: CashDetails
    deposit: DepositDetails
    land_projected_value: float = Field(description="Прогнозная стоимость земли")
    total_utilities_cost: float = Field(description="Коммуналка за весь горизонт (руб)")
    best_strategy: str


class BusinessMCSummary(BaseModel):
    """Итог DCF Monte-Carlo для бизнеса.

    `ei` распределение строится по сэмплам (revenue_growth, ebitda_margin,
    discount_rate); используется для оценки вероятности BUY и ширины
    доверительного интервала.
    """
    num_simulations: int
    ei_mean: float
    ei_p5: float
    ei_p50: float
    ei_p95: float
    ei_std: float
    buy_probability: float = Field(description="P(EI >= 1.0), %")
    verdict: str


# ========================
# Monte-Carlo Models (v2.0)
# ========================

class MonteCarloResult(BaseModel):
    """Result of Monte-Carlo simulation for one strategy."""
    num_simulations: int
    strategy: str  # cash / mortgage / deposit
    ei_mean: float
    ei_median: float
    ei_p1: float = 0.0   # 1st percentile (tail)
    ei_p5: float   # 5th percentile
    ei_p25: float  # 25th percentile
    ei_p75: float  # 75th percentile
    ei_p95: float  # 95th percentile
    ei_p99: float = 0.0  # 99th percentile (tail)
    ei_std: float
    buy_probability: float  # % симуляций где EI > threshold
    distribution_data: dict  # histogram bins for frontend


class MonteCarloSummary(BaseModel):
    """Summary of Monte-Carlo results across all strategies."""
    cash: MonteCarloResult
    mortgage: MonteCarloResult
    deposit: MonteCarloResult
    recommended_strategy: str
    confidence_level: str  # "high" / "medium" / "low"


# ========================
# Full Audit Result (v2.0)
# ========================

class AuditResult(BaseModel):
    id: str | None = None
    """Complete audit result with all scenarios, MC, and verdict."""
    id: Optional[str] = None
    complex_name: str
    apartment_type: str
    area_sqm: float
    price_total: float
    price_per_sqm: float
    audit_date: str

    # Matrix 3x3
    scenarios: list[ScenarioResult]

    # Summary EI (realistic scenario)
    ei_cash: float
    ei_deposit: float
    ei_mortgage: float

    # Sensitivity Table
    sensitivity_table: list[dict] = Field(default_factory=list)

    # Monte-Carlo (v2.0)
    monte_carlo: Optional[MonteCarloSummary] = None

    # Verdict
    verdict: Verdict
    verdict_explanation: str
    risks: list[str]
    assumptions: list[str]


# ========================
# Retro Models
# ========================

class RetroSnapshot(BaseModel):
    """Historical price snapshot."""
    date: str
    price_per_sqm: float
    source: Optional[str] = None


class DeltaPoint(BaseModel):
    """'What if we bought then' analysis point."""
    purchase_date: str
    purchase_price: float
    current_value: float
    delta_absolute: float = Field(description="Разница в рублях")
    delta_pct: float = Field(description="Разница в %")
    ei_at_that_time: float = Field(description="EI на ту дату")


class RetroResult(BaseModel):
    """Retrospective analysis result."""
    complex_name: str
    apartment_type: str
    snapshots: list[RetroSnapshot]
    delta_analysis: list[DeltaPoint]
    ei_history: list[dict]
    developer_accuracy_pct: Optional[float] = Field(
        None, description="Точность прогнозов застройщика (%)"
    )
    inflation_adjusted: bool = False


class WhatIfResult(BaseModel):
    """'Что, если бы мы купили N лет назад' — отдельная точка."""
    years_ago: int
    purchase_date: str
    purchase_price: float
    purchase_price_sqm: float
    current_value: float
    profit_absolute: float
    profit_pct: float
    ei_at_purchase: float
    ei_verdict: str = Field(
        description="'Отличная покупка' / 'Хорошая' / 'Нейтрально' / 'Убыток'"
    )
    mortgage_rate_then: float
    deposit_rate_then: float


# ========================
# API Models
# ========================

class AuditRequest(BaseModel):
    """API request for running an audit."""
    complex_name: str
    apartment_type: str
    area_sqm: float
    price_total: float
    monthly_rent: float
    mortgage_rate: Optional[float] = None  # auto from macro if None
    mortgage_term_years: int = 20
    down_payment_pct: float = 20.0
    deposit_rate: Optional[float] = None  # auto from macro if None
    price_growth_annual: Optional[float] = None  # auto from macro if None
    horizon_years: int = 5
    cash_discount_pct: float = 10.0
    run_monte_carlo: bool = True
    mc_simulations: int = 100_000


class MacroData(BaseModel):
    """Macro economics data snapshot."""
    date: str
    cbr_key_rate: Optional[float] = None
    inflation_annual: Optional[float] = None
    inflation_monthly: Optional[float] = None
    avg_deposit_rate: Optional[float] = None
    avg_mortgage_rate: Optional[float] = None
    ofz_yield_1y: Optional[float] = None
    ofz_yield_3y: Optional[float] = None
    ofz_yield_5y: Optional[float] = None
    source: Optional[str] = None


class HealthResponse(BaseModel):
    """API health check response."""
    status: str
    version: str
    db_status: str
    tables_count: int


# ========================
# Bank Offers (v2.1)
# ========================

class BankOffer(BaseModel):
    """Актуальный банковский продукт (ипотека / кредит / субсидия)."""
    id: Optional[str] = None
    bank_name: str
    product_type: BankProductType
    product_name: str
    rate_min: float
    rate_max: Optional[float] = None
    term_years_min: Optional[int] = None
    term_years_max: Optional[int] = None
    down_payment_min_pct: Optional[float] = None
    max_loan_amount: Optional[float] = None
    requirements: dict[str, Any] = Field(default_factory=dict)
    valid_from: date
    valid_to: Optional[date] = None
    source: str = "manual"
    source_url: Optional[str] = None
    is_active: bool = True


class BankOfferCreate(BaseModel):
    """Входные данные для POST /bank-offers (без id, scraped_at)."""
    bank_name: str
    product_type: BankProductType
    product_name: str
    rate_min: float
    rate_max: Optional[float] = None
    term_years_min: Optional[int] = None
    term_years_max: Optional[int] = None
    down_payment_min_pct: Optional[float] = None
    max_loan_amount: Optional[float] = None
    requirements: dict[str, Any] = Field(default_factory=dict)
    valid_from: date
    valid_to: Optional[date] = None
    source: str = "manual"
    source_url: Optional[str] = None
    is_active: bool = True


class BankOfferPatch(BaseModel):
    """Частичное обновление оффера."""
    rate_min: Optional[float] = None
    rate_max: Optional[float] = None
    valid_to: Optional[date] = None
    requirements: Optional[dict[str, Any]] = None
    is_active: Optional[bool] = None


class OfferMCSummary(BaseModel):
    """MC-результат для одного оффера + метаданные оффера."""
    offer: BankOffer
    effective_rate: float = Field(description="Ставка, реально подставленная в MC (rate_min либо середина диапазона)")
    monte_carlo: MonteCarloSummary
    ei_mortgage_median: float = Field(description="EI ипотечной стратегии (медиана)")
    ei_mortgage_mean: float
    ei_mortgage_p5: float
    ei_mortgage_p95: float
    buy_probability: float = Field(description="% симуляций с EI mortgage ≥ threshold")


class MultiOfferMCResult(BaseModel):
    """Итог Monte-Carlo аудита по всем подходящим офферам."""
    audit_id: Optional[str] = None
    num_simulations: int
    num_offers: int
    per_offer: list[OfferMCSummary]
    recommended_offer_id: Optional[str] = Field(
        None, description="offer.id с максимальным ei_mortgage_median"
    )
    recommended_bank: Optional[str] = None
    recommended_product: Optional[str] = None
    skipped_ineligible: int = Field(
        0, description="Число офферов, отфильтрованных как неподходящие"
    )


# ========================
# Location Score (Phase D)
# ========================

class POIHit(BaseModel):
    """Ближайший POI конкретного типа."""
    poi_type: str
    name: str
    distance_m: int
    lat: float
    lon: float


class LocationScore(BaseModel):
    """Скор местоположения объекта.

    `score` — композитная оценка в [0, 1]; 1.0 — идеально (метро <500м,
    школа <1км, больница <2км, плюс >10 POI в радиусе 1км).
    Используется как множитель в EI (фаза F, mixed scenario).
    """
    lat: float
    lon: float
    nearest: dict[str, Optional[POIHit]] = Field(
        default_factory=dict,
        description="Словарь poi_type -> ближайший POI (или None)",
    )
    poi_counts_1km: dict[str, int] = Field(
        default_factory=dict,
        description="Количество POI каждого типа в радиусе 1 км",
    )
    total_poi_within_1km: int = 0
    score: float = Field(ge=0.0, le=1.0, description="Композитная оценка локации [0..1]")
    components: dict[str, float] = Field(
        default_factory=dict,
        description="F3: разбивка скора на компоненты (metro/school/hospital/poi_density)",
    )
    computed_at: Optional[str] = None


# ===========================
# Competitor Analysis (Phase E)
# ===========================


class CompetitorSignal(str, Enum):
    """Сигнал по цене аудируемого объекта относительно рынка конкурентов."""
    OVERPAY = "OVERPAY"       # цена выше рынка (≥ p75)
    FAIR = "FAIR"             # в «коридоре справедливости» (p25..p75)
    UNDERPAY = "UNDERPAY"     # цена ниже рынка (≤ p25) — подозрительно дешёво
    INSUFFICIENT = "INSUFFICIENT"  # слишком мало компов для вывода (<5)


class Competitor(BaseModel):
    """Ретро-снапшот конкурентного объявления из CIAN/Avito/других источников."""
    id: Optional[int] = None
    complex_name: str
    snapshot_date: date
    competitor_name: str
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    distance_m: Optional[int] = None
    price_total: Optional[float] = None
    price_per_sqm: float
    area_sqm: Optional[float] = None
    rooms: Optional[int] = None
    property_type: str = "APARTMENT"
    source: str
    url: Optional[str] = None
    scraped_at: Optional[str] = None


class CompetitorAnalysis(BaseModel):
    """Результат конкурентного анализа для аудита.

    `percentile` — 0..100, позиция цены аудируемого объекта в распределении
    цен за м² по компам. 50 — медианная цена рынка; >75 — дорого; <25 — дёшево.
    `top5` — ближайшие по цене компы, отсортированы по |diff| от аудитной цены.
    `hedonic` — опциональная регрессионная оценка справедливой ₽/м² с учётом
    rooms / area / distance; None при N < 8 или вырожденной матрице признаков.
    """
    audit_price_per_sqm: float
    sample_size: int
    radius_m: int
    median_price_per_sqm: Optional[float] = None
    p25_price_per_sqm: Optional[float] = None
    p75_price_per_sqm: Optional[float] = None
    percentile: Optional[float] = Field(default=None, description="Перцентиль аудитной цены в [0..100]")
    signal: CompetitorSignal = CompetitorSignal.INSUFFICIENT
    top5: list[Competitor] = Field(default_factory=list)
    hedonic: Optional[dict] = Field(
        default=None,
        description="OLS-оценка ₽/м² по rooms/area/distance + 95% CI; None при N<8",
    )
