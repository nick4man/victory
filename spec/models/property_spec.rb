# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Property, type: :model do
  # ============================================
  # ASSOCIATIONS
  # ============================================
  describe 'associations' do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:property_type).optional }
    it { is_expected.to have_many(:favorites).dependent(:destroy) }
    it { is_expected.to have_many(:inquiries).dependent(:destroy) }
    it { is_expected.to have_many(:property_views).dependent(:destroy) }
    it { is_expected.to have_many(:price_histories).dependent(:destroy) }
  end

  # ============================================
  # VALIDATIONS
  # ============================================
  describe 'validations' do
    subject { build(:property) }

    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:price) }
    it { is_expected.to validate_presence_of(:area) }
    it { is_expected.to validate_presence_of(:address) }

    it { is_expected.to validate_length_of(:title).is_at_least(10).is_at_most(200) }
    it { is_expected.to validate_numericality_of(:price).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:area).is_greater_than(0) }
  end

  # ============================================
  # ENUMS
  # ============================================
  describe 'enums' do
    it { is_expected.to define_enum_for(:deal_type).with_values(sale: 0, rent: 1, daily: 2).with_prefix }
    it { is_expected.to define_enum_for(:status).with_values(
      draft: 0, pending: 1, active: 2, sold: 3, rented: 4, archived: 5, rejected: 6
    ).with_prefix }
    it { is_expected.to define_enum_for(:condition).with_values(
      needs_repair: 0, normal: 1, renovated: 2, euro: 3, designer: 4
    ).with_prefix }
  end

  # ============================================
  # SCOPES
  # ============================================
  describe 'scopes' do
    let!(:active_property) { create(:property, :active) }
    let!(:draft_property)  { create(:property, :draft) }
    let!(:sold_property)   { create(:property, status: :sold) }

    describe '.published' do
      it 'возвращает только активные с датой публикации' do
        expect(Property.published).to include(active_property)
        expect(Property.published).not_to include(draft_property)
      end
    end

    describe '.for_sale' do
      let!(:rent_property) { create(:property, :active, :for_rent) }

      it 'возвращает только объекты на продажу' do
        expect(Property.for_sale).to include(active_property)
        expect(Property.for_sale).not_to include(rent_property)
      end
    end

    describe '.not_deleted' do
      let!(:deleted_property) { create(:property, deleted_at: 1.day.ago) }

      it 'исключает удалённые объекты' do
        expect(Property.unscoped.not_deleted).to include(active_property)
        expect(Property.unscoped.not_deleted).not_to include(deleted_property)
      end
    end
  end

  # ============================================
  # INSTANCE METHODS
  # ============================================
  describe '#price_formatted' do
    it 'форматирует цену с разделителями и символом рубля' do
      property = build(:property, price: 5_000_000)
      expect(property.price_formatted).to include('₽')
      expect(property.price_formatted).to include('5')
    end
  end

  describe '#publish!' do
    let(:property) { create(:property, status: :draft) }

    it 'переводит объект в статус active' do
      property.publish!
      expect(property.reload).to be_status_active
    end

    it 'устанавливает published_at' do
      property.publish!
      expect(property.reload.published_at).to be_present
    end
  end

  describe '#unpublish!' do
    let(:property) { create(:property, :active) }

    it 'переводит объект в статус archived' do
      property.unpublish!
      expect(property.reload).to be_status_archived
    end

    it 'очищает published_at' do
      property.unpublish!
      expect(property.reload.published_at).to be_nil
    end
  end

  describe '#soft_delete!' do
    let(:property) { create(:property, :active) }

    it 'устанавливает deleted_at' do
      property.soft_delete!
      expect(property.reload.deleted_at).to be_present
    end

    it 'исключает объект из default scope' do
      property.soft_delete!
      expect(Property.all).not_to include(property)
    end
  end

  describe '#published?' do
    it 'возвращает true для активного опубликованного объекта' do
      property = create(:property, :active)
      expect(property).to be_published
    end

    it 'возвращает false для черновика' do
      property = build(:property, :draft)
      expect(property).not_to be_published
    end
  end

  # ============================================
  # PRICE PER SQM
  # ============================================
  describe 'вычисление цены за м²' do
    it 'рассчитывает price_per_sqm при сохранении' do
      property = create(:property, price: 5_000_000, area: 50)
      expect(property.price_per_sqm).to eq(100_000)
    end
  end
end
