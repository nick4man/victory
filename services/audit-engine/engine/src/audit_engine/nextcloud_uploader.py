"""
Nextcloud Uploader — Автоматическая выгрузка PDF-отчётов на Nextcloud.

Использует rclone alias 'nxt' → nextcloud.
Формат пути: nxt:Офис/НЕДВИЖИМОСТЬ/Отчёты по аудиту/<дата> - <ЖК: адрес>/

Модуль интегрируется в audit_engine и вызывается после генерации PDF.
"""

from __future__ import annotations

import subprocess
import logging
import time
from pathlib import Path
from datetime import date

logger = logging.getLogger(__name__)

# rclone remote alias
RCLONE_REMOTE = "nxt"
NEXTCLOUD_BASE_PATH = "Офис/НЕДВИЖИМОСТЬ/Отчёты по аудиту"

# rclone может падать по сети; фиксируем до 3 попыток с экспоненциальным backoff.
_RCLONE_MAX_ATTEMPTS = 3
_RCLONE_BACKOFF_SEC = 2.0


def _run_rclone_with_retry(cmd: list[str], timeout: int, label: str) -> bool:
    """Запустить rclone с retry при сетевых сбоях / таймаутах.

    Возвращает True при успехе хотя бы с одной попытки.
    FileNotFoundError (rclone не установлен) не ретраится — сразу False.
    """
    delay = _RCLONE_BACKOFF_SEC
    for attempt in range(1, _RCLONE_MAX_ATTEMPTS + 1):
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout,
            )
            if result.returncode == 0:
                if attempt > 1:
                    logger.info("✅ %s: успех с %d-й попытки", label, attempt)
                return True
            logger.warning(
                "rclone rc=%d на попытке %d/%d (%s): %s",
                result.returncode, attempt, _RCLONE_MAX_ATTEMPTS, label,
                result.stderr.strip()[:200],
            )
        except subprocess.TimeoutExpired:
            logger.warning(
                "⏱ Таймаут rclone на попытке %d/%d (%s)",
                attempt, _RCLONE_MAX_ATTEMPTS, label,
            )
        except FileNotFoundError:
            logger.error("rclone не установлен или не найден в PATH")
            return False

        if attempt < _RCLONE_MAX_ATTEMPTS:
            time.sleep(delay)
            delay *= 2

    logger.error("❌ %s: все %d попыток rclone провалились", label, _RCLONE_MAX_ATTEMPTS)
    return False


def _build_remote_dir(complex_name: str, audit_date: str | date | None = None) -> str:
    """
    Построить путь на Nextcloud для выгрузки.

    Формат: nxt:Офис/НЕДВИЖИМОСТЬ/Отчёты по аудиту/<дата> - <ЖК>

    Args:
        complex_name: Название ЖК (напр. "ЖК 1-й Донской").
        audit_date: Дата аудита (строка YYYY-MM-DD или date). 
                    Если None — используется сегодня.

    Returns:
        Полный rclone-путь вида "nxt:Офис/.../2026-04-13 - ЖК 1-й Донской"
    """
    if audit_date is None:
        audit_date = date.today().isoformat()
    elif isinstance(audit_date, date):
        audit_date = audit_date.isoformat()

    folder_name = f"{audit_date} - {complex_name}"
    return f"{RCLONE_REMOTE}:{NEXTCLOUD_BASE_PATH}/{folder_name}"


def upload_file(
    local_path: str | Path,
    complex_name: str,
    audit_date: str | date | None = None,
    timeout: int = 120,
) -> bool:
    """
    Выгрузить один файл на Nextcloud.

    Args:
        local_path: Локальный путь к файлу (PDF или MD).
        complex_name: Название ЖК.
        audit_date: Дата аудита (YYYY-MM-DD).
        timeout: Таймаут выгрузки в секундах.

    Returns:
        True если выгрузка успешна, False иначе.
    """
    local_path = Path(local_path)
    if not local_path.exists():
        logger.error(f"Файл не найден: {local_path}")
        return False

    remote_dir = _build_remote_dir(complex_name, audit_date)

    cmd = [
        "rclone", "copy",
        str(local_path),
        f"{remote_dir}/",
        "--no-traverse",
    ]

    logger.info(f"Выгрузка: {local_path.name} → {remote_dir}/")
    return _run_rclone_with_retry(cmd, timeout, label=f"upload {local_path.name}")


def upload_reports(
    report_dir: str | Path,
    complex_name: str,
    audit_date: str | date | None = None,
    pattern: str = "*.pdf",
    timeout: int = 120,
) -> dict[str, bool]:
    """
    Выгрузить все отчёты из директории.

    Args:
        report_dir: Директория с отчётами.
        complex_name: Название ЖК.
        audit_date: Дата аудита.
        pattern: Glob-паттерн файлов (по умолчанию *.pdf).
        timeout: Таймаут на каждый файл.

    Returns:
        Словарь {filename: success_bool}.
    """
    report_dir = Path(report_dir)
    if not report_dir.is_dir():
        logger.error(f"Директория не найдена: {report_dir}")
        return {}

    files = sorted(report_dir.glob(pattern))
    if not files:
        logger.warning(f"Нет файлов по паттерну '{pattern}' в {report_dir}")
        return {}

    results = {}
    for f in files:
        results[f.name] = upload_file(f, complex_name, audit_date, timeout)

    # Summary
    ok = sum(1 for v in results.values() if v)
    total = len(results)
    logger.info(f"📊 Итого выгружено: {ok}/{total} файлов в Nextcloud")

    return results


def upload_batch_rclone(
    report_dir: str | Path,
    complex_name: str,
    audit_date: str | date | None = None,
    pattern: str = "*.pdf",
    timeout: int = 300,
) -> bool:
    """
    Пакетная выгрузка всей директории через один вызов rclone copy.
    Более эффективно, чем поштучно.

    Args:
        report_dir: Директория с отчётами.
        complex_name: Название ЖК.
        audit_date: Дата аудита.
        pattern: Glob-фильтр (используется --include).
        timeout: Общий таймаут.

    Returns:
        True если выгрузка прошла успешно.
    """
    report_dir = Path(report_dir)
    if not report_dir.is_dir():
        logger.error(f"Директория не найдена: {report_dir}")
        return False

    remote_dir = _build_remote_dir(complex_name, audit_date)

    cmd = [
        "rclone", "copy",
        str(report_dir),
        f"{remote_dir}/",
        "--include", pattern,
        "--no-traverse",
    ]

    logger.info(f"Пакетная выгрузка: {report_dir} → {remote_dir}/")
    return _run_rclone_with_retry(cmd, timeout, label=f"batch {report_dir.name}")
