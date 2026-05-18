# frozen_string_literal: true

module Telegram
  module WorkBot
    # Извлечённая логика смены стадии лида — переиспользуется командами `/stage`,
    # `/close` и автоматическими triggers (например, ReactionHandler ставит 👍 →
    # first_contact, SLA-watchdog потенциально может закрыть «брошенный» лид).
    #
    # Делает:
    #   1. Обновляет `LeadEvent.current_stage` + side-effect timestamps
    #      (first_contact_at для 'first_contact', closed_at для 'closed_*')
    #   2. Перерисовывает якорную карточку через `edit_message_text` (меняется эмодзи)
    #   3. Постит тизер в #СДЕЛКА при contract/deal (через DealMirror)
    #   4. Пробрасывает stage_id в Topnlab CRM через `transfer_client`, если в
    #      `StagesCache.id_for(new_stage)` есть mapping (иначе skip, локально-only)
    #
    # Идемпотентность: повторный вызов на уже-current стадии возвращает
    # `Result(false, "already at <stage>")`.
    class LeadStageTransition
      Result = Struct.new(:success, :prev_stage, :new_stage, :message) do
        def success?
          success
        end
      end

      VALID_STAGES = ['new', 'first_contact', 'show', 'contract', 'deal', 'closed_won', 'closed_lost'].freeze

      def initialize(lead_event, new_stage, actor:, client: Telegram::Client.new)
        @lead   = lead_event
        @new    = new_stage.to_s
        @actor  = actor
        @client = client
      end

      def call
        unless VALID_STAGES.include?(@new)
          return Result.new(false, @lead.current_stage, @new,
                            "Неизвестная стадия: #{@new}")
        end
        return Result.new(false, @lead.current_stage, @new, "already at #{@new}") if @lead.current_stage == @new

        prev = @lead.current_stage
        apply_local!
        update_anchor_card!
        push_stage_to_crm(prev)
        maybe_mirror_to_deal
        notify_client_owner!(prev)

        Result.new(true, prev, @new, nil)
      end

      # Russian labels для emoji + клиент-facing strings. Sync с
      # LeadAnnouncer::STAGE_EMOJI на формате.
      STAGE_LABELS = {
        'new'           => 'новая заявка',
        'first_contact' => 'первый контакт',
        'show'          => 'показ объекта',
        'contract'      => 'договор',
        'deal'          => 'сделка',
        'closed_won'    => 'успешно закрыто',
        'closed_lost'   => 'отказ / не сложилось'
      }.freeze

      def self.stage_label(stage)
        STAGE_LABELS[stage.to_s] || stage.to_s
      end

      private

      # Phase 12 Iter 35 — stage_history audit-trail в metadata.
      # До этого фикса /stage никак не записывал «кто перевёл лид в показ».
      # Manager A пишет /stage показ, через час Manager B видит лид в стадии
      # «показ» — никакой visibility кто/когда. Иterа 39 капает на 20 entries
      # последних для anti-bloat.
      def apply_local!
        prev = @lead.current_stage
        attrs = { current_stage: @new }
        attrs[:first_contact_at] = Time.current if @new == 'first_contact' && @lead.first_contact_at.nil?
        attrs[:closed_at]        = Time.current if @new.start_with?('closed_')

        # Append stage_history entry. Phase 12 Iter 39 — cap через
        # LeadEvent#append_history (HISTORY_DEFAULT_CAPS['stage_history'] = 20).
        history = @lead.append_history(
          key: 'stage_history',
          entry: {
            'at' => Time.current.iso8601,
            'from' => prev,
            'to' => @new,
            'by' => @actor&.mention || 'system'
          }
        )
        attrs[:metadata] = @lead.metadata.merge('stage_history' => history)

        @lead.update!(attrs)
      end

      def update_anchor_card!
        return if @lead.anchor_message_id.blank?

        text = LeadAnnouncer.new(@lead, client: @client).format_card_text
        @client.edit_message_text(
          text,
          chat_id: @lead.tg_chat_id,
          message_id: @lead.anchor_message_id,
          parse_mode: 'HTML'
        )
      rescue StandardError => e
        Rails.logger.warn("[LeadStageTransition] edit_message_text failed: #{e.class}: #{e.message}")
      end

      def push_stage_to_crm(_prev)
        stage_id = Topnlab::StagesCache.id_for(@new)
        return if stage_id.blank? # map ещё не заполнен — Phase 2 поведение (skip CRM stage)

        crm_id = @lead.lead_ref.try(:crm_id)
        return if crm_id.blank?

        email = @lead.assigned_to&.email
        return if email.blank? # transfer_client требует email — без назначенного агента не дёргаем

        Topnlab::Client.new.transfer_client(order_id: crm_id.to_i, email: email, stage_id: stage_id)
      rescue Topnlab::Client::Error => e
        Rails.logger.warn("[LeadStageTransition] transfer_client failed: #{e.message}")
      end

      def maybe_mirror_to_deal
        return unless ['contract', 'deal'].include?(@new)

        DealMirror.new(@lead, client: @client).post
      end

      # D4 — fan-out: cabinet broadcast + persistent Notification + email.
      #
      # Feature-flag (default OFF на первом деплое): ENABLE_LEAD_STAGE_BROADCAST.
      # После двух недель monitoring'а — переключаем default в `true` и
      # удаляем guard (см. project memory).
      #
      # Failure isolation: каждый transport в отдельном rescue. Сломанный
      # email не должен убить cabinet broadcast и vice versa.
      def notify_client_owner!(prev_stage)
        return unless ENV['ENABLE_LEAD_STAGE_BROADCAST'] == 'true'

        client = resolve_client_user
        return if client.nil?

        label = self.class.stage_label(@new)

        # 1. WebSocket → live update в /cabinet (нет reload)
        begin
          CabinetChannel.broadcast_to(client, {
            type:          'lead_stage_changed',
            lead_event_id: @lead.id,
            stage:         @new,
            prev_stage:    prev_stage,
            stage_label:   label,
            changed_at:    Time.current.iso8601
          })
        rescue StandardError => e
          Rails.logger.warn("[LeadStageTransition] CabinetChannel.broadcast failed: #{e.class} #{e.message}")
        end

        # 2. Persistent Notification — bell-badge на /dashboard
        begin
          Notification.notify!(
            client,
            kind:       'lead_stage',
            title:      "Статус сделки: #{label}",
            body:       "Этап обновлён с «#{self.class.stage_label(prev_stage)}» на «#{label}».",
            notifiable: @lead
          )
        rescue StandardError => e
          Rails.logger.warn("[LeadStageTransition] Notification.notify! failed: #{e.class} #{e.message}")
        end

        # 3. Email — основной канал для клиента вне сайта
        begin
          if client.email.present?
            CabinetMailer.stage_update(client, @lead, prev_stage).deliver_later
          end
        rescue StandardError => e
          Rails.logger.warn("[LeadStageTransition] CabinetMailer.stage_update failed: #{e.class} #{e.message}")
        end
      end

      # lead_ref polymorphic — может быть Inquiry, PropertyValuation,
      # MortgageRequest etc. Resolve client User по:
      #   1. lead_ref.user (если адаптер уже linked в Lead::Intake)
      #   2. lead_ref.email → User.find_by(LOWER(email)=...)
      #
      # Filter: only role=:client AND active. Без этого риск notify'ить
      # admin/agent у которого тот же email что у клиента (rare, но
      # возможно при тестировании).
      def resolve_client_user
        ref = @lead.lead_ref
        return nil if ref.nil?

        if ref.respond_to?(:user) && ref.user.present?
          u = ref.user
          return u if u.respond_to?(:role_client?) && u.role_client? && u.active?
        end

        if ref.respond_to?(:email) && ref.email.present?
          u = User.where(active: true, deleted_at: nil)
                  .where(role: User.roles[:client])
                  .find_by('LOWER(email) = ?', ref.email.to_s.downcase)
          return u if u
        end

        nil
      end
    end
  end
end
