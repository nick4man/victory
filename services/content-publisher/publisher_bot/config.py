import os
from dataclasses import dataclass

@dataclass
class Config:
    # Telegram
    channel_bot_token: str = os.getenv('CHANNEL_BOT_TOKEN', '')
    oksana_chat_id: int = int(os.getenv('OKSANA_CHAT_ID', '0') or '0')
    dartagnan_chat_id: int = int(os.getenv('DARTAGNAN_CHAT_ID', '0') or '0')  # Approval Proxy (v2)
    chief_editor_chat_id: int = int(os.getenv('CHIEF_EDITOR_CHAT_ID', '0') or '0')
    rznvictory_channel: str = os.getenv('RZNVICTORY_CHANNEL', '@rznvictory')
    
    # БД
    database_url: str = os.getenv('DATABASE_URL', '')  # обязателен; дефолта с паролем здесь больше нет
    
    # Расписание
    publish_slots: list = None  # ['09:00', '13:00', '19:00'] MSK
    max_posts_per_day: int = int(os.getenv('MAX_POSTS_PER_DAY', '2'))
    
    # Таймауты
    approval_timeout_hours: int = int(os.getenv('APPROVAL_TIMEOUT_HOURS', '24'))
    approval_escalation_hours: int = int(os.getenv('APPROVAL_ESCALATION_HOURS', '48'))
    
    def __post_init__(self):
        if not self.database_url:
            raise RuntimeError('DATABASE_URL не задан — укажи его в .env.publisher (см. .env.example)')
        slots_str = os.getenv('PUBLISH_SLOTS', '09:00,13:00,19:00')
        self.publish_slots = slots_str.split(',')

config = Config()