# frozen_string_literal: true

module Telegram
  module WorkBot
    # BOTTLENECK — фильтр «кто едет на показ». Правило из брейншторма 11.09.26:
    # холодные и неодобренные → агент; наличные, одобренная ипотека, второй
    # показ, торг на столе → руководитель. Квалификация, которую агент и так
    # выясняет по Шагу 4, впервые на что-то влияет.
    #
    # Тёмный код: без ENV SHOW_ROUTING_ENABLED=true ни одна ветка бота его не
    # вызывает. Включать — только после базовой линии (см. план).
    class ShowRouting
      Recommendation = Struct.new(:conductor, :reason, keyword_init: true)

      DIRECTOR_SEGMENTS = ['cash', 'mortgage_approved'].freeze
      AGENT_SEGMENTS    = ['cold', 'mortgage_pending', 'alternative'].freeze

      def self.enabled?
        ENV['SHOW_ROUTING_ENABLED'] == 'true'
      end

      def self.recommend(lead)
        return Recommendation.new(conductor: :unknown, reason: 'сегмент не указан') if lead.segment.blank?

        prior = lead.show_reports.status_confirmed
        if prior.exists?
          reason = prior.where.not(offered_price: nil).exists? ? 'торг уже на столе' : 'повторный показ'
          return Recommendation.new(conductor: :director, reason: reason)
        end

        label = LeadEvent::SEGMENT_LABELS[lead.segment].to_s.sub(/\A\S+\s/, '').downcase
        return Recommendation.new(conductor: :director, reason: "сегмент «#{label}»") if DIRECTOR_SEGMENTS.include?(lead.segment)

        Recommendation.new(conductor: :agent, reason: "сегмент «#{label}»")
      end

      def self.keyboard(lead)
        people = [lead.assigned_to, *TelegramUser.directors.active].compact.uniq
        row = people.map do |p|
          icon = p.role_director? ? '👑' : '👤'
          { text: "#{icon} #{p.first_name.presence || p.mention}", callback_data: "show_assign:#{lead.id}:#{p.id}" }
        end
        { inline_keyboard: [row] }
      end

      def self.prompt_text(lead, rec)
        who = { agent: 'агент', director: 'руководитель', unknown: '—' }[rec.conductor]
        head = if rec.conductor == :unknown
                 '❔ Сначала укажи сегмент — без него фильтр молчит.'
               else
                 "🧭 Рекомендация: показывает <b>#{who}</b> (#{rec.reason})."
               end
        "#{head}\nКто поедет на показ по лиду ##{lead.id}?"
      end
    end
  end
end
