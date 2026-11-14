# frozen_string_literal: true

# Чат-бот (Llm::PageContext) подгружает факты результата оценки по token
# из ctx страницы — только если оценка принадлежит тому же посетителю.
# Критерий владения — этот токен (signed-cookie идентичности чата,
# см. VisitorIdentity), выставляемый при создании оценки из формы.
class AddVisitorTokenToPropertyValuations < ActiveRecord::Migration[8.1]
  def change
    add_column :property_valuations, :visitor_token, :string
    add_index  :property_valuations, :visitor_token
  end
end
