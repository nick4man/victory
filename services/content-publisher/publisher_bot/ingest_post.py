#!/usr/bin/env python3
"""
Скрипт инжеста постов для Creative Conveyor 2.0.
Добавляет новые посты в очередь публикации (таблица posts_queue).
Поддерживает CLI-аргументы и batch-инжест из JSON-файла.
"""

import argparse
import asyncio
import asyncpg
import json
import logging
import os
import sys
from datetime import datetime, date, timedelta
from typing import Optional, List, Dict, Any
from pathlib import Path

# Настройка логирования
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Допустимые типы контента (Creative Conveyor 2.0)
ALLOWED_CONTENT_TYPES = {'post', 'listing', 'story', 'article', 'reels', 'promo'}

# Конфигурация БД
DATABASE_URL = os.environ["DATABASE_URL"]  # обязателен; дефолта с паролем здесь больше нет


def parse_date(date_str: str) -> Optional[datetime]:
    """Парсит строку даты в datetime (с временем 23:59:59 MSK).
    Поддерживает форматы:
        - YYYY-MM-DD
        - YYYY-MM-DD HH:MM
        - YYYY-MM-DD HH:MM:SS
    Если время не указано, ставим 23:59:59 (дедлайн на конец дня).
    """
    try:
        # Сначала попробуем как дата
        if len(date_str) == 10:
            d = datetime.strptime(date_str, "%Y-%m-%d")
            # Дедлайн на конец дня по Москве (но в БД хранится как TIMESTAMPTZ)
            # Для простоты оставляем время 23:59:59
            return d.replace(hour=23, minute=59, second=59)
        # Пробуем с временем
        for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
            try:
                return datetime.strptime(date_str, fmt)
            except ValueError:
                pass
        raise ValueError(f"Неверный формат даты: {date_str}")
    except Exception as e:
        logger.error(f"Ошибка парсинга даты '{date_str}': {e}")
        raise


async def insert_post(
    pool: asyncpg.Pool,
    project_name: str,
    request_text: str,
    content_type: str = "post",
    deadline: Optional[datetime] = None,
    is_urgent: bool = False,
    requester: str = "Генерал",
    media_path: Optional[str] = None,
) -> dict:
    """Добавляет один пост в таблицу posts_queue.
    Возвращает словарь с добавленной записью.
    """
    query = """
        INSERT INTO posts_queue (
            project_name,
            content_type,
            requester,
            request_text,
            deadline,
            is_urgent,
            media_path,
            status,
            requested_at,
            created_by
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, 'DRAFT', NOW(), $8)
        RETURNING id, project_name, content_type, requester, request_text,
                  deadline, is_urgent, media_path, status, requested_at
    """
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            query,
            project_name,
            content_type,
            requester,
            request_text,
            deadline,
            is_urgent,
            media_path,
            requester  # created_by
        )
        return dict(row)


async def insert_posts_from_json(pool: asyncpg.Pool, json_path: Path) -> List[dict]:
    """Добавляет несколько постов из JSON-файла."""
    with open(json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    if not isinstance(data, list):
        raise ValueError("JSON должен содержать массив объектов")
    
    results = []
    for idx, item in enumerate(data):
        try:
            # Валидация обязательных полей
            project_name = item.get("project_name")
            if not project_name:
                raise ValueError(f"Объект {idx}: отсутствует project_name")
            request_text = item.get("request_text")
            if not request_text:
                raise ValueError(f"Объект {idx}: отсутствует request_text")
            
            # Контент-тип
            content_type = item.get("content_type", "post")
            if content_type not in ALLOWED_CONTENT_TYPES:
                logger.warning(
                    f"Объект {idx}: нестандартный content_type '{content_type}'. "
                    f"Допустимые: {', '.join(sorted(ALLOWED_CONTENT_TYPES))}"
                )
            
            # Дедлайн
            deadline = None
            if "deadline" in item:
                deadline = parse_date(item["deadline"])
            
            # Остальные поля
            is_urgent = item.get("is_urgent", False)
            requester = item.get("requester", "Генерал")
            media_path = item.get("media_path")
            
            # Вставка
            result = await insert_post(
                pool,
                project_name,
                request_text,
                content_type,
                deadline,
                is_urgent,
                requester,
                media_path,
            )
            results.append(result)
            logger.info(f"✅ Пост добавлен из JSON (idx {idx}): ID {result['id']}")
            
        except Exception as e:
            logger.error(f"❌ Ошибка при обработке объекта {idx}: {e}")
            # Продолжаем обработку остальных постов
            continue
    
    return results


def print_post_summary(post: dict):
    """Выводит красивое сообщение о добавленном посте."""
    deadline_str = "не указан"
    if post.get("deadline"):
        dl = post["deadline"]
        if isinstance(dl, datetime):
            deadline_str = dl.strftime("%Y-%m-%d")
        elif isinstance(dl, date):
            deadline_str = dl.strftime("%Y-%m-%d")
        else:
            deadline_str = str(dl)
    
    urgent_str = "да" if post.get("is_urgent") else "нет"
    
    print("\n" + "=" * 50)
    print("✅ Пост добавлен в очередь:")
    print(f"   ID: {post['id']}")
    print(f"   Проект: {post['project_name']}")
    print(f"   Тип: {post['content_type']}")
    print(f"   Статус: {post.get('status', 'DRAFT')}")
    print(f"   Дедлайн: {deadline_str}")
    print(f"   Срочный: {urgent_str}")
    print(f"   Запросил: {post.get('requester', 'Генерал')}")
    if post.get("media_path"):
        print(f"   Медиа: {post['media_path']}")
    print("=" * 50 + "\n")


async def main():
    parser = argparse.ArgumentParser(
        description="Добавление поста в очередь Creative Conveyor 2.0",
        epilog="Примеры:\n"
               "  python3 ingest_post.py --project 'ЖК Полянка' --text 'Текст поста'\n"
               "  python3 ingest_post.py --project 'ЖК Полянка' --text 'Текст' --type listing --deadline 2026-04-18 --urgent\n"
               "  python3 ingest_post.py --from-json posts.json",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    
    # Режим CLI
    parser.add_argument(
        "--project", "-p",
        required=False,  # обязательность проверяем позже
        help="Название проекта (например, 'ЖК Полянка')",
    )
    parser.add_argument(
        "--text", "-t",
        required=False,
        help="Текст запроса/описания поста",
    )
    parser.add_argument(
        "--type",
        default="post",
        choices=ALLOWED_CONTENT_TYPES,
        help="Тип контента (по умолчанию 'post')",
    )
    parser.add_argument(
        "--deadline", "-d",
        help="Дедлайн в формате YYYY-MM-DD (или YYYY-MM-DD HH:MM)",
    )
    parser.add_argument(
        "--urgent",
        action="store_true",
        help="Пометить пост как срочный",
    )
    parser.add_argument(
        "--requester", "-r",
        default="Генерал",
        help="Имя запросившего (по умолчанию 'Генерал')",
    )
    parser.add_argument(
        "--media", "-m",
        help="Путь к медиафайлу (изображение, видео)",
    )
    
    # Режим JSON
    parser.add_argument(
        "--from-json",
        help="Добавить посты из JSON-файла (batch-инжест)",
    )
    
    args = parser.parse_args()
    
    # Проверка режимов
    if args.from_json:
        if any([args.project, args.text]):
            logger.warning("Аргументы CLI игнорируются, используется режим JSON")
        # Режим JSON
        json_path = Path(args.from_json)
        if not json_path.exists():
            logger.error(f"Файл {json_path} не найден")
            sys.exit(1)
        
        try:
            pool = await asyncpg.create_pool(DATABASE_URL)
            results = await insert_posts_from_json(pool, json_path)
            for post in results:
                print_post_summary(post)
            logger.info(f"Обработано {len(results)} постов из JSON")
        except Exception as e:
            logger.error(f"Ошибка при batch-инжесте: {e}")
            sys.exit(1)
        finally:
            if pool:
                await pool.close()
        return
    
    # Режим CLI
    if not args.project or not args.text:
        logger.error("В режиме CLI обязательны --project и --text")
        parser.print_help()
        sys.exit(1)
    
    # Валидация типа
    if args.type not in ALLOWED_CONTENT_TYPES:
        logger.warning(
            f"Тип '{args.type}' не входит в стандартный набор. "
            f"Допустимые: {', '.join(sorted(ALLOWED_CONTENT_TYPES))}"
        )
    
    # Парсинг дедлайна
    deadline = None
    if args.deadline:
        try:
            deadline = parse_date(args.deadline)
        except Exception as e:
            logger.error(f"Некорректный дедлайн: {e}")
            sys.exit(1)
    
    # Подключение к БД
    try:
        pool = await asyncpg.create_pool(DATABASE_URL)
    except Exception as e:
        logger.error(f"Не удалось подключиться к БД: {e}")
        sys.exit(1)
    
    # Вставка
    try:
        post = await insert_post(
            pool,
            args.project,
            args.text,
            args.type,
            deadline,
            args.urgent,
            args.requester,
            args.media,
        )
        print_post_summary(post)
        logger.info(f"Пост успешно добавлен с ID {post['id']}")
    except Exception as e:
        logger.error(f"Ошибка при добавлении поста: {e}")
        sys.exit(1)
    finally:
        await pool.close()


if __name__ == "__main__":
    asyncio.run(main())