# frozen_string_literal: true

require 'rails_helper'

# Правило заполнения зависит от того, сохранена ли запись — см. комментарий
# в самом сервисе. Здесь то же самое проверяется тестами: на новой записи
# заполняется всё непустое, на сохранённой — только строго `nil` (не
# `blank?`), потому что стёртое редактором поле (`''`, `[]`) — осознанное
# решение человека, а не пропуск.
RSpec.describe Zhk::FactApplier do
  let(:complex) { create(:residential_complex, developer: nil, address_patterns: []) }

  it 'заполняет пустое поле и сообщает, что заполнил' do
    filled = described_class.apply(complex, developer: 'Единство')

    expect(filled).to eq(%i[developer])
    expect(complex.developer).to eq('Единство')
  end

  it 'не трогает то, что уже заполнено — иначе прогон откатывал бы правки редактора' do
    complex.update!(developer: 'Правка редактора')

    filled = described_class.apply(complex, developer: 'Единство')

    expect(filled).to be_empty
    expect(complex.developer).to eq('Правка редактора')
  end

  # Регресс: у address_patterns дефолт [] — уже НЕ nil на сохранённой записи,
  # и это осознанно стёртое редактором значение (см. Admin::ResidentialComplexesController
  # #normalized_params — там тоже проверка на nil, а не blank?, ровно за этим).
  it 'на сохранённой записи не восстанавливает пустой массив, стёртый редактором' do
    filled = described_class.apply(complex, address_patterns: ['ул. Льговская, д. 10'])

    expect(filled).to be_empty
    expect(complex.address_patterns).to eq([])
  end

  it 'игнорирует поля вне белого списка' do
    filled = described_class.apply(complex, published: true, id: 999)

    expect(filled).to be_empty
    expect(complex.published).to be false
  end

  it 'игнорирует nil — источник промолчал, а не сообщил пустоту' do
    complex.update!(developer: 'Единство')

    expect(described_class.apply(complex, developer: nil)).to be_empty
    expect(complex.developer).to eq('Единство')
  end

  context 'на сохранённой записи со стёртым полем' do
    it 'не восстанавливает пустую строку, стёртую редактором осознанно' do
      complex.update!(address: '')

      filled = described_class.apply(complex, address: 'ул. Костычева, 8')

      expect(filled).to be_empty
      expect(complex.address).to eq('')
    end
  end

  context 'на новой записи' do
    it 'заполняет всё непустое, включая address_patterns' do
      new_complex = ResidentialComplex.new(city: 'Рязань')

      filled = described_class.apply(
        new_complex,
        name: 'Легенда', developer: 'Единство', address_patterns: ['ул. Льговская, д. 10']
      )

      expect(filled).to match_array(%i[name developer address_patterns])
      expect(new_complex.name).to eq('Легенда')
      expect(new_complex.developer).to eq('Единство')
      expect(new_complex.address_patterns).to eq(['ул. Льговская, д. 10'])
    end
  end
end
