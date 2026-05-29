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

        # Phase 14 Iter 53 — wrap всё в @lead.with_lock чтобы predотвратить race
        # между Manager A (/stage показ) и Manager B (/stage договор) на одном
        # анкоре. Без lock: оба читают current_stage='new', оба edit_message_text
        # → конфликт + last-write-wins в TG. Lock сериализует mutations + edits.
        result = nil
        @lead.with_lock do
          @lead.reload

          return Result.new(false, @lead.current_stage, @new, "already at #{@new}") if @lead.current_stage == @new

          # Phase 14 Iter 51 — closed → not-closed reject (re-open lead).
          if @lead.current_stage.to_s.start_with?('closed_') && !@new.start_with?('closed_')
            result = Result.new(false, @lead.current_stage, @new,
                                "Лид уже закрыт (#{@lead.current_stage}). " \
                                'Re-open запрещён через бота — manual revert через Topnlab UI ' \
                                '+ rails console для current_stage.')
            next # exit with_lock block
          end

          prev = @lead.current_stage
          apply_local!
          update_anchor_card!
          push_stage_to_crm(prev)
          maybe_mirror_to_deal
          notify_client_owner!(prev)

          result = Result.new(true, prev, @new, nil)
        end
        result
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

        label = self.class.stage_label(@new)

        buyer  = resolve_client_user
        seller = resolve_seller_user

        # Avoid double-pushing когда buyer == seller (rare, но возможно
        # для агентств-internal тестов / семейных сделок).
        recipients = [
          [buyer,  :buyer],
          [seller, :seller]
        ].uniq { |u, _| u&.id }.reject { |u, _| u.nil? }

        recipients.each do |user, perspective|
          dispatch_notifications(user, perspective, label, prev_stage)
        end
      end

      # Per-recipient fan-out (WS + Notification + email). Каждый transport
      # в отдельном rescue.
      def dispatch_notifications(user, perspective, label, prev_stage)
        title, body = compose_message(perspective, label, prev_stage)

        # 1. WebSocket
        begin
          CabinetChannel.broadcast_to(user, {
            type:          'lead_stage_changed',
            perspective:   perspective,
            lead_event_id: @lead.id,
            stage:         @new,
            prev_stage:    prev_stage,
            stage_label:   label,
            changed_at:    Time.current.iso8601
          })
        rescue StandardError => e
          Rails.logger.warn("[LeadStageTransition] CabinetChannel.broadcast failed (#{perspective}): #{e.class} #{e.message}")
        end

        # 2. Persistent Notification
        begin
          Notification.notify!(
            user,
            kind:       'lead_stage',
            title:      title,
            body:       body,
            notifiable: @lead
          )
        rescue StandardError => e
          Rails.logger.warn("[LeadStageTransition] Notification.notify! failed (#{perspective}): #{e.class} #{e.message}")
        end

        # 3. Email
        begin
          if user.email.present?
            CabinetMailer.stage_update(user, @lead, prev_stage).deliver_later
          end
        rescue StandardError => e
          Rails.logger.warn("[LeadStageTransition] CabinetMailer.stage_update failed (#{perspective}): #{e.class} #{e.message}")
        end
      end

      # Buyer видит «ваша заявка», seller видит «по вашему объекту».
      def compose_message(perspective, label, prev_stage)
        prev_label = self.class.stage_label(prev_stage)
        case perspective
        when :seller
          [
            "Активность по вашему объекту: #{label}",
            "Покупатель прошёл этап «#{prev_label}» → «#{label}». Подробности в кабинете."
          ]
        else  # :buyer
          [
            "Статус сделки: #{label}",
            "Этап обновлён с «#{prev_label}» на «#{label}»."
          ]
        end
      end

      # lead_ref polymorphic — может быть Inquiry, PropertyValuation,
      # MortgageRequest etc. Resolve client (BUYER) User по:
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

      # CRIT-2 (D4 seller-side): Property.owner_user_id для seller-нотификаций.
      # Триггерится только если lead_ref → Property linkage existing
      # (Inquiry#property_id, PropertyValuation#property_id, etc.).
      def resolve_seller_user
        ref = @lead.lead_ref
        return nil if ref.nil?
        return nil unless ref.respond_to?(:property_id) && ref.property_id.present?

        property = Property.unscoped.find_by(id: ref.property_id)
        return nil if property.nil? || property.owner_user_id.blank?

        u = User.where(active: true, deleted_at: nil).find_by(id: property.owner_user_id)
        return nil unless u && u.respond_to?(:role_client?) && u.role_client?
        u
      end
    end
  end
end
