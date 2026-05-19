# frozen_string_literal: true

# Property.commercial_type — required by YRL <commercial-type> tag для
# category=коммерческая. AI-classified из description (см.
# Property::CommercialTypeClassifier). Допустимые YRL values:
#   офис | торговое помещение | свободного назначения | склад |
#   производство | общепит | гостиница | автосервис | готовый бизнес
# Admin может override через admin UI (TBD future).
class AddCommercialTypeToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :commercial_type, :string
    add_index  :properties, :commercial_type
  end
end
