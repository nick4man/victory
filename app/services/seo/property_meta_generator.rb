# frozen_string_literal: true

# Generates SEO-optimised title / description / H1 for a Property via
# Llm::OmniClient's analysis chain (free-first: gpt-oss-120b free →
# Gemini Flash → Sonnet fallback).
#
# Output is cached on the Property row itself (seo_title, seo_description,
# seo_h1, seo_generated_at, seo_model — see migration 20260514000932).
# The model is asked to respond with strict JSON; we parse, validate
# length budgets, and silently fall back to the rule-based effective_*
# helpers if the LLM is unreachable or malformed.
#
# Length budgets must match the column limits in the migration so we
# don't trigger a DB exception on persist:
#   title       ≤ 90  chars  (Google clips at 60, Yandex at 70 — we leave headroom)
#   description ≤ 250 chars  (Google snippet ~155, we allow up to 250)
#   h1          ≤ 120 chars
#
# Trigger via:
#   • Seo::GeneratePropertyMetaJob.perform_later(property_id)
#   • rake seo_generation:property_meta:backfill (batch with rate-limit)
#   • rake "seo_generation:property_meta:regenerate[id]"
module Seo
  class PropertyMetaGenerator
    Result = Struct.new(:ok?, :title, :description, :h1, :model, :error, keyword_init: true)

    TITLE_MAX_CHARS       = 90
    DESCRIPTION_MAX_CHARS = 250
    H1_MAX_CHARS          = 120

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Ты SEO-копирайтер для российского агентства недвижимости АН «Виктори»
      в Рязани. Ты пишешь meta-теги для карточки объекта недвижимости так,
      чтобы они хорошо ранжировались в Яндекс и Google и кликались юзером.

      ПРАВИЛА:
      • Только русский язык. Естественный, без канцелярита.
      • title ≤ 60 chars (Google клипает); содержит главное ключевое слово
        в начале (тип сделки + тип объекта + район).
      • description ≤ 155 chars; содержит CTA в конце; уникален.
      • h1 — короткая ёмкая фраза-заголовок (≤ 80 chars), синхронизирована
        с title но не дубль.
      • Без markdown, без HTML, без эмодзи, без CAPS-фраз.
      • Не выдумывай характеристики которых нет в данных.
      • Цена и площадь — только если они есть во входных данных.

      ОТВЕТ строго JSON:
      {"title": "...", "description": "...", "h1": "..."}
    PROMPT

    def initialize(property, client: Llm::OmniClient.new)
      @property = property
      @client   = client
    end

    def call
      return failure('blank property') if @property.nil?

      messages = build_messages
      llm = @client.complete(
        messages,
        chain:           :analysis,
        max_tokens:      400,
        temperature:     0.7,
        response_format: { type: 'json_object' }
      )

      parsed = parse_json(llm[:content].to_s)
      return failure("malformed JSON: #{llm[:content].to_s.truncate(200)}") unless parsed

      title       = clip(parsed['title'],       TITLE_MAX_CHARS)
      description = clip(parsed['description'], DESCRIPTION_MAX_CHARS)
      h1          = clip(parsed['h1'],          H1_MAX_CHARS)

      return failure('LLM returned empty fields') if title.blank? || description.blank?

      Result.new(
        ok?:         true,
        title:       title,
        description: description,
        h1:          h1.presence || title,
        model:       llm[:model],
        error:       nil
      )
    rescue Llm::OmniClient::Error => e
      failure("OmniClient: #{e.message}")
    rescue StandardError => e
      Rails.logger.warn("[Seo::PropertyMetaGenerator] #{@property.id}: #{e.class} #{e.message}")
      failure("#{e.class}: #{e.message}")
    end

    # Persist result onto the Property. Returns the Result regardless so
    # callers can log/retry. Skipped if generation failed.
    def persist!
      result = call
      return result unless result.ok?

      @property.update_columns( # rubocop:disable Rails/SkipsModelValidations
        seo_title:        result.title,
        seo_description: result.description,
        seo_h1:          result.h1,
        seo_model:       result.model,
        seo_generated_at: Time.current
      )

      result
    end

    private

    def build_messages
      [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user',   content: property_payload }
      ]
    end

    # Compact, fact-only payload — LLM should not over-invent. We feed only
    # what's actually on the record.
    def property_payload
      lines = []
      lines << "Тип сделки: #{@property.deal_type_i18n}"
      lines << "Тип объекта: #{@property.property_type&.name}" if @property.property_type
      lines << "Площадь: #{@property.area.to_f.round(1)} м²" if @property.area.to_f.positive?
      lines << "Комнат: #{@property.rooms}" if @property.rooms.to_i.positive?
      if @property.floor.to_i.positive? && @property.total_floors.to_i.positive?
        lines << "Этаж: #{@property.floor}/#{@property.total_floors}"
      end
      lines << "Состояние: #{@property.condition_i18n}" if @property.condition.present?
      lines << "Цена: #{@property.price_formatted}" if @property.price.to_f.positive?
      lines << "Район: #{@property.district}" if @property.district.present?
      lines << "Адрес: #{@property.address}" if @property.address.present?
      lines << "Метро: #{@property.metro_station}" if @property.metro_station.present?
      lines << "Год постройки: #{@property.building_year}" if @property.building_year.to_i.positive?
      lines << "Заголовок: #{@property.title}" if @property.title.present?
      lines.join("\n")
    end

    def parse_json(text)
      stripped = text.strip
      # Some LLMs wrap JSON in ```json fences — strip if present.
      stripped = stripped.sub(/\A```(?:json)?\s*/, '').sub(/\s*```\z/, '')
      JSON.parse(stripped)
    rescue JSON::ParserError
      nil
    end

    def clip(str, max_chars)
      return nil if str.blank?
      str.to_s.strip.truncate(max_chars, omission: '')
    end

    def failure(error)
      Result.new(ok?: false, title: nil, description: nil, h1: nil, model: nil, error: error)
    end
  end
end
