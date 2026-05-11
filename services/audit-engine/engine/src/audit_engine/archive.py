"""
Audit Archive — Модуль сохранения и поиска аудитов.

Обеспечивает:
- Автоматическое сохранение результатов после генерации PDF
- Поиск по архиву (по адресу, дате, вердикту, тегам)
- Получение полной карточки аудита по UUID
"""

from __future__ import annotations
import json
from datetime import date, datetime
from typing import Optional
from uuid import UUID

from sqlalchemy import text

from audit_engine.db import get_session
from audit_engine.models import AuditInput, AuditResult, RetroResult


# ========================
# SAVE
# ========================

async def save_to_archive(
    audit_input: AuditInput,
    audit_result: AuditResult,
    retro_result: RetroResult | None = None,
    *,
    object_address: str | None = None,
    calculation_period: str | None = None,
    complex_id: int | None = None,
    apartment_id: int | None = None,
    inflation: float = 8.0,
    report_pdf_path: str | None = None,
    detail_pdf_path: str | None = None,
    report_md_path: str | None = None,
    created_by: str = "audit_engine",
    notes: str | None = None,
    tags: list[str] | None = None,
) -> str:
    """
    Сохранить результат аудита в реестр audit_archive.
    
    Args:
        audit_input: Входные параметры аудита.
        audit_result: Полный результат аудита (матрица 3×3).
        retro_result: Результат ретроспективы (опционально).
        object_address: Полный адрес объекта. Если не указан — формируется из complex_name + apartment_type.
        calculation_period: Период расчёта (напр. "октябрь 2025").
        complex_id: ID ЖК в БД (если известен).
        apartment_id: ID квартиры в БД (если известен).
        inflation: Инфляция, использованная в расчёте.
        report_pdf_path: Путь к итоговому PDF.
        detail_pdf_path: Путь к PDF-детализации.
        report_md_path: Путь к Markdown-отчёту.
        created_by: Автор записи.
        notes: Заметки аудитора.
        tags: Теги для классификации.
    
    Returns:
        UUID созданной записи (строка).
    """
    # Формируем адрес, если не передан
    if not object_address:
        object_address = f"ЖК «{audit_input.complex_name}», {audit_input.apartment_type}, {audit_input.area_sqm} м²"
    
    # Собираем полный input_params
    input_params = audit_input.model_dump()
    input_params["inflation"] = inflation
    
    # Собираем EI-матрицу
    ei_matrix = {}
    for scenario in audit_result.scenarios:
        ei_matrix[scenario.scenario_name] = {
            "cash": scenario.cash.ei,
            "deposit": scenario.deposit.ei,
            "mortgage": scenario.mortgage.ei,
            "best_strategy": scenario.best_strategy,
            "params": scenario.params.model_dump(),
        }
    
    # Определяем EI по сценариям (ипотечный EI как основной по каждому сценарию)
    ei_optimistic = None
    ei_realistic = None
    ei_pessimistic = None
    for scenario in audit_result.scenarios:
        name_lower = scenario.scenario_name.lower()
        mortgage_ei = scenario.mortgage.ei
        if "оптимист" in name_lower:
            ei_optimistic = mortgage_ei
        elif "реалист" in name_lower:
            ei_realistic = mortgage_ei
        elif "пессимист" in name_lower:
            ei_pessimistic = mortgage_ei
    
    # Модули расчёта
    calc_modules = ["ei_calculator", "scenario_builder"]
    if retro_result:
        calc_modules.append("retro_analyzer")
    calc_modules.append("report_generator")
    calc_modules.append("pdf_branded")
    
    # Ретроспективные данные
    has_retro = retro_result is not None
    retro_data = None
    if retro_result:
        retro_data = retro_result.model_dump()
    
    async with get_session() as session:
        result = await session.execute(
            text("""
                INSERT INTO audit_archive (
                    complex_id, apartment_id, object_address, apartment_type, area_sqm,
                    audit_date, calculation_period,
                    price_total, price_per_sqm, mortgage_rate, deposit_rate,
                    down_payment_pct, mortgage_term_years, monthly_rent,
                    price_growth_annual, horizon_years, cash_discount_pct, inflation,
                    input_params,
                    ei_cash, ei_deposit, ei_mortgage,
                    ei_optimistic, ei_realistic, ei_pessimistic,
                    ei_matrix, calculation_modules, engine_version,
                    verdict, verdict_explanation, risks, assumptions,
                    report_pdf_path, detail_pdf_path, report_md_path,
                    has_retro, retro_data,
                    created_by, notes, tags
                ) VALUES (
                    :complex_id, :apartment_id, :object_address, :apartment_type, :area_sqm,
                    :audit_date, :calculation_period,
                    :price_total, :price_per_sqm, :mortgage_rate, :deposit_rate,
                    :down_payment_pct, :mortgage_term_years, :monthly_rent,
                    :price_growth_annual, :horizon_years, :cash_discount_pct, :inflation,
                    :input_params::jsonb,
                    :ei_cash, :ei_deposit, :ei_mortgage,
                    :ei_optimistic, :ei_realistic, :ei_pessimistic,
                    :ei_matrix::jsonb, :calculation_modules, :engine_version,
                    :verdict, :verdict_explanation, :risks, :assumptions,
                    :report_pdf_path, :detail_pdf_path, :report_md_path,
                    :has_retro, :retro_data::jsonb,
                    :created_by, :notes, :tags
                ) RETURNING id::text
            """),
            {
                "complex_id": complex_id,
                "apartment_id": apartment_id,
                "object_address": object_address,
                "apartment_type": audit_input.apartment_type,
                "area_sqm": audit_input.area_sqm,
                "audit_date": audit_result.audit_date,
                "calculation_period": calculation_period,
                "price_total": audit_input.price_total,
                "price_per_sqm": audit_result.price_per_sqm,
                "mortgage_rate": audit_input.mortgage_rate,
                "deposit_rate": audit_input.deposit_rate,
                "down_payment_pct": audit_input.down_payment_pct,
                "mortgage_term_years": audit_input.mortgage_term_years,
                "monthly_rent": audit_input.monthly_rent,
                "price_growth_annual": audit_input.price_growth_annual,
                "horizon_years": audit_input.horizon_years,
                "cash_discount_pct": audit_input.cash_discount_pct,
                "inflation": inflation,
                "input_params": json.dumps(input_params, ensure_ascii=False),
                "ei_cash": audit_result.ei_cash,
                "ei_deposit": audit_result.ei_deposit,
                "ei_mortgage": audit_result.ei_mortgage,
                "ei_optimistic": ei_optimistic,
                "ei_realistic": ei_realistic,
                "ei_pessimistic": ei_pessimistic,
                "ei_matrix": json.dumps(ei_matrix, ensure_ascii=False),
                "calculation_modules": calc_modules,
                "engine_version": "1.0.0",
                "verdict": audit_result.verdict.value,
                "verdict_explanation": audit_result.verdict_explanation,
                "risks": audit_result.risks,
                "assumptions": audit_result.assumptions,
                "report_pdf_path": report_pdf_path,
                "detail_pdf_path": detail_pdf_path,
                "report_md_path": report_md_path,
                "has_retro": has_retro,
                "retro_data": json.dumps(retro_data, ensure_ascii=False, default=str) if retro_data else None,
                "created_by": created_by,
                "notes": notes,
                "tags": tags or [],
            },
        )
        archive_id = result.scalar()
        return archive_id


# ========================
# SEARCH
# ========================

async def search_archive(
    *,
    query: str | None = None,
    address: str | None = None,
    complex_name: str | None = None,
    apartment_type: str | None = None,
    verdict: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    tags: list[str] | None = None,
    limit: int = 20,
    offset: int = 0,
) -> list[dict]:
    """
    Поиск по архиву аудитов с гибкой фильтрацией.
    
    Args:
        query: Свободный текстовый поиск (по адресу, нечёткий).
        address: Точный/частичный адрес.
        complex_name: Имя ЖК (через join).
        apartment_type: Тип квартиры.
        verdict: Фильтр по вердикту (BUY/WAIT/NEUTRAL).
        date_from: Дата аудита «от» (YYYY-MM-DD).
        date_to: Дата аудита «до» (YYYY-MM-DD).
        tags: Фильтр по тегам (ANY).
        limit: Макс. записей.
        offset: Смещение.
    
    Returns:
        Список словарей с основными полями.
    """
    conditions = []
    params: dict = {"limit": limit, "offset": offset}
    
    if query:
        conditions.append("aa.object_address % :query")
        params["query"] = query
    
    if address:
        conditions.append("aa.object_address ILIKE :address")
        params["address"] = f"%{address}%"
    
    if complex_name:
        conditions.append("c.name ILIKE :complex_name")
        params["complex_name"] = f"%{complex_name}%"
    
    if apartment_type:
        conditions.append("aa.apartment_type = :apartment_type")
        params["apartment_type"] = apartment_type
    
    if verdict:
        conditions.append("aa.verdict = :verdict")
        params["verdict"] = verdict.upper()
    
    if date_from:
        conditions.append("aa.audit_date >= :date_from")
        params["date_from"] = date_from
    
    if date_to:
        conditions.append("aa.audit_date <= :date_to")
        params["date_to"] = date_to
    
    if tags:
        conditions.append("aa.tags && :tags")
        params["tags"] = tags
    
    where_clause = ""
    if conditions:
        where_clause = "WHERE " + " AND ".join(conditions)
    
    sql = f"""
        SELECT 
            aa.id::text,
            aa.object_address,
            aa.apartment_type,
            aa.area_sqm,
            aa.audit_date,
            aa.calculation_period,
            aa.price_total,
            aa.price_per_sqm,
            aa.ei_cash,
            aa.ei_deposit,
            aa.ei_mortgage,
            aa.verdict,
            aa.verdict_explanation,
            aa.report_pdf_path,
            aa.detail_pdf_path,
            aa.has_retro,
            aa.tags,
            aa.created_at,
            c.name AS complex_name,
            d.name AS developer_name
        FROM audit_archive aa
        LEFT JOIN complexes c ON aa.complex_id = c.id
        LEFT JOIN developers d ON c.developer_id = d.id
        {where_clause}
        ORDER BY aa.audit_date DESC, aa.created_at DESC
        LIMIT :limit OFFSET :offset
    """
    
    async with get_session() as session:
        result = await session.execute(text(sql), params)
        rows = result.fetchall()
        return [dict(row._mapping) for row in rows]


async def get_archive_entry(audit_id: str) -> dict | None:
    """
    Получить полную карточку аудита по UUID.
    
    Args:
        audit_id: UUID аудита (строка).
    
    Returns:
        Полный словарь записи или None.
    """
    async with get_session() as session:
        result = await session.execute(
            text("""
                SELECT 
                    aa.*,
                    aa.id::text as id_str,
                    c.name AS complex_name,
                    d.name AS developer_name
                FROM audit_archive aa
                LEFT JOIN complexes c ON aa.complex_id = c.id
                LEFT JOIN developers d ON c.developer_id = d.id
                WHERE aa.id = :audit_id::uuid
            """),
            {"audit_id": audit_id},
        )
        row = result.first()
        if row:
            return dict(row._mapping)
        return None


async def get_archive_stats() -> dict:
    """
    Статистика архива: сколько аудитов, по вердиктам, последний аудит.
    
    Returns:
        Словарь со статистикой.
    """
    async with get_session() as session:
        result = await session.execute(text("""
            SELECT 
                COUNT(*) as total,
                COUNT(*) FILTER (WHERE verdict = 'BUY') as buy_count,
                COUNT(*) FILTER (WHERE verdict = 'WAIT') as wait_count,
                COUNT(*) FILTER (WHERE verdict = 'NEUTRAL') as neutral_count,
                MAX(audit_date) as last_audit_date,
                MIN(audit_date) as first_audit_date,
                COUNT(DISTINCT complex_id) as unique_complexes,
                AVG(ei_mortgage) as avg_ei_mortgage
            FROM audit_archive
        """))
        row = result.first()
        if row:
            return dict(row._mapping)
        return {}


async def update_archive_files(
    audit_id: str,
    *,
    report_pdf_path: str | None = None,
    detail_pdf_path: str | None = None,
    report_md_path: str | None = None,
) -> bool:
    """
    Обновить пути к файлам для существующего аудита.
    Полезно, когда PDF генерируется отдельным шагом.
    
    Args:
        audit_id: UUID аудита.
        report_pdf_path: Путь к итоговому PDF.
        detail_pdf_path: Путь к PDF-детализации.
        report_md_path: Путь к Markdown-отчёту.
    
    Returns:
        True, если запись обновлена.
    """
    updates = []
    params = {"audit_id": audit_id}
    
    if report_pdf_path is not None:
        updates.append("report_pdf_path = :report_pdf_path")
        params["report_pdf_path"] = report_pdf_path
    if detail_pdf_path is not None:
        updates.append("detail_pdf_path = :detail_pdf_path")
        params["detail_pdf_path"] = detail_pdf_path
    if report_md_path is not None:
        updates.append("report_md_path = :report_md_path")
        params["report_md_path"] = report_md_path
    
    if not updates:
        return False
    
    sql = f"UPDATE audit_archive SET {', '.join(updates)} WHERE id = :audit_id::uuid"
    
    async with get_session() as session:
        result = await session.execute(text(sql), params)
        return result.rowcount > 0


async def add_archive_notes(audit_id: str, notes: str) -> bool:
    """Добавить заметки к аудиту."""
    async with get_session() as session:
        result = await session.execute(
            text("""
                UPDATE audit_archive 
                SET notes = COALESCE(notes, '') || E'\n' || :notes
                WHERE id = :audit_id::uuid
            """),
            {"audit_id": audit_id, "notes": notes},
        )
        return result.rowcount > 0


async def add_archive_tags(audit_id: str, new_tags: list[str]) -> bool:
    """Добавить теги к аудиту (без дублирования)."""
    async with get_session() as session:
        result = await session.execute(
            text("""
                UPDATE audit_archive 
                SET tags = ARRAY(SELECT DISTINCT unnest(tags || :new_tags))
                WHERE id = :audit_id::uuid
            """),
            {"audit_id": audit_id, "new_tags": new_tags},
        )
        return result.rowcount > 0
