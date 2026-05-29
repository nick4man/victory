# frozen_string_literal: true

require 'json'

module Valuations
  # Generates a short Russian narrative explaining the price estimate to the
  # user. Runs AFTER the statistical estimator — sees the subject, final
  # estimate (with CI), filtered comparables (with per-comp AI reasons), and
  # the user's audience (buyer or seller).
  #
  # Output is plain markdown text saved to `evaluation_data['ai_summary']`,
  # then rendered on the result page and the PDF. Length capped at ~600
  # characters to stay readable on mobile.
  #
  # Uses the :analysis chain — same free-first cascade. Failures degrade
  # silently: result page falls back to the pre-AI «market_analysis» line.
  class AiExplainer
    MAX_TOKENS = 500
    TEMPERATURE = 0.4
    CACHE_TTL = 6 * 60 * 60  # 6 hours — re-explain when comps change

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      Ты — эксперт-оценщик недвижимости в городе {{CITY}}. Готовишь краткое
      объяснение оценки для клиента: 4-6 предложений на русском, без
      воды и без «вилки/диапазона/индекса эффективности» терминов. Сразу
      по делу.

      Структура:
      1. Краткий вердикт: справедлива ли цена / какая рекомендация.
      2. Сильные стороны объекта (площадь, район, состояние, год — что есть).
      3. Слабые стороны или нюансы (если есть).
      4. На чём основана оценка (сколько аналогов, насколько чистая выборка).
      5. Совет на следующий шаг (заказать осмотр / поторговаться / разместить).

      Тон: профессиональный, дружелюбный, без воды. Не использовать
      англицизмы и технические термины (hedonic, bootstrap, monte carlo).
      Цены — округлённо в миллионах: «6,5 млн ₽» а не «6 500 000».
    PROMPT

    def initialize(valuation, estimate:, comparables:, audience: :auto)
      @v = valuation
      @estimate = estimate
      @comparables = comparables
      @audience = audience == :auto ? detect_audience : audience
    end

    # @return [String, nil] markdown narrative, or nil on failure (caller
    #   falls back to its existing text).
    def call
      cached = cache_lookup
      return cached if cached

      response = client.complete(
        [
          { role: 'system', content: system_prompt },
          { role: 'user',   content: build_prompt }
        ],
        chain: :analysis,
        max_tokens: MAX_TOKENS,
        temperature: TEMPERATURE
      )
      text = clean_text(response[:content])
      cache_store(text) if text.present?
      text
    rescue StandardError => e
      Rails.logger.warn("[AiExplainer] failed: #{e.class} #{e.message.to_s.truncate(160)}")
      nil
    end

    private

    # Inject the resolved city into the system prompt so the model frames
    # its narrative against the right market context (Москва has different
    # ₽/м² norms than Рязань).
    def system_prompt
      city = @v.try(:city).presence || 'Рязани'
      SYSTEM_PROMPT_TEMPLATE.gsub('{{CITY}}', city)
    end

    def detect_audience
      # Heuristic:
      #   - if the valuation was created from a property page (?from_property=…
      #     persisted to evaluation_data) → buyer evaluating an existing listing;
      #   - otherwise the user is a seller pricing their own object.
      data = @v.respond_to?(:evaluation_data) ? safe_data : {}
      return :buyer if data['source_property_slug'].present? ||
                       data['from_property'].present? ||
                       data['audience'].to_s == 'buyer'

      :seller
    end

    def safe_data
      raw = @v.evaluation_data
      raw.is_a?(String) ? JSON.parse(raw) : (raw || {})
    rescue JSON::ParserError
      {}
    end

    def build_prompt
      parts = []
      parts << "АУДИТОРИЯ: #{@audience == :buyer ? 'покупатель (оценивает чужой объект)' : 'продавец (оценивает свой объект)'}"
      parts << ''
      parts << "ОБЪЕКТ: #{describe_subject}"
      parts << "АДРЕС: #{@v.address}" if @v.address.present?
      parts << ''
      parts << "ОЦЕНКА: #{fmt_mln(@estimate[:estimated_price])} (диапазон #{fmt_mln(@estimate[:min_price])} – #{fmt_mln(@estimate[:max_price])})"
      parts << "Уверенность: #{(@estimate[:confidence_level].to_f * 100).round}%"
      parts << ''
      parts << "АНАЛОГИ (#{@comparables.size}):"
      @comparables.first(5).each do |c|
        rec = c[:record]
        adj = c[:ai_adjustment] || 0
        parts << "- #{describe_comp(rec)} | #{fmt_mln(rec.try(:price))} | поправка #{adj > 0 ? '+' : ''}#{adj}%"
      end
      parts << ''
      parts << if @audience == :buyer
                 'Дай оценку: справедлива ли цена выставления? Стоит ли торговаться?'
               else
                 'Дай оценку: за какую цену реалистично продать? Сколько ждать покупателя?'
               end
      parts.join("\n")
    end

    def describe_subject
      bits = []
      bits << "#{@v.rooms}-комн." if @v.rooms.to_i.positive?
      bits << "#{@v.total_area.to_f.round(1)} м²"
      bits << "этаж #{@v.floor}/#{@v.total_floors}" if @v.floor.to_i.positive?
      bits << "#{@v.building_year} г." if @v.building_year.to_i.positive?
      cond = condition_ru(@v.try(:property_condition) || @v.try(:condition))
      bits << "состояние: #{cond}" if cond
      bits.join(', ')
    end

    def describe_comp(rec)
      bits = []
      bits << "#{rec.try(:rooms)}-комн." if rec.try(:rooms).to_i.positive?
      area = rec.try(:total_area) || rec.try(:area)
      bits << "#{area.to_f.round(1)} м²" if area.to_f.positive?
      bits << rec.try(:address).to_s.truncate(40) if rec.try(:address).present?
      bits.join(', ')
    end

    def condition_ru(value)
      {
        'designer'    => 'дизайнерский',
        'excellent'   => 'евроремонт',
        'good'        => 'с ремонтом',
        'average'     => 'жилое состояние',
        'needs_repair'=> 'требует ремонта'
      }[value.to_s]
    end

    def fmt_mln(price)
      return '—' if price.to_f.zero?

      mln = price.to_f / 1_000_000.0
      mln >= 10 ? "#{mln.round} млн ₽" : "#{mln.round(1).to_s.tr('.', ',')} млн ₽"
    end

    def clean_text(text)
      return nil if text.blank?

      cleaned = text.to_s.strip
      # Strip markdown code fences if model wrapped output
      cleaned = cleaned.sub(/\A```(?:[a-z]+)?\n*/, '').sub(/\n*```\z/, '')
      cleaned[0, 1200]
    end

    def client
      @client ||= Llm::OmniClient.new
    end

    # --- Cache ---

    def cache_key
      fingerprint = Digest::MD5.hexdigest([
        @v.id,
        @v.updated_at.to_i,
        @estimate[:estimated_price].to_i,
        @comparables.size,
        @audience
      ].join('|'))
      "ai_explain:#{fingerprint}"
    end

    def cache_lookup
      redis&.get(cache_key)
    rescue StandardError
      nil
    end

    def cache_store(text)
      redis&.set(cache_key, text, ex: CACHE_TTL)
    rescue StandardError
      nil
    end

    def redis
      @redis ||= begin
        require 'redis' unless defined?(Redis)
        Redis.new(url: ENV['REDIS_URL'].presence || 'redis://localhost:6379/0')
      rescue StandardError
        nil
      end
    end
  end
end
