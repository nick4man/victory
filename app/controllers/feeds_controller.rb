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
  skip_forgery_protection only: :yrl

  def yrl
    # Tell bots to crawl but never index this URL itself — the offers it
    # points to are what should rank, not the feed dump.
    response.headers['X-Robots-Tag'] = 'noindex, follow'
    expires_in 30.minutes, public: true

    @properties = Property.in_advertising
                          .includes(:property_type, :user, images_attachments: :blob)
                          .order(updated_at: :desc)
                          .limit(5_000)
    @host = request.host_with_port

    respond_to do |format|
      format.xml
    end
  end
end
