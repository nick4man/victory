# frozen_string_literal: true

module Lead
  class Intake
    # Адаптер «лид с сайта victory62.org».
    # Обрабатывает 3 разных формы (различие в `source`):
    #   * site_form      — ContactFormsController (контакт, обратный звонок)
    #   * site_valuation — PropertyValuationsController (форма экспресс-оценки)
    #   * site_mortgage  — заявка на ипотеку (mortgage_application_notifier)
    #
    # Не создаёт CRM-карточку немедленно — это делает Topnlab::Importer на синке,
    # либо синхронно через Topnlab::Client#import_client (отдельная задача в Phase 2).
    # Возвращает (lead_ref, metadata).
    class SiteSource
      def initialize(source)
        @source = source
      end

      def call(payload)
        lead_ref = lead_ref_for(payload)
        meta = {
          'name'    => payload[:name].presence || payload[:client_name].presence || 'Без имени',
          'phone'   => normalize_phone(payload[:phone]),
          'email'   => payload[:email].to_s.strip.presence,
          'summary' => build_summary(payload),
          'budget'  => payload[:budget].presence,
          'origin'  => payload[:origin].presence,
          'utm'     => payload[:utm].presence,
          'raw'     => payload.to_h.except(:name, :phone, :email)
        }.compact
        [lead_ref, meta]
      end

      private

      # Привязка к существующей сайтовой сущности:
      #   * site_valuation — PropertyValuation (валюация на сайте)
      #   * site_form/site_mortgage — Inquiry (универсальная форма)
      #   * fallback (если ничего не передали) — также Inquiry, чтобы не создавать
      #     BuyerOrder без crm_id (он требует NOT NULL crm_id из CRM).
      def lead_ref_for(payload)
        if @source == 'site_valuation' && payload[:valuation_id].present?
          PropertyValuation.find_by(id: payload[:valuation_id]) || fallback_inquiry(payload)
        elsif payload[:inquiry_id].present?
          Inquiry.find_by(id: payload[:inquiry_id]) || fallback_inquiry(payload)
        elsif payload[:property_id].present?
          Property.find_by(id: payload[:property_id]) || fallback_inquiry(payload)
        else
          fallback_inquiry(payload)
        end
      end

      # Если форма из неизвестного источника (тесты, ручной вызов) — создаём
      # минимальный Inquiry, чтобы LeadEvent.lead_ref не был nil.
      # Thread-local-флаг предотвращает рекурсию: Inquiry#after_create_commit
      # сам вызывает Lead::Intake, и без флага мы получили бы бесконечный цикл.
      def fallback_inquiry(payload)
        Thread.current[:skip_workbot_push] = true
        Inquiry.create!(
          inquiry_type: 'quick_inquiry',
          name:         payload[:name].to_s.presence || 'Без имени',
          phone:        digits(payload[:phone]),
          email:        payload[:email].to_s.strip.presence,
          message:      payload[:summary].to_s.presence || payload[:message].to_s.presence || 'Лид через Telegram-бот',
          source:       @source,
          status:       'new'
        )
      ensure
        Thread.current[:skip_workbot_push] = false
      end

      def digits(phone)
        phone.to_s.gsub(/\D/, '')
      end

      def build_summary(payload)
        return payload[:summary].to_s if payload[:summary].present?
        return payload[:message].to_s if payload[:message].present?
        case @source
        when 'site_valuation'
          "Запрос оценки: #{payload[:address] || payload[:property_address]}, #{payload[:area]} м², #{payload[:rooms]}-комн"
        when 'site_mortgage'
          "Заявка на ипотеку: сумма #{payload[:loan_amount]}, срок #{payload[:term_years]} лет"
        else
          'Заявка с сайта'
        end
      end

      def normalize_phone(phone)
        return nil if phone.blank?
        digits = phone.to_s.gsub(/\D/, '')
        digits = "7#{digits[1..]}" if digits.start_with?('8') && digits.length == 11
        return phone.to_s if digits.length < 10
        "+#{digits}"
      end

      def mask_phone(phone)
        n = normalize_phone(phone)
        return nil if n.blank?
        "#{n[0..3]}***#{n[-2..]}"
      end
    end
  end
end
