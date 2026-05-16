# frozen_string_literal: true

# Phase 1.6.A — multi-city foundation.
#
# Каталог уже multi-city: Рязань + Москва + СПб + МО. До этой миграции
# город outделялся at-render time через Property#address_locality (regex
# по address). Phase 1.6.B+ хочет роутить /moskva/* + /spb/* + filter
# по городу в SQL — для этого нужна индексированная колонка, не вычисление
# на лету.
#
# Backfill отдельной rake-командой (не inline в миграции, чтобы prod-
# deploy с большим каталогом не блокировал миграцию).
#
# Default value не задаём — на момент migration backfill runner-script
# заполнит существующие 90 записей. Новые писатели (Topnlab importer,
# admin form) должны проставлять city через after_save callback, который
# добавляется в Phase 1.6.A вместе с этой миграцией.
class AddCityToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :city, :string
    add_index :properties, :city
  end
end
