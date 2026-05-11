"""E2 — Bearer-token auth + per-token rate limit.

Архитектура:
- Токены задаются через env `AUDIT_API_TOKENS` — comma-separated. Если пусто,
  auth полностью выключен (backwards-compat — для existing деплоев).
- Принимаем как `X-Audit-Token: <token>`, так и `Authorization: Bearer <token>`.
- Rate-limit per-token: `AUDIT_RATE_LIMIT_PER_MIN` (default 60) на основе Redis.
  При недоступности Redis → in-memory дегrad с warning.
- Whitelist путей: `/`, `/api/v2/health`, `/api/v2/docs`, `/api/v2/openapi.json`.

Использование (middleware подключён в `app.py`):
    from audit_engine.api.auth import AuthMiddleware
    app.add_middleware(AuthMiddleware)
"""
from __future__ import annotations

import logging
import os
import time
from collections import defaultdict
from typing import Iterable

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger(__name__)


def _load_tokens() -> set[str]:
    raw = os.environ.get("AUDIT_API_TOKENS", "")
    return {t.strip() for t in raw.split(",") if t.strip()}


def _whitelist_paths() -> set[str]:
    return {
        "/",
        "/api/v2/health",
        "/api/v2/docs",
        "/api/v2/openapi.json",
        "/api/v2/redoc",
    }


VALID_TOKENS = _load_tokens()
WHITELIST = _whitelist_paths()
RATE_LIMIT_PER_MIN = int(os.environ.get("AUDIT_RATE_LIMIT_PER_MIN", "60"))
AUTH_ENABLED = bool(VALID_TOKENS)

# In-memory fallback bucket (если Redis недоступен)
_INMEM_BUCKET: dict[str, list[float]] = defaultdict(list)


def _extract_token(request: Request) -> str | None:
    """Поддерживаем 2 заголовка для гибкости интеграций."""
    tok = request.headers.get("X-Audit-Token")
    if tok:
        return tok.strip()
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return None


async def _check_rate_limit_redis(token: str) -> tuple[bool, int]:
    """Atomic sliding window через INCR + EXPIRE. Возвращает (allowed, remaining)."""
    try:
        import redis.asyncio as redis  # type: ignore
    except ImportError:
        return _check_rate_limit_inmem(token)

    url = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
    try:
        r = redis.from_url(url, decode_responses=True)
        minute = int(time.time() // 60)
        key = f"audit_rl:{token}:{minute}"
        count = await r.incr(key)
        if count == 1:
            await r.expire(key, 65)  # чуть больше минуты, чтобы успели слайдингом
        await r.aclose()
        remaining = max(0, RATE_LIMIT_PER_MIN - int(count))
        return (int(count) <= RATE_LIMIT_PER_MIN, remaining)
    except Exception as exc:
        logger.warning("Redis rate-limit fallback: %s", exc)
        return _check_rate_limit_inmem(token)


def _check_rate_limit_inmem(token: str) -> tuple[bool, int]:
    now = time.time()
    bucket = _INMEM_BUCKET[token]
    cutoff = now - 60.0
    bucket[:] = [t for t in bucket if t > cutoff]
    bucket.append(now)
    remaining = max(0, RATE_LIMIT_PER_MIN - len(bucket))
    return (len(bucket) <= RATE_LIMIT_PER_MIN, remaining)


class AuthMiddleware(BaseHTTPMiddleware):
    """Авторизация по токену + rate limit per token.

    Включается ТОЛЬКО когда `AUDIT_API_TOKENS` задан. Иначе middleware
    пропускает все запросы без проверки (backwards-compat).
    """

    async def dispatch(self, request: Request, call_next):
        path = request.url.path

        # Public endpoints
        if path in WHITELIST or not AUTH_ENABLED:
            return await call_next(request)

        token = _extract_token(request)
        if not token or token not in VALID_TOKENS:
            return JSONResponse(
                {"detail": "Missing or invalid token. Provide X-Audit-Token or Authorization: Bearer <token>."},
                status_code=401,
            )

        # Rate limit
        allowed, remaining = await _check_rate_limit_redis(token)
        if not allowed:
            return JSONResponse(
                {
                    "detail": f"Rate limit exceeded: {RATE_LIMIT_PER_MIN} requests/min per token",
                    "retry_after_seconds": 60,
                },
                status_code=429,
                headers={"X-RateLimit-Remaining": "0", "Retry-After": "60"},
            )

        response = await call_next(request)
        response.headers["X-RateLimit-Remaining"] = str(remaining)
        response.headers["X-RateLimit-Limit"] = str(RATE_LIMIT_PER_MIN)
        return response


def is_auth_enabled() -> bool:
    """Удобно для healthcheck и docs."""
    return AUTH_ENABLED
