# frozen_string_literal: true

FactoryBot.define do
  factory :landing_content do
    intent { 'sale' }
    # `type` — настоящая колонка каталога, не STI (см. LandingContent:16).
    type { 'kvartira' }
    # Уникальный индекс (intent, type, district_slug, rooms) — раздаём разные районы.
    sequence(:district_slug) do |n|
      slugs = RyazanDistricts.all_micro_slugs
      slugs[n % slugs.size]
    end
    title { 'Купить квартиру — тестовый лендинг' }
    published { true }

    trait :with_blocks do
      body_blocks do
        [
          { 'kind' => 'heading',   'text' => 'О районе' },
          { 'kind' => 'paragraph', 'text' => 'Крупный спальный микрорайон с развитой инфраструктурой.' }
        ]
      end
    end

    # Текст, который ломал разметку, пока начальное состояние ехало через
    # raw() внутри одинарных кавычек HTML-атрибута.
    trait :with_tricky_text do
      body_blocks do
        [
          { 'kind' => 'paragraph',
            'text' => %(Дом'25 «Юг» — <b>цена</b> & сроки, </script> и "кавычки") }
        ]
      end
    end

    trait :draft do
      published { false }
    end
  end
end
