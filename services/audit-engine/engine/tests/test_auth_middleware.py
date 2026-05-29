"""E2 unit-тесты — auth middleware и rate-limit логика.

Тесты:
1. Без токенов в env auth disabled — всё проходит.
2. С токенами whitelist endpoints (/, /health) — публичные.
3. Без токена → 401.
4. Неверный токен → 401.
5. Правильный токен → 200.
6. Превышение rate limit → 429.
7. Headers X-RateLimit-* приходят с ответом.
"""
from __future__ import annotations

import os
import sys
from importlib import reload
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest


def _reload_app_with_tokens(tokens: str = ""):
    """Перезагружаем модули auth+app, чтобы новые env-переменные подхватились."""
    os.environ["AUDIT_API_TOKENS"] = tokens
    os.environ["AUDIT_SCHEDULER_DISABLED"] = "1"
    from audit_engine.api import auth
    from audit_engine.api import app as app_module
    reload(auth)
    reload(app_module)
    return app_module.app


@pytest.fixture(autouse=True)
def _cleanup_auth_env():
    """Сбрасываем AUDIT_API_TOKENS после каждого теста, чтобы не отравить
    остальной suite (бывшие 401-ы в test_bank_offers_api и т.д.).
    """
    yield
    os.environ.pop("AUDIT_API_TOKENS", None)
    os.environ.pop("AUDIT_RATE_LIMIT_PER_MIN", None)
    # Перезагружаем модули обратно в backwards-compat режим
    from audit_engine.api import auth
    from audit_engine.api import app as app_module
    reload(auth)
    reload(app_module)


# -----------------------------------------------------------------------
# In-memory rate limit (unit)
# -----------------------------------------------------------------------

def test_inmem_rate_limit_allows_under_limit():
    os.environ["AUDIT_API_TOKENS"] = "test"
    os.environ["AUDIT_RATE_LIMIT_PER_MIN"] = "5"
    from audit_engine.api import auth
    reload(auth)
    auth._INMEM_BUCKET.clear()

    for _ in range(5):
        allowed, _ = auth._check_rate_limit_inmem("test")
        assert allowed


def test_inmem_rate_limit_blocks_over_limit():
    os.environ["AUDIT_API_TOKENS"] = "test"
    os.environ["AUDIT_RATE_LIMIT_PER_MIN"] = "3"
    from audit_engine.api import auth
    reload(auth)
    auth._INMEM_BUCKET.clear()

    for _ in range(3):
        allowed, _ = auth._check_rate_limit_inmem("test")
        assert allowed
    allowed, remaining = auth._check_rate_limit_inmem("test")
    assert not allowed
    assert remaining == 0


def test_extract_token_x_header():
    os.environ["AUDIT_API_TOKENS"] = "test"
    from audit_engine.api import auth
    reload(auth)

    class FakeReq:
        headers = {"X-Audit-Token": "  my-token-123  "}
    assert auth._extract_token(FakeReq()) == "my-token-123"


def test_extract_token_bearer():
    from audit_engine.api import auth

    class FakeReq:
        headers = {"Authorization": "Bearer abc-secret"}
    assert auth._extract_token(FakeReq()) == "abc-secret"


def test_extract_token_none():
    from audit_engine.api import auth

    class FakeReq:
        headers: dict = {}
    assert auth._extract_token(FakeReq()) is None


# -----------------------------------------------------------------------
# Integration через TestClient
# -----------------------------------------------------------------------

@pytest.fixture
def client_with_auth():
    """TestClient с включённым auth (2 валидных токена)."""
    try:
        from fastapi.testclient import TestClient
    except ImportError:
        pytest.skip("fastapi.testclient unavailable")

    os.environ["AUDIT_RATE_LIMIT_PER_MIN"] = "5"
    app = _reload_app_with_tokens("token-alpha,token-beta")
    return TestClient(app)


@pytest.fixture
def client_no_auth():
    """TestClient без токенов (backwards-compat)."""
    try:
        from fastapi.testclient import TestClient
    except ImportError:
        pytest.skip("fastapi.testclient unavailable")
    app = _reload_app_with_tokens("")
    return TestClient(app)


def test_auth_disabled_passes_through(client_no_auth):
    """AUDIT_API_TOKENS пуст → middleware прозрачен."""
    r = client_no_auth.get("/")
    assert r.status_code == 200


def test_whitelist_root_no_token(client_with_auth):
    """`/` в whitelist — без токена тоже 200."""
    r = client_with_auth.get("/")
    assert r.status_code == 200


def test_whitelist_health_no_token(client_with_auth):
    """`/api/v2/health` тоже в whitelist."""
    r = client_with_auth.get("/api/v2/health")
    # Может быть 200 или 503 (БД может быть недоступна в тесте), но НЕ 401
    assert r.status_code != 401


def test_protected_endpoint_no_token(client_with_auth):
    """Защищённый endpoint без токена → 401 (даже если path не существует —
    auth выполняется ДО routing)."""
    r = client_with_auth.get("/api/v2/nonexistent-route")
    assert r.status_code == 401
    assert "token" in r.json()["detail"].lower()


def test_protected_endpoint_wrong_token(client_with_auth):
    r = client_with_auth.get(
        "/api/v2/nonexistent-route",
        headers={"X-Audit-Token": "wrong-token"},
    )
    assert r.status_code == 401


def test_protected_endpoint_with_valid_token(client_with_auth):
    r = client_with_auth.get(
        "/api/v2/nonexistent-route",
        headers={"X-Audit-Token": "token-alpha"},
    )
    # Может быть 500 (БД недоступна), 200 — всё что НЕ 401/403
    assert r.status_code not in (401, 403)


def test_protected_endpoint_bearer_token(client_with_auth):
    r = client_with_auth.get(
        "/api/v2/nonexistent-route",
        headers={"Authorization": "Bearer token-beta"},
    )
    assert r.status_code not in (401, 403)


def test_rate_limit_triggers_429(client_with_auth, monkeypatch):
    """6-й запрос за минуту → 429 (limit=5).

    Принудительно используем in-memory bucket — Redis может содержать
    остатки от предыдущих тестов / реальных запросов.
    """
    from audit_engine.api import auth

    async def _force_inmem(token: str):
        return auth._check_rate_limit_inmem(token)

    monkeypatch.setattr(auth, "_check_rate_limit_redis", _force_inmem)
    auth._INMEM_BUCKET.clear()

    # Используем уникальный токен для теста, чтобы не пересекаться с другими
    auth.VALID_TOKENS.add("rl-test-token")
    try:
        for i in range(5):
            r = client_with_auth.get(
                "/api/v2/nonexistent-route",
                headers={"X-Audit-Token": "rl-test-token"},
            )
            assert r.status_code != 429, f"early 429 on request {i+1}"

        r = client_with_auth.get(
            "/api/v2/nonexistent-route",
            headers={"X-Audit-Token": "rl-test-token"},
        )
        assert r.status_code == 429
        assert "rate limit" in r.json()["detail"].lower()
        assert r.headers.get("Retry-After") == "60"
    finally:
        auth.VALID_TOKENS.discard("rl-test-token")
