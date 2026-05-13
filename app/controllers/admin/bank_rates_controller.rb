# frozen_string_literal: true

module Admin
  # Admin view for the banki.ru scraper. Shows the latest weekly snapshot,
  # diff vs the previous one (rate ups/downs, added/removed programs),
  # plus a manual "refresh now" button for when admins want fresher data
  # ahead of the next Sunday cron.
  class BankRatesController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    def index
      @kind = (params[:kind].presence_in(BankRateSnapshot::KINDS) || 'deposit')
      @latest = BankRateSnapshot.for_kind(@kind).recent.first
      @history = BankRateSnapshot.for_kind(@kind).recent.limit(10)
      @diff = @latest&.diff_vs_previous || { added: [], removed: [], changed: [] }
    end

    def refresh
      BankRatesRefreshJob.perform_now
      last = BankRateSnapshot.recent.first
      flash[:notice] = if last
                        "Парсер выполнен. Snapshot ##{last.id} (#{last.status}, программ: #{last.items_count})."
                      else
                        'Парсер выполнен, но snapshot не создан — см. логи.'
                      end
      redirect_to admin_bank_rates_path(token: params[:token])
    end
  end
end
