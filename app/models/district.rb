# frozen_string_literal: true

# == Schema Information
#
# Table name: districts
#
#  id         :bigint   not null, primary key
#  name       :string   not null
#  city       :string
#  boundary   :geometry(MultiPolygon, 4326)  not null
#  created_at :datetime not null
#  updated_at :datetime not null
#
# Polygon district boundaries (Воронеж first). Loaded by
# `rake districts:import_voronezh`. Used by ChatTools::FindInDistrictPolygon
# to filter properties via ST_Within instead of fuzzy text comparison.
class District < ApplicationRecord
  validates :name, presence: true
  validates :name, uniqueness: { scope: :city }

  scope :in_city, ->(city) { where(city: city) }

  # Properties whose geom falls inside this district's polygon.
  def properties_within
    Property.on_site
            .where('ST_Within(properties.geom::geometry, ?)', boundary)
  end
end
