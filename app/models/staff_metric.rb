# frozen_string_literal: true

# Phase 7.6 — Daily KPI snapshot. См. миграцию 20260527000800.
class StaffMetric < ApplicationRecord
  belongs_to :staff, class_name: 'TelegramUser'

  validates :date, presence: true
  validates :staff_id, uniqueness: { scope: :date }

  scope :for_date,   ->(date) { where(date: date) }
  scope :for_period, ->(range) { where(date: range) }
  scope :for_staff,  ->(tg_user) { where(staff: tg_user) }

  # === Derived (compute, не хранятся) ===
  def completion_rate
    return 0.0 if tasks_assigned.zero?

    tasks_completed.to_f / tasks_assigned
  end

  def on_time_rate
    return 0.0 if tasks_completed.zero?

    tasks_on_time.to_f / tasks_completed
  end

  def question_dependency
    return 0.0 if tasks_completed.zero?

    questions_asked.to_f / tasks_completed
  end

  # Lead-conversion НЕ из daily snapshot — это 90d window (recomputed на view).
  # Метод нужен для удобного отображения если кто-то посчитал поле.
  def lead_conversion_rate_local
    return 0.0 if leads_assigned.zero?

    leads_converted.to_f / leads_assigned
  end

  def first_contact_30m_rate
    return 0.0 if leads_assigned.zero?

    leads_first_contact_in_30m.to_f / leads_assigned
  end
end
