# frozen_string_literal: true

# Журнал сырья, как оно пришло от службы сбора. Две задачи: идемпотентность
# (тот же digest не переприменяется) и возможность через полгода ответить
# «откуда мы это взяли», не веря на слово.
class CreateZhkObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :zhk_observations do |t|
      t.string   :source,      null: false
      t.string   :external_id, null: false
      t.string   :url
      t.datetime :fetched_at,  null: false
      t.jsonb    :payload,     null: false, default: {}
      t.string   :digest,      null: false
      t.timestamps
    end

    add_index :zhk_observations, %i[source external_id digest], unique: true,
              name: 'idx_zhk_observations_identity'
    add_index :zhk_observations, %i[source fetched_at]
  end
end
