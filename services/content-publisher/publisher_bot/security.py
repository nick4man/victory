"""
security.py — Iron Isolation Module
Жёсткий whitelist для всех исходящих сообщений бота публикаций (@victory62_bot).

УТВЕРЖДЕНО: 2026-04-16. Босс: финальная стратегия безопасности без новых ботов.
ПРИНЦИП: Бот публикаций имеет право слать сообщения ТОЛЬКО в разрешённые цели.
"""

import logging

logger = logging.getLogger(__name__)

# ===== ЖЁСТКИЙ WHITELIST =====
# Любое изменение требует явного решения Босса.

ALLOWED_TARGETS = {
    "@rznvictory",          # Канал публикаций — основная цель бота
    "1272500574",           # Оксана/Д'Артаньян — approval flow
    "1068744275",           # Chief Editor (Сергей/Главред) — эскалация и доработки
}

# Преобразуем к строкам для сравнения
_ALLOWED_STR = {str(t) for t in ALLOWED_TARGETS}


class TargetBlockedError(Exception):
    """Raised when a message target is not in the whitelist."""
    pass


def assert_allowed_target(chat_id) -> None:
    """
    Проверяет, что адресат находится в whitelist.
    Вызывать ПЕРЕД каждым bot.send_message / bot.send_photo / bot.send_document.

    Raises:
        TargetBlockedError: если цель не разрешена.
    """
    target_str = str(chat_id)
    if target_str not in _ALLOWED_STR:
        logger.error(
            f"SECURITY BLOCK: attempt to send message to FORBIDDEN target: {chat_id}. "
            f"Allowed: {ALLOWED_TARGETS}"
        )
        raise TargetBlockedError(
            f"Target '{chat_id}' is NOT in the whitelist. "
            f"Allowed targets: {ALLOWED_TARGETS}"
        )
    logger.debug(f"Security check passed for target: {chat_id}")