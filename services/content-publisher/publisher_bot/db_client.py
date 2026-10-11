import asyncio
import asyncpg
from datetime import datetime, time, date, timedelta
from typing import List, Optional, Dict, Any
import logging
import pytz
from config import config

logger = logging.getLogger(__name__)

class DatabaseClient:
    def __init__(self):
        self.pool: Optional[asyncpg.Pool] = None
    
    async def connect(self):
        """Establish connection pool"""
        self.pool = await asyncpg.create_pool(config.database_url)
        logger.info("Database connection pool created")
    
    async def close(self):
        """Close connection pool"""
        if self.pool:
            await self.pool.close()
            logger.info("Database connection pool closed")
    
    async def get_post(self, post_id: int) -> Optional[dict]:
        """Get post by id"""
        query = "SELECT * FROM posts_queue WHERE id = $1"
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow(query, post_id)
            return dict(row) if row else None
    
    async def get_posts_by_status(self, status: str) -> List[dict]:
        """Get list of posts by status"""
        query = "SELECT * FROM posts_queue WHERE status = $1 ORDER BY requested_at ASC"
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query, status)
            return [dict(row) for row in rows]
    
    async def get_scheduled_posts_due(self) -> List[dict]:
        """Get posts with status=SCHEDULED and scheduled_at <= now()"""
        query = "SELECT * FROM posts_queue WHERE status = 'SCHEDULED' AND scheduled_at <= NOW() ORDER BY scheduled_at ASC"
        async with self.pool.acquire() as conn:
            rows = await conn.fetch(query)
            return [dict(row) for row in rows]
    
    async def try_transition_status(self, post_id: int, from_status: str, to_status: str) -> bool:
        """
        Atomic conditional status transition: only updates if current status == from_status.
        Returns True if the row was updated (transition succeeded), False otherwise.
        This is the core deduplication primitive — it prevents two concurrent workers
        from both publishing the same post.
        """
        query = """
            UPDATE posts_queue
            SET status = $3, updated_at = NOW()
            WHERE id = $1 AND status = $2
            RETURNING id
        """
        async with self.pool.acquire() as conn:
            result = await conn.fetchrow(query, post_id, from_status, to_status)
            if result:
                logger.info(f"[DEDUP] Post #{post_id}: {from_status} → {to_status}")
                return True
            else:
                logger.warning(f"[DEDUP] Post #{post_id}: transition {from_status} → {to_status} BLOCKED (status mismatch)")
                return False

    async def update_post_status(self, post_id: int, new_status: str, **extra_fields) -> bool:
        """Update post status and extra fields"""
        fields = ['status = $2']
        values = [post_id, new_status]
        
        for i, (key, value) in enumerate(extra_fields.items(), start=3):
            fields.append(f"{key} = ${i}")
            values.append(value)
        
        query = f"UPDATE posts_queue SET {', '.join(fields)}, updated_at = NOW() WHERE id = $1 RETURNING id"
        async with self.pool.acquire() as conn:
            result = await conn.fetchrow(query, *values)
            return bool(result)
    
    async def add_revision(self, post_id: int, action: str, text_snapshot: str, reviewer: str, comment: str = '') -> int:
        """Add record to content_revisions"""
        query = "INSERT INTO content_revisions (post_id, action, text_snapshot, reviewer, comment) VALUES ($1, $2, $3, $4, $5) RETURNING id"
        async with self.pool.acquire() as conn:
            result = await conn.fetchrow(query, post_id, action, text_snapshot, reviewer, comment)
            return result['id']
    
    async def get_posts_published_today(self) -> int:
        """Count posts published today"""
        query = "SELECT COUNT(*) FROM posts_queue WHERE status = 'PUBLISHED' AND DATE(published_at AT TIME ZONE 'Europe/Moscow') = DATE(NOW() AT TIME ZONE 'Europe/Moscow')"
        async with self.pool.acquire() as conn:
            result = await conn.fetchval(query)
            return result
    
    async def get_next_available_slot(self) -> Optional[datetime]:
        """Find nearest free slot (09:00/13:00/19:00 MSK)"""
        moscow_tz = pytz.timezone('Europe/Moscow')
        now_moscow = datetime.now(moscow_tz)
        
        slots = []
        for slot_str in config.publish_slots:
            hour, minute = map(int, slot_str.split(':'))
            slots.append(time(hour, minute))
        
        for day_offset in range(7):
            check_date = (now_moscow + timedelta(days=day_offset)).date()
            
            # Check daily limit
            query_count = """
                SELECT COUNT(*) FROM posts_queue 
                WHERE (status = 'PUBLISHED' AND DATE(published_at AT TIME ZONE 'Europe/Moscow') = $1)
                   OR (status = 'SCHEDULED' AND DATE(scheduled_at AT TIME ZONE 'Europe/Moscow') = $1)
            """
            async with self.pool.acquire() as conn:
                count = await conn.fetchval(query_count, check_date)
                if count >= config.max_posts_per_day:
                    continue

                for slot_time in slots:
                    slot_dt = moscow_tz.localize(datetime.combine(check_date, slot_time))
                    if slot_dt <= now_moscow:
                        continue
                    
                    query_slot = "SELECT COUNT(*) FROM posts_queue WHERE status = 'SCHEDULED' AND scheduled_at = $1"
                    slot_taken = await conn.fetchval(query_slot, slot_dt)
                    if not slot_taken:
                        return slot_dt
        return None

db = DatabaseClient()
