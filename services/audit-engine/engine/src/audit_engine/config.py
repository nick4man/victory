"""Configuration for Audit Engine v2.0."""

# _secrets_loader_v1
import os as _os
def _load_env_file(_p):
    if not _os.path.exists(_p):
        return
    with open(_p, encoding="utf-8") as _fh:
        for _line in _fh:
            _line = _line.strip()
            if not _line or _line.startswith("#"):
                continue
            _k, _sep, _v = _line.partition("=")
            if not _sep:
                continue
            _os.environ.setdefault(_k.strip(), _v.strip().strip('"').strip("'"))
for _p in [
    _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), ".env"),
    "/opt/.openclaw/.openclaw/workspace-conveyor/.env",
]:
    _load_env_file(_p)
del _load_env_file, _p

import os
from pydantic_settings import BaseSettings
from pydantic import ConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment."""

    model_config = ConfigDict(env_file=".env", extra="ignore")

    # Default — для локальной разработки. В контейнере перекрывается env DATABASE_URL
    # (см. docker-compose.yml). Пароль здесь — placeholder; реальный обязан
    # прийти через env (DB_PASSWORD или прямой DATABASE_URL).
    database_url: str = f"postgresql://audit_user:{os.environ.get('DB_PASSWORD', 'NOT_SET')}@localhost:5432/re_audit"
    redis_url: str = "redis://localhost:6379/0"

    # Default audit parameters
    default_horizon_years: int = 5
    default_cash_discount_pct: float = 10.0
    default_down_payment_pct: float = 20.0
    default_mortgage_term_years: int = 20

    # EI thresholds
    ei_buy_threshold: float = 1.2
    ei_neutral_low: float = 0.9
    ei_neutral_high: float = 1.1
    ei_reject_threshold: float = 0.8

    # Monte-Carlo defaults
    # Бенчмарк 2026-05-07 (audit-v2-stack, CPU): 100k→32 ms, 1M→14 s, 10M→551 s.
    # Сходимость mean(EI): 0.5688 → 0.5685 → 0.5684 (SE ~1e-4 на 1M).
    # Production-N=1M — компромисс точность/время. 10M доступен явным num_simulations.
    mc_default_simulations: int = 1_000_000
    mc_max_simulations: int = 10_000_000
    mc_async_threshold: int = 50_000  # N above which endpoint offloads to threadpool
    mc_async_concurrency: int = 4  # Semaphore width around to_thread
    mc_price_growth_std: float = 3.0  # σ for price growth distribution
    mc_mortgage_rate_std: float = 2.0  # σ for mortgage rate distribution
    mc_deposit_rate_std: float = 1.5  # σ for deposit rate distribution
    mc_correlation_mortgage_deposit: float = 0.85  # ρ between mortgage and deposit rates

    # Mixture Monte-Carlo (Phase F): Categorical([bull, base, bear]) → MVN.
    # σ per-scenario = base_σ × std_multiplier; shifts по μ задаются как
    # абсолютные дельты к `price_growth_annual` из AuditInput.
    mc_scenario_weights_bull: float = 0.25
    mc_scenario_weights_base: float = 0.50
    mc_scenario_weights_bear: float = 0.25
    mc_scenario_mu_shift_bull: float = 3.0   # +3 п.п. к price_growth_annual
    mc_scenario_mu_shift_base: float = 0.0
    mc_scenario_mu_shift_bear: float = -4.0  # -4 п.п.
    mc_scenario_std_mult_bull: float = 1.2
    mc_scenario_std_mult_base: float = 1.0
    mc_scenario_std_mult_bear: float = 1.4   # медвежий — жирнее хвост

    # Location-aware volatility (фаза D ↔ F): σ *= (1.2 - 0.4*location_score)
    # → локации с высоким скором (близко к метро/школам) менее волатильны.
    mc_location_vol_base: float = 1.2
    mc_location_vol_slope: float = 0.4

    # Business DCF MC defaults
    mc_business_revenue_growth_std: float = 3.0     # п.п.
    mc_business_margin_std: float = 2.0             # п.п. к ebitda-margin
    mc_business_discount_rate_std: float = 1.5      # п.п.

    # Nextcloud upload
    nextcloud_rclone_remote: str = "nxt"
    nextcloud_base_path: str = "Офис/НЕДВИЖИМОСТЬ/Отчёты по аудиту"
    nextcloud_auto_upload: bool = True


settings = Settings()
