# frozen_string_literal: true

# Public XML feeds for real-estate aggregators.
#
# Yandex.Недвижимость format (YRL) is the de-facto standard in RU — also
# accepted by ЦИАН / МирКвартир / Restate / Domofond with the subset of
# fields they care about. Each aggregator pulls this URL on their own
# schedule; we just need it to be fast, cacheable, and noindex (we don't
# want a 1MB+ XML competing with HTML pages in SERP).
class FeedsController < ApplicationController
  # Aggregator bots fetch via plain GET — no session, no CSRF.
  skip_forgery_protection only: %i[yrl cian avito]

  before_action :load_offered_properties, only: %i[yrl cian avito]
  before_action :set_feed_headers,        only: %i[yrl cian avito]

  def yrl
    respond_to(&:xml)
  end

  def cian
    respond_to(&:xml)
  end

  def avito
    respond_to(&:xml)
  end

  private

  def load_offered_properties
    @properties = Property.in_advertising
                          .includes(:property_type, :user, images_attachments: :blob)
                          .order(updated_at: :desc)
                          .limit(5_000)
    @host = request.host_with_port
  end

  def set_feed_headers
    # Tell bots to crawl but never index this URL itself — the offers it
    # points to are what should rank, not the feed dump.
    response.headers['X-Robots-Tag'] = 'noindex, follow'
    expires_in 30.minutes, public: true
  end
end
