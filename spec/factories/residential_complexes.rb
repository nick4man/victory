# frozen_string_literal: true

FactoryBot.define do
  factory :residential_complex do
    sequence(:name) { |n| "Легенда #{n}" }
    city { 'Рязань' }
    district_slug { 'kanishchevo' }
    developer { 'Единство' }
    address { 'ул. Костычева, 8' }
    published { false }

    trait :published do
      published { true }
    end

    # Опубликован + есть собственный текст → sitemap_ready
    trait :with_body do
      published { true }
      body_blocks do
        [
          { 'kind' => 'heading',   'text' => 'О комплексе' },
          { 'kind' => 'paragraph', 'text' => 'Дом сдан в 2021 году, три корпуса, закрытый двор.' }
        ]
      end
    end

    trait :with_faq do
      body_blocks do
        [
          { 'kind' => 'paragraph', 'text' => 'Короткое описание комплекса.' },
          { 'kind' => 'faq', 'items' => [{ 'q' => 'Есть ли парковка?', 'a' => 'Да, подземный паркинг.' }] }
        ]
      end
    end

    trait :soft_deleted do
      deleted_at { Time.current }
    end
  end
end
