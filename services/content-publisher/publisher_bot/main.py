import asyncio
import logging
import signal
from telegram.ext import ApplicationBuilder, CallbackQueryHandler
from config import config
from db_client import db
from scheduler import setup_scheduler
from approval_bot import approval_handler, approve_callback, reject_callback, send_for_approval

# Logging setup
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

async def main():
    # 1. Initialize DB
    try:
        await db.connect()
        logger.info("Successfully connected to database")
    except Exception as e:
        logger.error(f"Failed to connect to database: {e}")
        return

    # 2. Build Telegram Application
    application = ApplicationBuilder().token(config.channel_bot_token).build()
    
    # Add handlers
    application.add_handler(approval_handler) # ConversationHandler for REVISE
    application.add_handler(CallbackQueryHandler(approve_callback, pattern="^approve:"))
    application.add_handler(CallbackQueryHandler(reject_callback, pattern="^reject:"))

    # 3. Start Scheduler
    scheduler = setup_scheduler(application.bot)
    scheduler.start()
    logger.info("Scheduler started")

    # 3.1. On startup: send approval cards for any WAITING_APPROVAL posts that never got one
    try:
        pending = await db.get_posts_by_status('WAITING_APPROVAL')
        for post in pending:
            if not post.get('tg_message_id'):  # no approval card sent yet
                logger.info(f"Sending missed approval card for post #{post['id']}")
                await send_for_approval(application.bot, post)
        if pending:
            logger.info(f"Startup approval flush: processed {len(pending)} pending posts")
    except Exception as e:
        logger.error(f"Startup approval flush failed: {e}")

    # 4. Run Application
    async with application:
        await application.initialize()
        await application.start()
        logger.info("Telegram Bot started")
        
        # Setup graceful shutdown
        stop_event = asyncio.Event()
        
        def signal_handler():
            logger.info("Shutdown signal received")
            stop_event.set()

        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, signal_handler)

        # Main loop (polling or wait)
        await application.updater.start_polling()
        
        await stop_event.wait()
        
        # 5. Shutdown
        logger.info("Shutting down...")
        await application.updater.stop()
        await application.stop()
        await application.shutdown()
        scheduler.shutdown()
        await db.close()
        logger.info("Graceful shutdown complete")

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
