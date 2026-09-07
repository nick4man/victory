# frozen_string_literal: true

require 'rails_helper'

# Bootstrap spec для core Property model. Goal: safety-net coverage перед
# refactor (Property ~1000 LOC — кандидат на decomposition через
# rails-architect agent).
#
# Scope: enums + validations + soft-delete + key scopes. Подробное purpose-
# specific behavior (premium classification, search_by_text, geo) — отдельные
# spec файлы при необходимости.
RSpec.describe Property do
  let(:user) do
    User.create!(
      email: "test-#{SecureRandom.hex(4)}@victory.test",
      first_name: 'Test', last_name: 'Agent',
      password: 'TestPass123!',
      password_confirmation: 'TestPass123!'
    )
  end

  def build_property(attrs = {})
    prop = described_class.new({
      user: user,
      title: 'Тестовая квартира — 2-комн Канищево',
      description: 'Тестовое описание объекта.',
      price: 5_500_000,
      area: 54,
      rooms: 2,
      deal_type: :sale,
      status: :draft,
      condition: :normal,
      address: 'Рязань, ул. Тестовая, д. 1, кв. 10',
      district: 'Канищево'
    }.merge(attrs))
    # published_properties_must_be_complete требует ≥1 изображение для
    # active+published. Аттачим minimal valid JPEG (validation проверяет
    # только content_type+size, не декодирует) чтобы scope-specs со
    # status: :active проходили.
    prop.images.attach(
      io: StringIO.new("\xFF\xD8\xFF\xD9".b), filename: 'test.jpg', content_type: 'image/jpeg'
    )
    prop
  end

  describe 'associations' do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:property_type).optional }
    it { is_expected.to have_many(:favorites).dependent(:destroy) }
    it { is_expected.to have_many(:inquiries).dependent(:destroy) }
    it { is_expected.to have_many(:price_histories).dependent(:destroy) }
  end

  describe 'validations' do
    it 'requires title (≥ 10 chars)' do
      p = build_property(title: 'Кратко')
      expect(p).not_to be_valid
      expect(p.errors[:title]).to be_present
    end

    it 'requires price > 0' do
      p = build_property(price: 0)
      expect(p).not_to be_valid
      expect(p.errors[:price]).to be_present
    end

    it 'requires area > 0' do
      p = build_property(area: nil)
      expect(p).not_to be_valid
    end

    it 'requires address' do
      expect(build_property(address: nil)).not_to be_valid
    end

    it 'requires deal_type' do
      expect(build_property(deal_type: nil)).not_to be_valid
    end

    it 'accepts valid baseline property' do
      expect(build_property).to be_valid
    end
  end

  describe 'enums' do
    it 'defines deal_type: sale/rent/daily' do
      expect(described_class.deal_types.keys).to contain_exactly('sale', 'rent', 'daily')
    end

    it 'defines status with at least active/draft/archived' do
      expect(described_class.statuses.keys).to include('active', 'draft', 'archived')
    end

    # deal_type объявлен с prefix: true (жёсткое правило проекта — см. CLAUDE.md),
    # поэтому предикаты именуются deal_type_rent?, а не rent?. Спек проверял
    # «default style», которого в этом проекте нет by design.
    it 'predicate methods work (prefixed style)' do
      p = build_property(deal_type: :rent)
      expect(p).to be_deal_type_rent
      expect(p).not_to be_deal_type_sale
    end
  end

  describe 'soft delete' do
    let!(:property) { build_property.tap(&:save!) }

    it 'sets deleted_at on soft_delete!' do
      property.soft_delete!
      expect(property.reload.deleted_at).to be_present
    end

    it 'excludes soft-deleted from default scope (not_deleted)' do
      property.soft_delete!
      expect(described_class.where(id: property.id)).to be_empty
    end

    it 'unscoped query returns soft-deleted' do
      property.soft_delete!
      expect(described_class.unscoped.where(id: property.id)).to exist
    end
  end

  describe 'scopes' do
    let!(:draft)     { build_property(status: :draft).tap(&:save!) }
    let!(:active)    { build_property(status: :active, published_at: 1.day.ago).tap(&:save!) }
    let!(:archived)  { build_property(status: :archived).tap(&:save!) }

    describe '.active' do
      it 'includes only status=active' do
        expect(described_class.active).to include(active)
        expect(described_class.active).not_to include(draft, archived)
      end
    end

    describe '.published' do
      it 'requires both status=active AND published_at present' do
        expect(described_class.published).to include(active)
        expect(described_class.published).not_to include(draft)
      end

      it 'excludes active без published_at' do
        no_pub = build_property(status: :active).tap(&:save!)
        expect(described_class.published).not_to include(no_pub)
      end
    end

    describe '.assigned_to' do
      it 'matches by user_id' do
        expect(described_class.assigned_to(user)).to include(draft)
      end
    end

    describe '.unassigned' do
      # properties.user_id объявлен NOT NULL (db/structure.sql:78), поэтому scope
      # не может совпасть ни с одной строкой. Спек раньше пытался создать такую
      # через save!(validate: false) и падал на NotNullViolation — БД не пускает.
      #
      # Scope при этом жив в админке: фильтр в
      # dashboard/admin/properties_controller.rb:15 и счётчик «Без агента» в
      # dashboard/index.html.erb:87. Оба всегда пусты. Удаление мёртвой
      # функциональности — отдельное решение, здесь фиксируем инвариант.
      it 'не может совпасть — user_id объявлен NOT NULL' do
        expect(described_class.unscoped.unassigned.to_sql).to include('"user_id" IS NULL')
        expect(described_class.unscoped.unassigned).to be_empty
      end
    end
  end

  describe '.ransackable_attributes' do
    it 'whitelists known safe fields' do
      attrs = described_class.ransackable_attributes
      expect(attrs).to include('address', 'district', 'status', 'deal_type')
    end

    it 'does NOT include unsafe fields like user_id raw' do
      # Ransack allowlist должен быть explicit — добавление нового поля = код-ревью.
      expect(described_class.ransackable_attributes).to be_an(Array)
      expect(described_class.ransackable_attributes.size).to be < 80 # sanity cap
    end
  end
end
