# frozen_string_literal: true

module Admin
  # JSON-эндпоинты модерации антиспам-блок-листа (issue #219). Ручная
  # пометка URL/домена как спама (source = local), выборка записей и
  # разблокировка (soft-delete). HTML намеренно нет: потребитель — будущая
  # модерация (ops-скрипты / админ-UI поверх JSON).
  class SpamBlockedEntriesController < ApplicationController
    include AdminTokenAuth

    # POST/DELETE без сессии дергаются ops-скриптами по ?token= — CSRF там
    # не применим (токен сам секрет, как у вебхуков); cookie-сессия после
    # /admin/login проходит стандартную проверку подлинности формой.
    skip_before_action :verify_authenticity_token, if: -> { params[:token].present? }

    def index
      scope = SpamBlockedEntry.unscoped.order(updated_at: :desc)
      scope = scope.where(source: params[:source]) if params[:source].present?
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.where(entry_type: params[:entry_type]) if params[:entry_type].present?

      entries = scope.limit(index_limit).offset(params[:offset].to_i)
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
      render json: { ok: true }
    end

    private

    def index_limit
      [[params.fetch(:limit, 100).to_i, 1].max, 500].min
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
        updated_at: entry.updated_at.iso8601
      }
    end
  end
end
