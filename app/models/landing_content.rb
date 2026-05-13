# frozen_string_literal: true

# Editable SEO landing-page content. One row per (intent, type,
# district_slug, rooms). The body is a JSONB array of typed blocks
# (heading, paragraph, quote, link, image, list, faq) — the editor and
# the renderer share that vocabulary via LandingBlocksHelper.
#
# Caching: on save we re-render `body_html` (used by LandingsController#show)
# and `body_plain` (used by ChatTools::GetLandingContent for the chatbot
# context). Both projections come from the same block array, so they can
# never drift.
#
# Admins (re-)attach images directly; image blocks store the ActiveStorage
# signed_id and the renderer resolves it at render time.
class LandingContent < ApplicationRecord
  self.inheritance_column = nil  # `type` is a real catalog field, not STI

  BLOCK_KINDS = %w[heading paragraph quote link image list faq].freeze
  INTENTS     = %w[sale rent].freeze
  TYPES       = %w[kvartira dom uchastok komnata kommercheskaya].freeze

  has_many_attached :images

  validates :intent, presence: true, inclusion: { in: INTENTS }
  validates :type,   presence: true, inclusion: { in: TYPES }
  validates :title,  presence: true, length: { maximum: 200 }
  validates :meta_description, length: { maximum: 300 }, allow_blank: true
  validates :intent, uniqueness: { scope: %i[type district_slug rooms] }

  before_save :rerender_caches, if: -> { body_blocks_changed? }

  scope :published, -> { where(published: true) }
  scope :for_landing, ->(intent:, type:, district_slug: nil, rooms: nil) {
    where(intent: intent, type: type, district_slug: district_slug, rooms: rooms)
  }

  # Best-effort URL for this landing on the public site. Used in the
  # admin index ("Open on site →"). Doesn't validate the route — the
  # LandingsController route constraints decide what actually exists.
  def public_path
    base = intent == 'rent' ? '/snyat' : '/kupit'
    parts = [base, type]
    parts << "rayon/#{district_slug}" if district_slug.present?
    parts << (rooms == 'studiya' ? 'studiya' : "#{rooms}-komnatnaya") if rooms.present?
    parts.join('/')
  end

  private

  def rerender_caches
    helper = ActionController::Base.helpers
    # Mix in our helper so we have access to render_landing_blocks /
    # landing_blocks_to_plain. ActionController::Base.helpers carries
    # only built-in tag helpers by default.
    helper.extend(LandingBlocksHelper)

    self.body_html  = helper.render_landing_blocks(body_blocks).to_s
    self.body_plain = helper.landing_blocks_to_plain(body_blocks).to_s
  end
end
