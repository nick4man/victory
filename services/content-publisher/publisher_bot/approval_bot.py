import logging
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    ContextTypes,
    CallbackQueryHandler,
    MessageHandler,
    filters,
    ConversationHandler
)
from config import config
from db_client import db
from security import assert_allowed_target

logger = logging.getLogger(__name__)

WAITING_COMMENT = 1

# Кто имеет право жать кнопки на карточках согласования. Без этой проверки
# любой, у кого есть сообщение (пересылка!), мог одобрить/отклонить пост.
APPROVER_IDS = {
    config.oksana_chat_id,
    config.dartagnan_chat_id,
    config.chief_editor_chat_id,
}


def _assert_approver(update: Update) -> bool:
    user = update.effective_user
    if not user or user.id not in APPROVER_IDS:
        logger.error(
            f"SECURITY BLOCK: approval action from unauthorized user "
            f"{user.id if user else 'unknown'} (allowed: {APPROVER_IDS})"
        )
        return False
    return True

async def send_for_approval(bot, post: dict):
    """Send post for approval to Dartagnan (realtor-assistant proxy, v2 scheme)"""
    text = (
        f"📝 *Новый пост на аппрув* `#{post['id']}`\n\n"
        f"🏷 *Объект:* {post.get('project_name', 'н/д')}\n"
        f"📂 *Тип:* {post.get('content_type', 'н/д')}\n"
        f"🔢 *Итерация:* {post.get('iteration', 1)}\n\n"
        f"─────────────────\n"
        f"{post['smm_text']}\n"
        f"─────────────────\n\n"
        f"⏰ *Дедлайн:* {post.get('deadline', 'не указан')}"
    )
    
    keyboard = [
        [
            InlineKeyboardButton("✅ Одобрить", callback_data=f"approve:{post['id']}"),
            InlineKeyboardButton("✏️ На доработку", callback_data=f"revise:{post['id']}"),
        ],
        [InlineKeyboardButton("❌ Отклонить", callback_data=f"reject:{post['id']}")]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    # v2: send to Dartagnan (realtor-assistant), not directly to Oksana
    # 🔴 IRON ISOLATION: whitelist check before sending
    assert_allowed_target(config.dartagnan_chat_id)
    await bot.send_message(
        chat_id=config.dartagnan_chat_id,
        text=text,
        reply_markup=reply_markup,
        parse_mode='Markdown'
    )

async def approve_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    post_id = int(query.data.split(':')[1])
    await query.answer()

    if not _assert_approver(update):
        await query.edit_message_text("⛔ Недостаточно прав для этого действия.")
        return

    # Check current status
    post = await db.get_post(post_id)
    if not post or post['status'] != 'WAITING_APPROVAL':
        await query.edit_message_text(f"⚠️ Пост #{post_id} уже обработан или не найден.")
        return

    slot = await db.get_next_available_slot()
    if slot:
        # Атомарно: без условия status = WAITING_APPROVAL повторный клик
        # (или гонка двух нажатий) дал бы двойную запись в revisions.
        if not await db.try_transition_status(post_id, 'WAITING_APPROVAL', 'SCHEDULED', scheduled_at=slot):
            await query.edit_message_text(f"⚠️ Пост #{post_id} уже обработан.")
            return
        await db.add_revision(post_id, 'APPROVE', post['smm_text'], 'Oksana')
        await query.edit_message_text(f"✅ Пост #{post_id} одобрен и запланирован на {slot.strftime('%d.%m.%y %H:%M')} MSK")
    else:
        await query.edit_message_text(f"⚠️ Пост #{post_id} одобрен, но не удалось найти свободный слот в расписании!")

async def reject_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    post_id = int(query.data.split(':')[1])
    await query.answer()

    if not _assert_approver(update):
        await query.edit_message_text("⛔ Недостаточно прав для этого действия.")
        return

    post = await db.get_post(post_id)
    if not post:
        await query.edit_message_text(f"⚠️ Пост #{post_id} не найден.")
        return
    # Атомарный переход: раньше статус перезаписывался безусловно и реджект
    # карточки мог убить уже SCHEDULED/PUBLISHED пост.
    if not await db.try_transition_status(post_id, 'WAITING_APPROVAL', 'REJECTED'):
        await query.edit_message_text(f"⚠️ Пост #{post_id} уже обработан.")
        return
    await db.add_revision(post_id, 'REJECT', post['smm_text'], 'Oksana')
    await query.edit_message_text(f"❌ Пост #{post_id} отклонен.")

async def start_revise(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    post_id = int(query.data.split(':')[1])
    if not _assert_approver(update):
        await query.answer()
        await query.message.reply_text("⛔ Недостаточно прав для этого действия.")
        return ConversationHandler.END
    context.user_data['revising_post_id'] = post_id
    await query.answer()
    await query.message.reply_text("✏️ Пожалуйста, напишите комментарий к доработке:")
    return WAITING_COMMENT

async def handle_revise_comment(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _assert_approver(update):
        await update.message.reply_text("⛔ Недостаточно прав для этого действия.")
        return ConversationHandler.END

    post_id = context.user_data.get('revising_post_id')
    comment = update.message.text
    
    post = await db.get_post(post_id)
    if post:
        await db.update_post_status(post_id, 'REVISION', review_comment=comment)
        await db.add_revision(post_id, 'REVISE', post['smm_text'], 'Oksana', comment)
        
        # Notify Chief Editor
        # 🔴 IRON ISOLATION: whitelist check before sending
        assert_allowed_target(config.chief_editor_chat_id)
        await context.bot.send_message(
            chat_id=config.chief_editor_chat_id,
            text=f"✏️ *Пост #{post_id} отправлен на доработку.*\n\nКомментарий Оксаны:\n_{comment}_",
            parse_mode='Markdown'
        )
        await update.message.reply_text(f"✅ Комментарий сохранен. Пост #{post_id} отправлен на доработку.")
    
    return ConversationHandler.END

approval_handler = ConversationHandler(
    entry_points=[CallbackQueryHandler(start_revise, pattern="^revise:")],
    states={
        WAITING_COMMENT: [MessageHandler(filters.TEXT & ~filters.COMMAND, handle_revise_comment)]
    },
    fallbacks=[],
    allow_reentry=True
)
