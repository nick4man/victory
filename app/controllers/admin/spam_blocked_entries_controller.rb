# frozen_string_literal: true

module Admin
  # JSON-эндпоинты модерации антиспам-блок-листа (issue #219). Ручная
  # пометка URL/домена как спама (source = local), выборка записей и
  # разблокировка (soft-delete). HTML намеренно нет: потребитель — будущая
  # модерация (ops-скрипты / админ-UI поверх JSON).
  class SpamBlockedEntriesController < ApplicationController
    include AdminTokenAuth

    # POST/DELETE без сессии дергаются ops-скриптами по ?token= — CSRF там
    # не применим (токен сам секрет, как у вебхуков). Снимаем проверку только
    # для ВАЛИДНОГО токена: с мусорным ?token= запрос идёт по cookie-пути
    # и обязан пройти стандартную проверку подлинности формы (иначе CSRF-лазейка
    # в админской сессии — ревью Kimi, раунд 7)
    skip_before_action :verify_authenticity_token, if: :valid_api_token_param?

    def index
      # по умолчанию — действующие записи (default_scope); снятые блоки
      # отдаём только по явному флагу, иначе их невозможно отличить
      scope = params[:with_deleted].present? ? SpamBlockedEntry.unscoped : SpamBlockedEntry.all
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

    # CSRF снимаем только для валидного API-токена (см. skip_before_action
    # выше); мусорный ?token= в контексте cookie-сессии не даёт права
    # обходить проверку подлинности формы
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
