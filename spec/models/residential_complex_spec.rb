# frozen_string_literal: true

require 'rails_helper'

# A2 — справочник ЖК. Покрываем то, что ломает публичные URL и индексацию:
# слаги (публичный контракт), soft-delete, правила sitemap_ready/indexable
# (они же управляют noindex-guard'ом), валидацию района (битый слаг тихо
# ломает перелинковку) и пре-рендер блоков через общий concern.
RSpec.describe ResidentialComplex do
  describe 'слаги' do
    it 'транслитерирует кириллицу вместо схлопывания в пустую строку' do
      complex = create(:residential_complex, name: 'Приокский парк')

      expect(complex.slug).to eq('priokskiy-park')
    end

    it 'не ротирует слаг опубликованного ЖК при переименовании' do
      complex = create(:residential_complex, :with_body, name: 'Легенда')
      original = complex.slug

      complex.update!(name: 'Легенда Плюс')

      expect(complex.reload.slug).to eq(original)
    end

    it 'ротирует слаг неопубликованного ЖК, сохраняя старый резолвимым' do
      complex = create(:residential_complex, name: 'Черновик')
      old_slug = complex.slug

      complex.update!(name: 'Скобелев')

      expect(complex.reload.slug).to eq('skobelev')
      expect(described_class.friendly.find(old_slug)).to eq(complex)
    end

    it 'держит слаг уникальным' do
      create(:residential_complex, name: 'Открытие')
      duplicate = create(:residential_complex, name: 'Открытие')

      expect(duplicate.slug).not_to eq('otkrytie')
    end
  end

  describe 'soft-delete' do
    it 'исключает удалённые из default_scope и возвращает через unscoped' do
      complex = create(:residential_complex)
      complex.soft_delete!

      expect(described_class.find_by(id: complex.id)).to be_nil
      expect(described_class.unscoped.find_by(id: complex.id)).to eq(complex)
    end
  end

  describe 'скоупы' do
    let!(:draft)     { create(:residential_complex, name: 'Черновик') }
    let!(:no_body)   { create(:residential_complex, :published, name: 'Без текста') }
    let!(:ready)     { create(:residential_complex, :with_body, name: 'Готовый') }

    it 'visible возвращает только опубликованные' do
      expect(described_class.visible).to contain_exactly(no_body, ready)
    end

    it 'sitemap_ready требует собственный редакционный текст' do
      expect(described_class.sitemap_ready).to contain_exactly(ready)
      expect(described_class.sitemap_ready).not_to include(no_body, draft)
    end

    it 'in_district фильтрует по слагу района' do
      other = create(:residential_complex, district_slug: 'solotcha')

      expect(described_class.in_district('solotcha')).to contain_exactly(other)
    end
  end

  describe 'enum-префиксы (правило #2 CLAUDE.md)' do
    it 'генерирует префиксные предикаты' do
      complex = build(:residential_complex, housing_class: :comfort, build_status: :completed)

      expect(complex.housing_class_comfort?).to be(true)
      expect(complex.build_status_completed?).to be(true)
      expect(complex.build_status_planned?).to be(false)
    end
  end

  describe 'валидация района' do
    it 'принимает известный микрорайон' do
      expect(build(:residential_complex, district_slug: 'kanishchevo')).to be_valid
    end

    it 'принимает админ-район' do
      expect(build(:residential_complex, district_slug: 'moskovskiy')).to be_valid
    end

    it 'отвергает неизвестный слаг' do
      complex = build(:residential_complex, district_slug: 'nesushchestvuyushchiy')

      expect(complex).not_to be_valid
      expect(complex.errors[:district_slug].join).to include('неизвестен')
    end

    it 'разрешает пустой слаг' do
      expect(build(:residential_complex, district_slug: nil)).to be_valid
    end

    it 'сверяется с реестром города, а не только Рязани' do
      complex = build(:residential_complex, city: 'Москва', district_slug: 'kanishchevo')

      expect(complex).not_to be_valid
    end
  end

  describe 'пре-рендер блоков (RendersLandingBlocks)' do
    it 'заполняет body_html и body_plain на save' do
      complex = create(:residential_complex, :with_body)

      expect(complex.body_html).to include('<h2>О комплексе</h2>')
      expect(complex.body_plain).to include('Дом сдан в 2021 году')
    end

    it 'эмитит details/summary для faq — FAQPage JSON-LD достаётся без нового кода' do
      complex = create(:residential_complex, :with_faq)

      expect(complex.body_html).to include('<details>')
      expect(complex.body_html).to include('<summary>Есть ли парковка?</summary>')
    end
  end

  describe 'правила индексации' do
    let(:user) do
      User.create!(
        email: "zhk-#{SecureRandom.hex(4)}@victory.test",
        first_name: 'Test', last_name: 'Agent',
        password: 'TestPass123!', password_confirmation: 'TestPass123!'
      )
    end

    def create_listing(complex)
      prop = Property.new(
        user: user,
        title: "Квартира в ЖК #{complex.name}",
        description: 'Тестовое описание объекта.',
        price: 5_500_000, area: 54, rooms: 2,
        deal_type: :sale, status: :active, condition: :normal,
        address: 'Рязань, ул. Костычева, д. 8, кв. 10',
        district: 'Канищево',
        published_at: Time.current,
        residential_complex: complex
      )
      # published_properties_must_be_complete требует ≥1 изображение
      prop.images.attach(
        io: StringIO.new("\xFF\xD8\xFF\xD9".b), filename: 'test.jpg', content_type: 'image/jpeg'
      )
      prop.save!
      prop
    end

    it 'индексирует опубликованный ЖК с текстом даже без объектов' do
      complex = create(:residential_complex, :with_body)

      expect(complex.on_site_listings_count).to eq(0)
      expect(complex).to be_indexable
    end

    it 'индексирует опубликованный ЖК без текста, пока есть живые объекты' do
      complex = create(:residential_complex, :published)
      create_listing(complex)

      expect(complex.on_site_listings_count).to eq(1)
      expect(complex).to be_indexable
    end

    it 'не индексирует пустой ЖК без текста и без объектов' do
      complex = create(:residential_complex, :published)

      expect(complex).not_to be_indexable
    end

    it 'не считает черновики объектов' do
      complex = create(:residential_complex, :published)
      listing = create_listing(complex)
      listing.update_columns(status: Property.statuses[:draft])

      expect(complex.on_site_listings_count).to eq(0)
    end
  end

  describe 'публичное представление' do
    it 'отдаёт путь и отображаемое имя' do
      complex = create(:residential_complex, name: 'Легенда')

      expect(complex.public_path).to eq('/zhk/legenda')
      expect(complex.display_name).to eq('ЖК «Легенда»')
    end
  end
end
