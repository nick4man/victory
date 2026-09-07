# frozen_string_literal: true

# Провенанс по полю: один ЖК × одно поле × один источник = одна строка.
# `value` строкой намеренно — журнал хранит то, что сказал источник, а
# типизация это забота потребителя.
class CreateZhkFacts < ActiveRecord::Migration[8.1]
  def change
    # index: false — одиночный (residential_complex_id) был бы левым
    # префиксом idx_zhk_facts_identity ниже, Postgres читает составной
    # индекс по префиксу, второй b-tree на каждую вставку не нужен.
    create_table :zhk_facts do |t|
      t.references :residential_complex, null: false, foreign_key: true, index: false
      t.string     :field,       null: false
      t.string     :value
      t.string     :source,      null: false
      t.string     :url
      t.datetime   :observed_at, null: false
      t.timestamps
    end

    add_index :zhk_facts, %i[residential_complex_id field source], unique: true,
              name: 'idx_zhk_facts_identity'
  end
end
