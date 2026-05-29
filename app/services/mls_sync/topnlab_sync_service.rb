# frozen_string_literal: true

# DEPRECATED — Topnlab API does NOT expose cross-agency MLS data.
#
# Per Topnlab API docs (sections 2 + 4):
#   - GET /get-ids?type=...  accepts ONLY realty | order | service. There is
#     no `type=mls` parameter; passing it returns HTTP 422 «Неизвестный тип
#     карточки».
#   - GET /get-entities-from-mls?id=... returns OUR OWN realty cards in their
#     MLS network projection (with extra fields used by the MLS broadcast),
#     not other agencies' listings.
#
# Conclusion: this sync would duplicate our Property table into MlsListing
# (same objects, different table) — useless for comparable-search.
#
# True cross-agency comparable data comes from:
#   - ExternalListings::YrlParser  — Yandex YRL feeds of other Ryazan agencies
#   - Future: Avito Data API, CIAN headless scrape
#
# The service is left in place as a no-op so the rake task and sidekiq-cron
# entry don't 500. Remove once the cron entry is deleted in a follow-up.
module MlsSync
  class TopnlabSyncService
    def initialize(*_args, **_kwargs); end

    def call
      Rails.logger.info('[MlsSync::TopnlabSync] noop — Topnlab MLS endpoint exposes own listings only, not comps')
      { success: true, ids_seen: 0, upserted: 0, errors: [], noop: true }
    end
  end
end
