import logging
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from datetime import datetime, timedelta
import pytz
from db_client import db
from publisher_bot import publish_post
from approval_bot import send_for_approval
from config import config

logger = logging.getLogger(__name__)

async def job_publish_due(bot):
    """Job 1: Check and publish scheduled posts"""
    posts = await db.get_scheduled_posts_due()
    for post in posts:
        await publish_post(bot, post['id'])

async def job_remind_approval(bot):
    """Job 2: Remind Oksana about pending posts"""
    posts = await db.get_posts_by_status('WAITING_APPROVAL')
    now = datetime.now()
    timeout = timedelta(hours=config.approval_timeout_hours)
    
    for post in posts:
        # FIX 2026-04-16: schema uses 'requested_at', not 'created_at'
        post_time = post.get('requested_at') or post.get('updated_at')
        if post_time and post_time.tzinfo:
            post_time = post_time.replace(tzinfo=None)
        if post_time and now - post_time > timeout:
            # v2: reminders go to Dartagnan (realtor-assistant proxy), not directly to Oksana
            await bot.send_message(
                chat_id=config.dartagnan_chat_id,
                text=f"⏳ *Напоминание:* Пост #{post['id']} ожидает аппрува более {config.approval_timeout_hours}ч.",
                parse_mode='Markdown'
            )

async def job_escalate_approval(bot):
    """Job 3: Escalate to Chief Editor if post is stuck"""
    posts = await db.get_posts_by_status('WAITING_APPROVAL')
    now = datetime.now()
    escalation = timedelta(hours=config.approval_escalation_hours)
    
    for post in posts:
        # FIX 2026-04-16: schema uses 'requested_at', not 'created_at'
        post_time = post.get('requested_at') or post.get('updated_at')
        if post_time and post_time.tzinfo:
            post_time = post_time.replace(tzinfo=None)
        if post_time and now - post_time > escalation:
            await bot.send_message(
                chat_id=config.chief_editor_chat_id,
                text=f"🚨 *Эскалация:* Пост #{post['id']} без ответа более {config.approval_escalation_hours}ч. Просьба проверить.",
                parse_mode='Markdown'
            )

def setup_scheduler(bot):
    scheduler = AsyncIOScheduler(timezone=pytz.timezone('Europe/Moscow'))
    
    scheduler.add_job(job_publish_due, 'interval', minutes=5, args=[bot])
    # scheduler.add_job(job_remind_approval, 'interval', minutes=30, args=[bot])
    # scheduler.add_job(job_escalate_approval, 'interval', minutes=60, args=[bot])
    
    return scheduler
