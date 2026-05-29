"""Hedonic regression для оценки справедливой цены ₽/м².

Зачем:
    Простой median ₽/м² по компам игнорирует характеристики объекта
    (площадь, число комнат, расстояние). 60-метровая двушка на 1-м
    этаже не сопоставима с 90-метровой трёшкой на 10-м напрямую.

Модель:
    log(price_per_sqm) = β0 + β1·rooms + β2·log(area_sqm) + β3·distance_km + ε

    OLS через numpy.lstsq. Прогноз для аудитного объекта возвращается
    с 95% доверительным интервалом (на основе residual std).

Когда возвращается None:
    - n_complete < MIN_HEDONIC_SAMPLE (по умолчанию 8) — слишком мало
      объектов с заполненными площадью/комнатами для разумной регрессии.
    - матрица признаков вырождена (все объекты — однокомнатные).

Интеграция:
    `competitor_analyzer.analyze()` опционально вызывает `fit_and_predict`
    и кладёт результат в `CompetitorAnalysis.hedonic`. Median-based анализ
    остаётся как основной — hedonic это дополнительный сигнал.
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass
from typing import Iterable, Optional

import numpy as np

from audit_engine.models import Competitor

logger = logging.getLogger(__name__)

MIN_HEDONIC_SAMPLE = 8
CI_Z_95 = 1.96


@dataclass
class HedonicTarget:
    """Параметры аудитного объекта, которые подставляются в модель."""
    rooms: int
    area_sqm: float
    distance_km: float = 0.0  # сам аудитный объект — точка отсчёта


@dataclass
class HedonicResult:
    predicted_price_per_sqm: float
    ci_lo_95: float
    ci_hi_95: float
    n_used: int
    r_squared: float
    residual_std: float
    feature_names: tuple[str, ...]
    coefficients: tuple[float, ...]

    def to_dict(self) -> dict:
        return {
            "predicted_price_per_sqm": round(self.predicted_price_per_sqm, 2),
            "ci_lo_95": round(self.ci_lo_95, 2),
            "ci_hi_95": round(self.ci_hi_95, 2),
            "n_used": self.n_used,
            "r_squared": round(self.r_squared, 4),
            "residual_std": round(self.residual_std, 4),
            "feature_names": list(self.feature_names),
            "coefficients": [round(c, 6) for c in self.coefficients],
        }


def apartment_type_to_rooms(apt_type: Optional[str]) -> Optional[int]:
    """Маппинг 'Studio'/'1BR'/'2BR'/... → число комнат для hedonic-регрессии.

    Возвращает None, если тип не распознан — тогда вызывающий код просто
    пропускает hedonic.
    """
    if not apt_type:
        return None
    s = apt_type.strip().lower()
    if s in ("studio", "студия"):
        return 0
    for prefix in ("1", "2", "3", "4", "5"):
        if s.startswith(prefix):
            try:
                return int(prefix)
            except ValueError:
                pass
    return None


def _drop_constant_columns(X: np.ndarray) -> tuple[np.ndarray, list[int]]:
    """Удалить колонки без вариативности (кроме intercept в позиции 0).

    Возвращает (X_reduced, kept_indices). intercept всегда сохраняется.
    """
    keep = [0]
    for j in range(1, X.shape[1]):
        if X[:, j].std() > 1e-9:
            keep.append(j)
    return X[:, keep], keep


def _build_design_matrix(comps: list[Competitor]) -> tuple[np.ndarray, np.ndarray]:
    """Возвращает X (n × 4) и y (n,). Отбрасывает объекты с пропусками."""
    rows: list[list[float]] = []
    ys: list[float] = []
    for c in comps:
        if c.area_sqm is None or c.rooms is None or c.price_per_sqm <= 0:
            continue
        if c.area_sqm <= 0:
            continue
        distance_km = (c.distance_m or 0) / 1000.0
        rows.append([1.0, float(c.rooms), math.log(c.area_sqm), distance_km])
        ys.append(math.log(c.price_per_sqm))
    return np.array(rows, dtype=float), np.array(ys, dtype=float)


def fit_and_predict(
    target: HedonicTarget,
    competitors: Iterable[Competitor],
) -> Optional[HedonicResult]:
    """Подогнать OLS на компах, предсказать ₽/м² для target.

    Возвращает None, если sample слишком мал или регрессия вырождена.
    """
    comps = list(competitors)
    X_full, y = _build_design_matrix(comps)
    n = X_full.shape[0]
    if n < MIN_HEDONIC_SAMPLE:
        logger.info(
            "hedonic: %d полных объектов < %d — пропускаю регрессию",
            n, MIN_HEDONIC_SAMPLE,
        )
        return None

    # Если какая-то фича константна (напр. distance_m=0 у всех) — выкидываем её.
    X, kept = _drop_constant_columns(X_full)
    feature_names_full = ("intercept", "rooms", "log_area", "distance_km")
    feature_names = tuple(feature_names_full[i] for i in kept)
    if X.shape[1] < 2:
        logger.info("hedonic: после dedupe осталась только константа — пропускаю")
        return None
    if np.linalg.matrix_rank(X) < X.shape[1]:
        logger.info("hedonic: rank-deficient design matrix — пропускаю")
        return None

    coef_reduced, _, rank, _ = np.linalg.lstsq(X, y, rcond=None)
    if rank < X.shape[1]:
        logger.info("hedonic: rank %d < k %d — пропускаю", rank, X.shape[1])
        return None

    # R² и residual std
    y_pred = X @ coef_reduced
    ss_res = float(np.sum((y - y_pred) ** 2))
    ss_tot = float(np.sum((y - y.mean()) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 0.0
    dof = n - X.shape[1]
    residual_std = math.sqrt(ss_res / dof) if dof > 0 else 0.0

    # Восстанавливаем полный вектор коэффициентов (нули для отброшенных фич),
    # чтобы клиенту было удобно мапить на feature_names_full.
    full_coef = [0.0] * len(feature_names_full)
    for src, idx in enumerate(kept):
        full_coef[idx] = float(coef_reduced[src])

    x_target_full = np.array(
        [1.0, float(target.rooms), math.log(target.area_sqm), target.distance_km],
        dtype=float,
    )
    log_pred = float(x_target_full[kept] @ coef_reduced)
    pred = math.exp(log_pred)

    half_log = CI_Z_95 * residual_std
    ci_lo = math.exp(log_pred - half_log)
    ci_hi = math.exp(log_pred + half_log)

    return HedonicResult(
        predicted_price_per_sqm=pred,
        ci_lo_95=ci_lo,
        ci_hi_95=ci_hi,
        n_used=n,
        r_squared=r2,
        residual_std=residual_std,
        feature_names=feature_names,
        coefficients=tuple(full_coef[i] for i in kept),
    )
