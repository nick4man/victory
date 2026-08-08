# frozen_string_literal: true

# Property Valuation Model
# Stores property valuation requests and results
class PropertyValuation < ApplicationRecord
  # Associations
  belongs_to :user, optional: true
  has_many_attached :photos
  
  # Enums
  enum :property_type, {
    apartment: 'apartment',
    house: 'house',
    land: 'land',
    commercial: 'commercial',
    garage: 'garage',
    room: 'room'
  }
  
  enum :deal_type, {
    sale: 'sale',
    rent: 'rent'
  }
  
  enum :status, {
    pending: 'pending',
    completed: 'completed',
    failed: 'failed'
  }

  # Express = local hedonic + bootstrap CI on Property+MlsListing.
  # Investment = full audit-engine-v2 pipeline (EI/Monte Carlo/PDF).
  enum :audit_mode, {
    express: 'express',
    investment: 'investment'
  }, prefix: :audit_mode
  
  enum :building_type, {
    panel: 'panel',
    brick: 'brick',
    monolith: 'monolith',
    block: 'block',
    wood: 'wood',
    stalin: 'stalin'
  }
  
  attribute :property_condition, :string
  enum :property_condition, {
    needs_repair: 'needs_repair',
    average: 'average',
    good: 'good',
    excellent: 'excellent',
    designer: 'designer'
  }, prefix: :property_condition
  
  TYPES_REQUIRING_AREA = %w[apartment room house commercial garage].freeze
  TYPES_REQUIRING_LAND_AREA = %w[land].freeze

  # A7 Phase 2: real-time push в /cabinet когда valuation flips
  # pending → completed/failed. Адресат — linked User (user_id) либо
  # User matched по email/phone.
  after_update_commit :broadcast_cabinet_completion, if: :saved_change_to_status?

  # Validations
  # Phase 16 — auto-tag staff/test submissions (Надежда тестирует на проде,
  # «Тест Клиент», phase-test emails — отделяем от real client data).
  # Hook идёт до validation чтобы tag persist'нулся даже если valid? fails позже.
  before_validation :detect_staff_test_submission, on: :create

  validates :property_type, presence: true
  validates :deal_type, presence: true
  validates :address, presence: true, length: { minimum: 10 }
  validates :total_area, presence: true, numericality: { greater_than: 0 },
                         if: -> { property_type.in?(TYPES_REQUIRING_AREA) }
  validates :land_area, presence: true, numericality: { greater_than: 0 },
                        if: -> { property_type.in?(TYPES_REQUIRING_LAND_AREA) }
  validates :floor, numericality: { greater_than: 0 }, allow_nil: true
  validates :total_floors, numericality: { greater_than: 0 }, allow_nil: true
  validates :rooms, numericality: { greater_than: 0 }, allow_nil: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :phone, format: { with: /\A\+?[0-9\s\-\(\)]+\z/ }, allow_blank: true
  validates :token, presence: true, uniqueness: true
  
  validate :floor_not_greater_than_total
  validate :photos_limit
  
  # Callbacks
  before_validation :generate_token, on: :create
  before_validation :resolve_coordinates, on: :create
  before_validation :normalize_phone
  after_create_commit :push_to_work_bot
  
  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :completed, -> { where(status: 'completed') }
  scope :pending, -> { where(status: 'pending') }
  scope :with_email, -> { where.not(email: nil) }
  scope :investment_audits, -> { where(audit_mode: 'investment') }
  scope :express_estimates, -> { where(audit_mode: 'express') }
  
  # Instance Methods
  
  def to_property_params
    {
      property_type: property_type,
      deal_type: deal_type,
      address: address,
      city: city,
      district: district,
      total_area: total_area,
      living_area: living_area,
      kitchen_area: kitchen_area,
      rooms: rooms,
      floor: floor,
      total_floors: total_floors,
      building_type: building_type,
      building_year: building_year,
      property_condition: property_condition,
      has_balcony: has_balcony,
      has_loggia: has_loggia,
      has_garage: has_garage,
      metro_station: metro_station,
      metro_distance: metro_distance,
      land_area: land_area,
      land_category: land_category,
      ownership_type: ownership_type
    }
  end

  # Площадь участка в м² (для алгоритма оценки участков); хранится в сотках.
  def land_area_in_sqm
    return nil if land_area.blank?
    land_area.to_f * 100
  end
  
  def full_name
    name.presence || 'Неизвестный'
  end
  
  def price_range_formatted
    "#{ActionController::Base.helpers.number_to_currency(min_price, precision: 0)} - #{ActionController::Base.helpers.number_to_currency(max_price, precision: 0)}"
  end
  
  def estimated_price_formatted
    ActionController::Base.helpers.number_to_currency(estimated_price, precision: 0)
  end
  
  def confidence_percentage
    (confidence_level * 100).round
  end
  
  def accuracy_level
    case confidence_level
    when 0.8..1.0 then 'Высокая'
    when 0.6..0.8 then 'Средняя'
    else 'Низкая'
    end
  end
  
  def created_at_formatted
    I18n.l(created_at, format: :long)
  end

  # Short human-readable identifier — printed on PDF, shown in UI, used by
  # staff to look up an audit ("откройте отчёт №10042"). Falls back to id
  # for legacy rows that haven't been backfilled (should not happen — the
  # migration backfills all existing rows and the column is NOT NULL).
  def report_label
    "№#{report_number || id}"
  end

  private
  
  def generate_token
    self.token = SecureRandom.urlsafe_base64(16)
  end

  def resolve_coordinates
    return if address.blank? || (latitude.present? && longitude.present?)

    full = [city.presence, district.presence, address].compact.join(', ')
    res = Geocoding::AddressLookup.call(full)
    return unless res

    self.latitude  ||= res.latitude
    self.longitude ||= res.longitude
    self.city      ||= res.city
    self.district  ||= res.district
  end
  
  def normalize_phone
    return unless phone.present?
    
    # Remove all non-digit characters except +
    self.phone = phone.gsub(/[^\d+]/, '')
  end
  
  def floor_not_greater_than_total
    return unless floor.present? && total_floors.present?
    
    errors.add(:floor, 'не может быть больше общего количества этажей') if floor > total_floors
  end
  
  def photos_limit
    return unless photos.attached?
    
    if photos.count > 10
      errors.add(:photos, 'не может быть больше 10')
    end
    
    photos.each do |photo|
      if photo.byte_size > 5.megabytes
        errors.add(:photos, 'размер файла не должен превышать 5 МБ')
      end
      
      unless photo.content_type.in?(%w[image/jpeg image/png image/jpg image/webp])
        errors.add(:photos, 'должны быть в формате JPEG, PNG или WebP')
      end
    end
  end

  # Публикуем заявку оценки в Telegram-бот АН (auto-route в топик ОЦЕНКА).
  # Не блокирует — ошибки логируем и проглатываем.
  def push_to_work_bot
    return if ENV['TG_WORK_BOT_DISABLED'] == 'true'
    return if Thread.current[:skip_workbot_push] == true
    Lead::Intake.call(
      source: 'site_valuation',
      payload: {
        name:    full_name.presence || 'Клиент сайта',
        phone:   phone,
        email:   email,
        address: address,
        area:    total_area,
        rooms:   rooms,
        budget:  estimated_price_formatted,
        valuation_id: id,
        summary: "Запрос оценки: #{address}, #{total_area} м²#{", #{rooms}-комн" if rooms.present?}"
      }
    )
  rescue StandardError => e
    Rails.logger.error("[PropertyValuation#push_to_work_bot] valuation=#{id} #{e.class}: #{e.message}")
  end

  # A7 Phase 2: push completion в /cabinet через CabinetChannel.
  # Адресат — linked User или matched-by-email. Fail-safe.
  def broadcast_cabinet_completion
    target_user = user || User.where(active: true).find_by('LOWER(email) = ?', email.to_s.downcase)
    return if target_user.nil?

    CabinetChannel.broadcast_to(target_user, {
      type:             'valuation_status_changed',
      valuation_id:     id,
      valuation_token:  token,
      status:           status,
      estimated_price:  estimated_price,
      address:          address,
      updated_at:       updated_at.iso8601
    })
  rescue StandardError => e
    Rails.logger.warn("[PropertyValuation##{id}] CabinetChannel broadcast failed: #{e.class} #{e.message}")
  end

  # Phase 16 — staff/test detection. Auto-tag без UX friction.
  def detect_staff_test_submission
    return if staff_test # уже выставлен (например через factory или admin override)

    result = StaffSubmissionDetector.detect(
      email: email, phone: phone, name: name, tg_user_id: nil
    )
    self.staff_test = result.staff_test
    self.staff_test_matched_by = result.matched_by
  end
end

