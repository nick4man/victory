# frozen_string_literal: true

module Dashboard
  class InquiriesController < BaseController
    before_action :load_inquiry, only: %i[show destroy cancel timeline]

    def index
      @inquiries = current_user.inquiries.includes(:property, :agent).order(created_at: :desc)
    rescue StandardError => e
      Rails.logger.warn("[Dashboard::Inquiries#index] #{e.class}: #{e.message}")
      @inquiries = current_user.inquiries.order(created_at: :desc)
    end

    def show
      @property = @inquiry.property
      @agent    = @inquiry.agent
      @events   = build_timeline(@inquiry)
    end

    # Soft-cancel — keeps the row for analytics, just marks status and time.
    # User still sees it under /dashboard/inquiries (cancelled badge).
    def cancel
      cancellable = @inquiry.respond_to?(:status) && %w[new contacted in_progress scheduled].include?(@inquiry.status.to_s)
      if cancellable
        @inquiry.update(
          status: 'cancelled',
          cancelled_at: Time.current,
          cancellation_reason: params[:reason].presence || 'Отменено клиентом из кабинета'
        )
        redirect_to dashboard_inquiry_path(@inquiry), notice: 'Заявка отменена.'
      else
        redirect_to dashboard_inquiry_path(@inquiry), alert: 'Эту заявку уже нельзя отменить.'
      end
    end

    def destroy
      @inquiry.destroy
      redirect_to dashboard_inquiries_path, notice: 'Заявка удалена из истории.'
    end

    # Timeline as JSON — kept for any future async fetcher; the synchronous
    # `show` action already passes @events into the view, so this is rarely
    # called in practice.
    def timeline
      render json: { events: build_timeline(@inquiry) }
    end

    private

    def load_inquiry
      @inquiry = current_user.inquiries.find(params[:id])
    end

    # Builds a list of events from columns Inquiry already has — no separate
    # "InquiryEvent" log needed for v1. If we later add staff comments or
    # status-change history, plug them in here.
    def build_timeline(inquiry)
      events = []
      events << { at: inquiry.created_at, kind: 'created',   label: 'Заявка отправлена' }
      events << { at: inquiry.processed_at, kind: 'contacted', label: 'Менеджер связался' } if inquiry.processed_at.present?
      events << { at: inquiry.scheduled_at, kind: 'scheduled', label: "Запланирован показ — #{inquiry.scheduled_at}" } if inquiry.scheduled_at.present?
      events << { at: inquiry.completed_at, kind: 'completed', label: 'Заявка выполнена' } if inquiry.completed_at.present?
      events << { at: inquiry.cancelled_at, kind: 'cancelled', label: cancellation_label(inquiry) } if inquiry.cancelled_at.present?
      events.compact.sort_by { |e| e[:at] }.reverse
    end

    def cancellation_label(inquiry)
      reason = inquiry.cancellation_reason.presence
      reason ? "Заявка отменена — #{reason}" : 'Заявка отменена'
    end
  end
end
