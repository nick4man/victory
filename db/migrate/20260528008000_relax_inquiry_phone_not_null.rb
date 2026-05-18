# frozen_string_literal: true

# Phase 4D — TG-DM intake create's Inquiry без phone (client пока не дал,
# qualification — отдельный шаг). Model-level validation уже conditional
# (skip когда source='tg_dm'), но DB column был NOT NULL — это блокирует.
class RelaxInquiryPhoneNotNull < ActiveRecord::Migration[7.1]
  def change
    change_column_null :inquiries, :phone, true
  end
end
