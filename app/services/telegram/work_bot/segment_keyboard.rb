# frozen_string_literal: true

module Telegram
  module WorkBot
    # BOTTLENECK — единственная клавиатура выбора сегмента покупателя.
    # Используется в трёх местах (карточка лида, нудж после /stage показ,
    # подтверждение отчёта о показе), поэтому живёт отдельно: разъедутся
    # подписи — разъедутся и данные.
    class SegmentKeyboard
      # Короткие подписи — в ряду пять кнопок, длинные Telegram режет.
      SHORT = {
        'cash'              => '💵 Нал',
        'mortgage_approved' => '🏦 Ипотека ✓',
        'mortgage_pending'  => '⏳ Ипотека ?',
        'alternative'       => '🔄 Альт',
        'cold'              => '❄️ Холод'
      }.freeze

      def self.row(lead)
        LeadEvent::SEGMENTS.map do |value|
          { text: SHORT.fetch(value), callback_data: "segment:#{lead.id}:#{value}" }
        end
      end

      def self.for(lead)
        { inline_keyboard: [row(lead)] }
      end

      def self.prompt_text
        '❔ <b>Укажи сегмент покупателя</b> — это то, что ты и так выясняешь по Шагу 4. ' \
          'Без сегмента показ не попадёт в сравнение конверсий.'
      end
    end
  end
end
