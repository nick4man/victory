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
    CTX_KEYS = %w[kind slug deal type district rooms token id].freeze
    CTX_VALUE_MAX = 100

    private

    # Page payload from widget: { path:, query:, title:, h1:, referrer:, ctx: {} }
    def extract_page_params
      raw = params[:page]
      return nil unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      ctx = {
        'path'     => raw['path'].to_s[0, 500].presence,
        'query'    => raw['query'].to_s[0, 500].presence,
        'title'    => raw['title'].to_s[0, 200].presence,
        'h1'       => raw['h1'].to_s[0, 200].presence,
        'referrer' => raw['referrer'].to_s[0, 500].presence,
        'ctx'      => sanitize_page_ctx(raw['ctx'])
      }.compact
      ctx.presence
    end

    def sanitize_page_ctx(raw_ctx)
      return nil unless raw_ctx.respond_to?(:to_unsafe_h) || raw_ctx.is_a?(Hash)
      raw_ctx = raw_ctx.to_unsafe_h if raw_ctx.respond_to?(:to_unsafe_h)
      raw_ctx
        .slice(*CTX_KEYS)
        .transform_values { |v| v.to_s[0, CTX_VALUE_MAX].presence }
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
