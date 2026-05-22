# frozen_string_literal: true

module Admin
  # #413f Шаг 2 — management клиентских user records + activation
  # generator. Token-guarded via AdminTokenAuth.
  #
  # Use-cases:
  #   - выгрузить список Topnlab-импортированных клиентов и их статус
  #     активации (linked TG / только invited / не контактировали)
  #   - сгенерировать activation link для конкретного клиента
  #     (агент вручную делится через WhatsApp / в офисе / печатает QR /
  #     email-подпись)
  #   - revoke ошибочно сгенерированных tokens
  #   - manual SMS-fallback кнопка (для случаев когда клиент не отвечает
  #     ни на email ни на bot inbound trigger) — НЕ реализована в этом
  #     commit'е, defer to отдельной фиче
  #
  # Routes:
  #   GET    /admin/users                  → index (filter by status + search)
  #   GET    /admin/users/:id              → show (detail + activation panel)
  #   POST   /admin/users/:id/generate_activation        → TgLinkToken.generate!
  #   POST   /admin/users/:id/revoke_activation_tokens   → mark all valid consumed
  class UsersController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    before_action :set_user, only: %i[show generate_activation revoke_activation_tokens]

    # Status filters (UI):
    #   linked       — tg_user_id present
    #   invited_no_tg — invited_at present, tg_user_id nil (отправили
    #                    приглашение, не активировал)
    #   not_invited  — invited_at nil (никогда не контактировали)
    def index
      scope = User.unscoped.where(role: :client, deleted_at: nil)
      @status = params[:status].presence
      scope = filter_by_status(scope, @status) if @status
      scope = filter_by_search(scope, params[:q]) if params[:q].present?

      @users = scope.order(created_at: :desc).page(params[:page]).per(30)
      @counts = compute_counts
    end

    def show
      @active_token = @user.tg_link_tokens.valid.order(created_at: :desc).first
      @owned_properties = Property.unscoped.where(owner_user_id: @user.id)
                                  .order(updated_at: :desc).limit(20)
      @bot_username = ENV.fetch('TELEGRAM_BOT_USERNAME', 'anvictorybot').downcase
    end

    # POST /admin/users/:id/generate_activation
    # Idempotent: если есть active token — re-use, не плодим дубликаты.
    def generate_activation
      if (existing = @user.tg_link_tokens.valid.order(created_at: :desc).first)
        flash[:notice] = "Используется существующий токен (истекает через #{minutes_until(existing.expires_at)} мин)."
      else
        TgLinkToken.generate!(user: @user, request: request)
        flash[:notice] = 'Активационная ссылка сгенерирована (срок 30 минут).'
      end
      redirect_to admin_user_path(@user)
    end

    # POST /admin/users/:id/revoke_activation_tokens
    # Soft-revoke: mark all valid tokens этого user как consumed_at=now.
    # Не удаляем — audit-trail сохраняется.
    def revoke_activation_tokens
      n = @user.tg_link_tokens.valid.update_all(consumed_at: Time.current)
      flash[:notice] = n.positive? ? "Отозвано токенов: #{n}." : 'Активных токенов нет.'
      redirect_to admin_user_path(@user)
    end

    private

    def set_user
      @user = User.unscoped.find(params[:id])
    end

    def filter_by_status(scope, status)
      case status
      when 'linked'        then scope.where.not(tg_user_id: nil)
      when 'invited_no_tg' then scope.where.not(invited_at: nil).where(tg_user_id: nil)
      when 'not_invited'   then scope.where(invited_at: nil)
      else                       scope
      end
    end

    def filter_by_search(scope, query)
      q = "%#{query.strip}%"
      scope.where(
        'LOWER(email) LIKE LOWER(?) OR phone LIKE ? OR LOWER(first_name) LIKE LOWER(?) ' \
        'OR LOWER(last_name) LIKE LOWER(?)',
        q, q, q, q
      )
    end

    def compute_counts
      base = User.unscoped.where(role: :client, deleted_at: nil)
      {
        all:           base.count,
        linked:        base.where.not(tg_user_id: nil).count,
        invited_no_tg: base.where.not(invited_at: nil).where(tg_user_id: nil).count,
        not_invited:   base.where(invited_at: nil).count
      }
    end

    def minutes_until(time)
      [((time - Time.current) / 60).ceil, 0].max
    end
  end
end
