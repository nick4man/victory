# frozen_string_literal: true

class AddReportNumberToPropertyValuations < ActiveRecord::Migration[7.1]
  def up
    add_column :property_valuations, :report_number, :bigint
    add_index  :property_valuations, :report_number, unique: true

    # Sequence starts at 10001 so numbers are always 5+ digits — visually
    # easy to read aloud and search ("Отчёт №10031").
    execute <<~SQL
      CREATE SEQUENCE IF NOT EXISTS property_valuation_report_number_seq START 10001;
    SQL

    # Backfill existing rows in deterministic order — oldest gets lowest number.
    execute <<~SQL
      UPDATE property_valuations
      SET report_number = nextval('property_valuation_report_number_seq')
      WHERE report_number IS NULL
      AND id IN (SELECT id FROM property_valuations WHERE report_number IS NULL ORDER BY created_at, id);
    SQL

    change_column_default :property_valuations, :report_number,
                          from: nil, to: -> { "nextval('property_valuation_report_number_seq')" }
    change_column_null :property_valuations, :report_number, false
  end

  def down
    remove_index  :property_valuations, :report_number
    remove_column :property_valuations, :report_number
    execute 'DROP SEQUENCE IF EXISTS property_valuation_report_number_seq;'
  end
end
