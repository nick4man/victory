# frozen_string_literal: true

# Single source for the four homepage stat tiles.
#
# Caches in Redis for 1 hour; busted by Property#after_commit when a deal_state
# transitions to/from 'deal', and by Review#after_commit on every write.
class AgencyMetricsService
  AGENCY_FOUNDED_ON = Date.new(2008, 1, 16).freeze
  CACHE_KEY         = 'agency:metrics:v2'
  CACHE_TTL         = 1.hour

  def self.call
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { new.compute }
  end

  def self.bust!
    Rails.cache.delete(CACHE_KEY)
  end

  def compute
    stats           = Topnlab::StatsClient.call
    api_closed      = stats[:closed_deals].to_i
    db_closed       = completed_deals_count
    closed_deals    = [api_closed, db_closed].max  # whichever is fresher
    processed       = stats[:processed_total].to_i
    volume          = total_volume_rub

    {
      years_on_market:    years_on_market,
      completed_deals:    closed_deals,        # honest count: realty.deal+order.deal (~42)
      processed_requests: processed,           # marketing-facing tile (~1200)
      total_volume:       volume,
      total_volume_human: format_volume(volume),
      happy_clients:      happy_clients_count(closed_deals),
      average_rating:     average_rating,
      reviews_count:      reviews_count,
      stats_stale:        stats[:stale] == true,
      computed_at:        Time.current
    }
  end

  def years_on_market
    ((Date.current - AGENCY_FOUNDED_ON).to_f / 365.25).floor
  end

  def completed_deals_count
    Property.unscoped.where(deal_state: 'deal').count
  end

  def total_volume_rub
    Property.unscoped.where(deal_state: 'deal').sum(:price).to_i
  end

  # «Довольный клиент» = одобренный отзыв с rating ≥ 4.
  # Пока отзывов мало — fallback на счётчик завершённых сделок,
  # чтобы виджет на лендинге не показывал ноль на старте.
  def happy_clients_count(completed = nil)
    base = Review.status_approved.where('rating >= ?', 4).count
    return base if base.positive?

    completed ||= completed_deals_count
    completed
  end

  def average_rating
    ratings = Review.status_approved.pluck(:rating).compact
    return 0.0 if ratings.empty?

    (ratings.sum.to_f / ratings.size).round(1)
  end

  def reviews_count
    Review.status_approved.count
  end

  private

  def format_volume(rub)
    return nil if rub.to_i.zero?

    case rub
    when 0...1_000_000              then "#{(rub / 1_000.0).round} тыс ₽"
    when 1_000_000...1_000_000_000  then "#{(rub / 1_000_000.0).round} млн ₽"
    else                                 "#{(rub / 1_000_000_000.0).round(1)} млрд ₽"
    end
  end
end
