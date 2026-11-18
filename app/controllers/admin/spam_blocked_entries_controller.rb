# frozen_string_literal: true

module Admin
  # JSON-эндпоинты модерации антиспам-блок-листа (issue #219). Ручная
  # пометка URL/домена как спама (source = local), выборка записей и
  # разблокировка (soft-delete). HTML намеренно нет: потребитель — будущая
  # модерация (ops-скрипты / админ-UI поверх JSON).
  class SpamBlockedEntriesController < ApplicationController
    include AdminTokenAuth

    # POST/DELETE без сессии дергаются ops-скриптами по ?token= — CSRF там
    # не применим (токен сам секрет, как у вебхуков). Проверку подлинности
    # формы проходят только запросы без валидного токена (cookie-путь) —
    # см. переопределение verify_authenticity_token ниже. skip_before_action
    # намеренно НЕ используем: CodeQL трактует его как отключение CSRF
    # (required check на PR #228, ревью раунд 8).

    def index
      # по умолчанию — действующие записи (default_scope); снятые блоки
      # отдаём только по явному булеву флагу, иначе их невозможно отличить
      scope = ActiveModel::Type::Boolean.new.cast(params[:with_deleted]) ? SpamBlockedEntry.unscoped : SpamBlockedEntry.all
      scope = scope.order(updated_at: :desc)
      scope = scope.where(source: params[:source]) if params[:source].present?
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(entry_type: params[:entry_type]) if params[:entry_type].present?

      entries = scope.limit(index_limit).offset(index_offset)
      render json: { ok: true, entries: entries.map { |e| serialize(e) } }
    end

    def create
      result = SpamBlockedEntry.block_locally!(params[:url], status: params[:status].presence || :blocked)
      if result[:ok]
        render json: { ok: true, entry: serialize(result[:value]) }, status: :created
      else
        render json: { ok: false, error: result[:error].to_s }, status: :unprocessable_entity
      end
    end

    def destroy
      entry = SpamBlockedEntry.unscoped.find(params[:id])
      entry.update_columns(deleted_at: Time.current, updated_at: Time.current)
      # иначе ip_blocked? продолжал бы дропать адрес из кеша до CIDR_CACHE_TTL
      Rails.cache.delete(SpamBlockedEntry::CIDR_CACHE_KEY) if entry.entry_type_ip?
      render json: { ok: true }
    end

    private

    # Семантика «CSRF-проверка выключена только для валидного API-токена»,
    # но без skip_before_action (CodeQL / PR #228): валидный ?token= —
    # запрос уже аутентифицирован секретом, cookie-сессии нет, CSRF
    # неприменим; с мусорным ?token= запрос идёт по cookie-пути и обязан
    # пройти стандартную :exception-проверку подлинности формы (иначе
    # CSRF-лазейка в админской сессии — ревью Kimi, раунд 7).
    def verify_authenticity_token
      return if valid_api_token_param?

      super
    end

    # Валидность API-токена — единственный критерий отказа от проверки
    # подлинности формы (см. verify_authenticity_token выше)
    def valid_api_token_param?
      expected = ENV['ADMIN_TOKEN'].to_s
      return false if expected.blank? || params[:token].blank?

      ::ActiveSupport::SecurityUtils.secure_compare(
        ::Digest::SHA256.hexdigest(params[:token].to_s),
        ::Digest::SHA256.hexdigest(expected)
      )
    end

    def index_limit
      [[params.fetch(:limit, 100).to_i, 1].max, 500].min
    end

    # отрицательный offset ушёл бы в PostgreSQL и дал 500 — как и limit,
    # прижимаем снизу нулём
    def index_offset
      [params[:offset].to_i, 0].max
    end

    def serialize(entry)
      {
        id:         entry.id,
        entry_type: entry.entry_type,
        value:      entry.value,
        status:     entry.status,
        source:     entry.source,
        hits:       entry.hits,
        blocked_at: entry.blocked_at&.iso8601,
        deleted_at: entry.deleted_at&.iso8601,
        updated_at: entry.updated_at.iso8601
      }
    end
  end
end
