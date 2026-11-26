# frozen_string_literal: true

# Анонимная запись на показ — легитимный сценарий: большинство посетителей
# не залогинены (current_user nil), а колонка user_id была NOT NULL — INSERT
# падал даже после приведения атрибутов модели к схеме (t_6bbf76ae).
class AllowNullUserInViewingSchedules < ActiveRecord::Migration[8.1]
  def change
    change_column_null :viewing_schedules, :user_id, true
  end
end
