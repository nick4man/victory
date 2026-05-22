# frozen_string_literal: true

# Phase 16 — auto-tagging staff/test submissions для отделения от real client'ов.
#
# Контекст: Lead #70 «Phase2 Test», #78/#79 «Тест Клиент», Надеждины
# PropertyValuation (она же staff но активно тестирует через сайт). Без
# tagging эти данные смешиваются с real client leads в KPI, dashboard,
# списках. Authentication-based gating отпугнёт real клиентов — instead
# tag'аем через эвристики (email/phone match с staff, name/email markers).
#
# staff_test_matched_by — string причина detection: 'email_staff_match',
# 'phone_staff_match', 'tg_staff_match', 'test_marker_name',
# 'test_marker_email' (для observability в admin/health).
class AddStaffTestTagging < ActiveRecord::Migration[7.1]
  def change
    add_column :inquiries,            :staff_test,            :boolean, default: false, null: false
    add_column :inquiries,            :staff_test_matched_by, :string,  limit: 64

    add_column :property_valuations,  :staff_test,            :boolean, default: false, null: false
    add_column :property_valuations,  :staff_test_matched_by, :string,  limit: 64

    add_column :lead_events,          :staff_test,            :boolean, default: false, null: false
    add_column :lead_events,          :staff_test_matched_by, :string,  limit: 64

    # Filter индекс — common queries WHERE staff_test=false (real клиенты).
    add_index :inquiries,           :staff_test
    add_index :property_valuations, :staff_test
    add_index :lead_events,         :staff_test
  end
end
