# frozen_string_literal: true

module Telegram
  # Обработчик update['message_reaction'] из webhook'а.
  #
  # Подписка через `allowed_updates: ['message_reaction', ...]` в `setWebhook`
  # (см. rake task `telegram:webhook:setup`).
  #
  # Действие при detect:
  #   - Если message_id ∈ LeadEvent.anchor_message_id
  #     И emoji ∈ ACK_EMOJI ({👍, 🔥, ✅})
  #     И user ∈ TelegramUser.active
  #   → выставляем `first_contact_at = now` (если ещё пусто) и переводим в стадию 'first_contact'
  #     через LeadStageTransition (это перерисует карточку и опц. пушит stage в CRM)
  #
  # Формат payload (Telegram Bot API):
  #   {
  #     "chat": { "id": -1003779115845 },
  #     "message_id": 12345,
  #     "user": { "id": 555, "username": "ivan", ... },
  #     "date": 1715774400,
  #     "old_reaction": [],
  #     "new_reaction": [{ "type": "emoji", "emoji": "👍" }]
  #   }
  class ReactionHandler
    ACK_EMOJI = ['👍', '🔥', '✅'].freeze

    def initialize(payload, client: Telegram::Client.new)
      @rx     = payload.is_a?(Hash) ? payload : {}
      @client = client
    end

    def call
      return :no_payload if @rx.empty?
      return :no_user    if @rx['user'].blank?

      tg_user = TelegramUser.find_by(tg_user_id: @rx.dig('user', 'id'))
      return :unknown_user unless tg_user&.status == 'active'

      emoji = pick_ack_emoji
      return :not_ack_emoji unless emoji

      # Phase 7.3 — реакция на task DM (assignee's own DM с задачами).
      # Если single task в DM-группе → mark_completed!(acked_method: 'reaction').
      # Multiple → ignore (user должен использовать кнопку или /done с id).
      task_result = handle_task_reaction(tg_user)
      return task_result if task_result

      # Phase 3 — реакция на якорь лида.
      lead = find_lead_by_message
      return :not_on_anchor unless lead
      return :lead_closed   if lead.closed_at.present?

      maybe_advance_to_first_contact(lead, tg_user)
      :handled
    rescue StandardError => e
      Rails.logger.error("[ReactionHandler] #{e.class}: #{e.message}")
      :error
    end

    private

    # Phase 7.3 — Task reaction completion.
    # @return [Symbol, nil] :task_completed / :task_group_multiple / :task_closed,
    #   или nil если msg_id не относится к задаче (фолбэк на lead reaction).
    def handle_task_reaction(tg_user)
      msg_id = @rx['message_id']
      return nil if msg_id.blank?

      tasks_in_dm = ::Task.where(tg_message_id: msg_id, assignee_id: tg_user.id).to_a
      return nil if tasks_in_dm.empty?

      open_tasks = tasks_in_dm.select(&:status_open?)
      if open_tasks.empty?
        Rails.logger.info("[ReactionHandler] tg_msg=#{msg_id} — все задачи в DM уже закрыты")
        return :task_closed
      end

      if open_tasks.size > 1
        # Multi-task DM — reaction неоднозначен. Friendly hint в DM.
        send_multitask_hint(tg_user, open_tasks)
        return :task_group_multiple
      end

      task = open_tasks.first
      task.mark_completed!(acked_method: 'reaction')
      Rails.logger.info("[ReactionHandler] task ##{task.id} done by #{tg_user.mention} via emoji reaction")
      :task_completed
    end

    def send_multitask_hint(tg_user, open_tasks)
      chat_id = tg_user.dm_chat_id || tg_user.tg_user_id
      return if chat_id.blank?

      ids = open_tasks.map(&:id).join(', ')
      text = "🤔 В этом DM #{open_tasks.size} задач — реакция неоднозначна. " \
             "Используй кнопку <code>[✅ Выполнено #N]</code> или команду <code>/done #{open_tasks.first.id}</code>. " \
             "Открытые: #{ids}."
      @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
    rescue Telegram::Client::Error => e
      Rails.logger.warn("[ReactionHandler] hint DM failed: #{e.message}")
    end

    def find_lead_by_message
      msg_id = @rx['message_id']
      return nil if msg_id.blank?

      LeadEvent.find_by(anchor_message_id: msg_id)
    end

    # Из new_reaction array выбираем первый ack-emoji (если он есть).
    # @return [String, nil]
    def pick_ack_emoji
      new_rx = @rx['new_reaction'] || []
      new_rx.each do |r|
        next unless r.is_a?(Hash) && r['type'] == 'emoji'

        return r['emoji'] if ACK_EMOJI.include?(r['emoji'])
      end
      nil
    end

    # Если лид ещё в 'new' и first_contact_at пуст — продвигаем через
    # `LeadStageTransition` (она же перерисует карточку и пушит stage в CRM).
    # Если уже в more advanced — НЕ откатываем (только первая реакция считается).
    def maybe_advance_to_first_contact(lead, tg_user)
      return if lead.current_stage != 'new'
      return if lead.first_contact_at.present?

      Rails.logger.info("[ReactionHandler] lead=#{lead.id} ack-react by #{tg_user.mention} → first_contact")
      WorkBot::LeadStageTransition.new(lead, 'first_contact', actor: tg_user, client: @client).call
    end
  end
end
