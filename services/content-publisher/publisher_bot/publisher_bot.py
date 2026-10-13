import asyncio
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path
from telegram.error import TelegramError
from config import config
from db_client import db
from security import assert_allowed_target

# Импорт модуля очистки (опционально)
try:
    sys.path.append('/opt/.openclaw/.openclaw/workspace/agents/python-senior')
    from cleanup_manager import cleanup_after_publish
    CLEANUP_AVAILABLE = True
except ImportError as e:
    logging.getLogger(__name__).warning(f"Модуль очистки недоступен: {e}")
    CLEANUP_AVAILABLE = False

logger = logging.getLogger(__name__)

async def publish_post(bot, post_id: int):
    """Publish post to the channel"""
    post = await db.get_post(post_id)
    if not post:
        logger.error(f"Post #{post_id} not found for publication")
        return False

    # ✅ DEDUPLICATION GUARD #1: pre-flight status check
    # Only SCHEDULED posts are allowed to proceed. Any other status
    # (including PUBLISHED) means the post was already handled — abort immediately.
    if post['status'] != 'SCHEDULED':
        logger.warning(
            f"[DEDUP] Post #{post_id} skipped — current status is '{post['status']}', "
            f"expected 'SCHEDULED'. Possible duplicate trigger."
        )
        return False

    retries = 3
    success = False
    
    for attempt in range(retries):
        try:
            # ✅ DEDUPLICATION GUARD #2: atomic status transition
            # Set status to PUBLISHING before sending to Telegram.
            # If another worker or scheduler tick picks up the same post
            # before the first send completes, it will see PUBLISHING (not SCHEDULED)
            # and bail out via guard #1. This closes the race window.
            transitioned = await db.try_transition_status(post_id, from_status='SCHEDULED', to_status='PUBLISHING')
            if not transitioned:
                logger.warning(
                    f"[DEDUP] Post #{post_id} atomic transition SCHEDULED→PUBLISHING failed "
                    f"(another worker already claimed it). Aborting."
                )
                return False

            # 🔴 IRON ISOLATION: whitelist check before publishing
            assert_allowed_target(config.rznvictory_channel)
            # Check if post has media
            if post.get('media_path') and post.get('media_approved'):
                with open(post['media_path'], 'rb') as photo:
                    message = await bot.send_photo(
                        chat_id=config.rznvictory_channel,
                        photo=photo,
                        caption=post['smm_text'],
                        parse_mode='HTML'
                    )
            else:
                message = await bot.send_message(
                    chat_id=config.rznvictory_channel,
                    text=post['smm_text'],
                    parse_mode='HTML'
                )
            
            # ✅ Mark as PUBLISHED with exact datetime and tg_message_id
            await db.update_post_status(
                post_id,
                'PUBLISHED',
                published_at=datetime.now(timezone.utc),
                tg_message_id=message.message_id
            )
            
            logger.info(f"Successfully published post #{post_id} (tg_msg_id={message.message_id})")
            
            # Автоматическая очистка локальных файлов после публикации
            if CLEANUP_AVAILABLE:
                try:
                    posts_queue_dir = Path(__file__).parent.parent / "posts_queue"
                    # dry_run=False — реальное удаление
                    result = await cleanup_after_publish(post_id, db, posts_queue_dir, dry_run=False)
                    logger.info(f"Очистка файлов поста #{post_id}: удалено {len(result.get('deleted', []))} файлов")
                except Exception as cleanup_err:
                    logger.error(f"Ошибка при очистке файлов поста #{post_id}: {cleanup_err}")
            else:
                logger.warning(f"Модуль очистки недоступен, локальные файлы поста #{post_id} не удалены")
            
            success = True
            break
            
        except Exception as e:
            logger.warning(f"Attempt {attempt + 1} failed to publish post #{post_id}: {e}")
            # ✅ Roll back PUBLISHING → SCHEDULED so next scheduler tick can retry
            try:
                await db.try_transition_status(post_id, from_status='PUBLISHING', to_status='SCHEDULED')
                logger.info(f"Post #{post_id} rolled back to SCHEDULED for retry")
            except Exception as rollback_err:
                logger.error(f"Failed to roll back post #{post_id}: {rollback_err}")

            if attempt < retries - 1:
                await asyncio.sleep(300)  # 5 min pause between retries
            else:
                # All retries exhausted — mark as FAILED and alert Chief Editor
                try:
                    await db.update_post_status(post_id, 'FAILED')
                except Exception:
                    pass
                # 🔴 IRON ISOLATION: whitelist check before alerting
                assert_allowed_target(config.chief_editor_chat_id)
                await bot.send_message(
                    chat_id=config.chief_editor_chat_id,
                    text=f"🚨 *Ошибка публикации поста #{post_id}*\n\nПосле {retries} попыток: {str(e)}",
                    parse_mode='Markdown'
                )

    return success
