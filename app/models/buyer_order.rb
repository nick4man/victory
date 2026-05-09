# frozen_string_literal: true

# Mirror of Topnlab `type=order` cards (Покупатели/Арендаторы) — agents see them
# in /dashboard/orders. Personal client info is stored in masked form
# (`client_phone_masked`, `client_name`); full PII stays in Topnlab.
class BuyerOrder < ApplicationRecord
  belongs_to :user, optional: true
  has_many :notes, as: :notable, dependent: :destroy

  ACTIVE_STATES = %w[lead active ad prepayment deferred].freeze

  scope :active,        -> { where(deal_state: ACTIVE_STATES) }
  scope :inactive,      -> { where.not(deal_state: ACTIVE_STATES) }
  scope :recent,        -> { order(synced_at: :desc) }
  scope :for_district,  ->(d) { where('? = ANY(preferred_districts)', d.to_s) if d.present? }
  scope :for_city,      ->(c) { where('? = ANY(preferred_cities)', c.to_s) if c.present? }
  scope :realty_type_eq, ->(t) { where(realty_type: t) if t.present? }
  scope :deal_type_eq,  ->(t) { where(deal_type: t) if t.present? }
  scope :within_price, ->(min, max) {
    s = all
    s = s.where('price_min IS NULL OR price_min <= ?', max) if max.to_i.positive?
    s = s.where('price_max IS NULL OR price_max >= ?', min) if min.to_i.positive?
    s
  }
  scope :for_agent, ->(uid) { where(user_id: uid) if uid.present? }

  def title
    parts = []
    parts << I18n.t("deal_types.#{deal_type}", default: deal_type.to_s.humanize)
    parts << I18n.t("realty_types.#{realty_type}", default: realty_type.to_s.humanize) if realty_type.present?
    if rooms_min || rooms_max
      parts << "#{[rooms_min, rooms_max].compact.uniq.join('-')}-комн."
    end
    parts << preferred_districts.first if preferred_districts.any?
    parts.join(', ')
  end

  def price_range
    return nil if price_min.blank? && price_max.blank?
    return "до #{number(price_max)} ₽" if price_min.blank?
    return "от #{number(price_min)} ₽" if price_max.blank?
    "#{number(price_min)} — #{number(price_max)} ₽"
  end

  def matching_properties(limit: 12)
    pt_id = PropertyType.find_by(slug: realty_type)&.id
    return Property.none if pt_id.nil?

    s = Property.published.where(property_type_id: pt_id, deal_type: deal_type)
    s = s.where('price >= ?', price_min) if price_min
    s = s.where('price <= ?', price_max) if price_max
    s = s.where('area >= ?', area_min) if area_min
    s = s.where('area <= ?', area_max) if area_max
    s = s.where('rooms >= ?', rooms_min) if rooms_min
    s = s.where('rooms <= ?', rooms_max) if rooms_max
    s = s.where(district: preferred_districts) if preferred_districts.any?
    s.order(updated_at: :desc).limit(limit)
  end

  private

  def number(value)
    ActionController::Base.helpers.number_with_delimiter(value.to_i, delimiter: ' ')
  end
end
