# frozen_string_literal: true

module Chat
  # Shared extraction of the widget's `page` payload (path/query/title/h1/
  # referrer + structured `ctx` from #chat-page-context) for both the
  # conversation bootstrap (GET) and every message POST. Visitor-controlled —
  # everything is length-capped, `ctx` passes only whitelisted keys.
  module PageContextParams
    extend ActiveSupport::Concern

    # Ключи ctx — только идентификаторы видов страниц из хелпера
    # chat_page_context, не произвольный контент посетителя.
    CTX_KEYS = %w[kind slug deal type district rooms token id state].freeze
    CTX_VALUE_MAX = 100

    private

    # Page payload from widget: { path:, query:, title:, h1:, referrer:, ctx: {}, state: {} }
    # Переводы строк вырезаем сразу: иначе сырой value может вставить в
    # системный промпт псевдозаголовок (ScopeGuard проверяет только body).
    # state — живое состояние элементов с data-chat-state; whitelist —
    # по виду страницы (тем же sanitize_state из Llm::PageContext, чтобы
    # сервер и блок работали по одному списку ключей).
    def extract_page_params
      raw = params[:page]
      return nil unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      ctx = {
        'path'     => clean_page_value(raw['path'], 500),
        'query'    => clean_page_value(raw['query'], 500),
        'title'    => clean_page_value(raw['title'], 200),
        'h1'       => clean_page_value(raw['h1'], 200),
        'referrer' => clean_page_value(raw['referrer'], 500),
        'ctx'      => sanitize_page_ctx(raw['ctx'])
      }.compact
      kind = Llm::PageContext.detect(ctx['path'], ctx['ctx'])
      ctx['state'] = Llm::PageContext.sanitize_state(raw['state'], kind)
      ctx.compact.presence
    end

    def clean_page_value(value, max)
      value.to_s.gsub(/[\r\n]+/, ' ')[0, max].presence
    end

    def sanitize_page_ctx(raw_ctx)
      # GET bootstrap шлёт ctx строкой (page[ctx]=<json>), POST — хешем.
      if raw_ctx.is_a?(String)
        raw_ctx = (JSON.parse(raw_ctx) rescue nil)
      elsif raw_ctx.respond_to?(:to_unsafe_h)
        raw_ctx = raw_ctx.to_unsafe_h
      end
      return nil unless raw_ctx.is_a?(Hash)

      raw_ctx
        .slice(*CTX_KEYS)
        .transform_values { |v| clean_page_value(v, CTX_VALUE_MAX) }
        .compact
        .presence
    end

    def stamp_page(conv, page_ctx)
      meta = conv.metadata.is_a?(Hash) ? conv.metadata.dup : {}
      meta['page'] = page_ctx
      conv.update_columns(metadata: meta) if conv.metadata != meta
    end
  end
end
