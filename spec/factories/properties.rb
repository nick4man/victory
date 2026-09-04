# frozen_string_literal: true

# Первая фабрика Property в проекте (09.08.26). Модель тяжёлая: обязательный
# user, валидация полноты для публикации (нужна хотя бы одна картинка) и
# гео-колбэки. Держим минимальный набор — расширять по мере надобности.
FactoryBot.define do
  factory :property do
    association :user
    sequence(:title) { |n| "Тестовая квартира №#{n}" }
    description { 'Тестовое описание объекта.' }
    price { 5_500_000 }
    area { 54 }
    rooms { 2 }
    deal_type { :sale }
    status { :draft }
    condition { :normal }
    address { 'Рязанская обл., г. Рязань, ул. Тестовая, д. 1' }
    district { 'Канищево' }
    city { 'Рязань' }

    # published_properties_must_be_complete требует ≥1 изображение у
    # active+published. Валидация смотрит только content_type и размер,
    # содержимое не декодирует — хватает минимального валидного JPEG.
    trait :on_site do
      status { :active }
      published_at { Time.current }

      after(:build) do |property|
        property.images.attach(
          io: StringIO.new("\xFF\xD8\xFF\xD9".b),
          filename: 'test.jpg',
          content_type: 'image/jpeg'
        )
      end
    end

    trait :with_coordinates do
      latitude  { 54.6269 }
      longitude { 39.6916 }
    end

    trait :without_district do
      district { nil }
    end
  end
end
