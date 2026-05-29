# frozen_string_literal: true

# Phase 16 — детектит submissions от staff (тестирование на проде) или
# obvious test data, чтобы не смешивать с real client leads / valuations.
#
# Use cases:
#   • Lead::Intake hooks → tag Inquiry/LeadEvent
#   • PropertyValuation create callback → tag valuation
#   • Admin tooling → проверить произвольный input
#
# Detection cascading (первое попадание выигрывает):
#   1. test_marker_email — email matches *test*, *example*, *@victory.ru staff
#   2. test_marker_name  — name содержит "тест", "test"
#   3. email_staff_match — email совпадает с TelegramUser.email ИЛИ User.role IN (staff)
#   4. phone_staff_match — phone (last 10) совпадает с staff phone
#   5. tg_staff_match    — tg_user_id совпадает с TelegramUser.tg_user_id
#   6. name_staff_first  — name совпадает с TelegramUser.first_name (staff first names)
#
# Никакой ML / fuzzy match — все правила deterministic для review-ability.
# Если хочется добавить новое правило — добавить ветку в #detect, добавить
# tag в STAFF_TEST_REASONS и обновить spec.
class StaffSubmissionDetector
  STAFF_TEST_REASONS = %w[
    test_marker_email
    test_marker_name
    email_staff_match
    phone_staff_match
    tg_staff_match
    name_staff_first
  ].freeze

  # Test/example email patterns.
  TEST_EMAIL_RX = /(?:@test\.|@example\.|test@|example@|\+test@|phase\d.*test|stub@)/i.freeze
  # Test name markers — case-insensitive substring.
  TEST_NAME_RX = /\b(тест|test|phase\d.*test|sample|dummy|fixture)\b/i.freeze

  Result = Struct.new(:staff_test, :matched_by, keyword_init: true) do
    def to_h_attrs
      { staff_test: staff_test, staff_test_matched_by: matched_by }
    end
  end

  # @param email [String, nil]
  # @param phone [String, nil]
  # @param name  [String, nil]
  # @param tg_user_id [Integer, nil]
  # @return [Result]
  def self.detect(email: nil, phone: nil, name: nil, tg_user_id: nil)
    new(email: email, phone: phone, name: name, tg_user_id: tg_user_id).detect
  end

  def initialize(email:, phone:, name:, tg_user_id:)
    @email = email.to_s.downcase.strip
    @phone = phone.to_s
    @name  = name.to_s.downcase.strip
    @tg_user_id = tg_user_id&.to_i
  end

  def detect
    # 1. Test email patterns
    return tag(:test_marker_email) if @email.match?(TEST_EMAIL_RX)

    # 2. Test name markers
    return tag(:test_marker_name) if @name.match?(TEST_NAME_RX)

    # 3. Email совпадает с staff
    return tag(:email_staff_match) if email_matches_staff?

    # 4. Phone last-10 совпадает с staff
    return tag(:phone_staff_match) if phone_matches_staff?

    # 5. tg_user_id совпадает с staff
    return tag(:tg_staff_match) if tg_matches_staff?

    # 6. Name совпадает с staff first_name (Надежда, Оксана, Сергей, Ирина и т.д.)
    return tag(:name_staff_first) if name_matches_staff_first?

    Result.new(staff_test: false, matched_by: nil)
  end

  private

  def tag(reason)
    Result.new(staff_test: true, matched_by: reason.to_s)
  end

  def email_matches_staff?
    return false if @email.blank?

    # Через TelegramUser.email (active staff)
    return true if ::TelegramUser.where(status: 'active').where('LOWER(email) = ?', @email).exists?

    # Через User.role (внутренний staff)
    ::User.where(role: %i[agent manager admin], deleted_at: nil, active: true)
          .where('LOWER(email) = ?', @email).exists?
  end

  def phone_matches_staff?
    last10 = @phone.gsub(/\D/, '').last(10)
    return false if last10.length < 10

    ::User.where(role: %i[agent manager admin], deleted_at: nil, active: true)
          .where('phone LIKE ?', "%#{last10}").exists?
  end

  def tg_matches_staff?
    return false if @tg_user_id.blank? || !@tg_user_id.positive?

    ::TelegramUser.where(tg_user_id: @tg_user_id, status: 'active').exists?
  end

  # Имена staff с TelegramUser.first_name (нормализованные lowercase). Cached
  # per-instance — invocation typically per-submission, не loop'им БД.
  STAFF_FIRST_NAMES_CACHE_KEY = 'staff_submission_detector:first_names_v1'

  def name_matches_staff_first?
    return false if @name.length < 3 # «Ан» / «Ир» — слишком общее

    staff_firsts = Rails.cache.fetch(STAFF_FIRST_NAMES_CACHE_KEY, expires_in: 5.minutes) do
      ::TelegramUser.where(status: 'active')
                    .where.not(first_name: [nil, ''])
                    .pluck(:first_name)
                    .map { |f| f.to_s.downcase.strip }
                    .uniq
    end

    # Exact match (имя submitter'а = staff first_name полностью)
    staff_firsts.include?(@name)
  end
end
