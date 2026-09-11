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

    # Гейт — `empty_value?`, а не `!value.nil?`: пустая строка/массив из
    # attrs на новой записи — тоже «данных нет». Проверяем прогоном, а не
    # чтением кода: на `!value.nil?` этот пример упал бы (developer и
    # address_patterns попали бы в filled).
    it 'не применяет пустую строку и пустой массив из attrs' do
      new_complex = ResidentialComplex.new(city: 'Рязань')

      filled = described_class.apply(new_complex, developer: '', address_patterns: [])

      expect(filled).to be_empty
      expect(new_complex.developer).to be_nil
      expect(new_complex.address_patterns).to eq([])
    end

    it 'не применяет строку из одних пробелов' do
      new_complex = ResidentialComplex.new(city: 'Рязань')

      filled = described_class.apply(new_complex, developer: '   ')

      expect(filled).to be_empty
      expect(new_complex.developer).to be_nil
    end
  end

  describe '.empty_value?' do
    # Гейт стоял на `value.present?`, и это была заряженная ловушка,
    # описанная в самом файле: в день, когда в FILLABLE попадут булевы
    # поля удобств, наблюдение «парковки нет» перестало бы применяться
    # МОЛЧА. Через `apply` ловушка сегодня ненаблюдаема (булевой
    # FILLABLE-колонки нет), через предикат — наблюдаема, и мутация
    # «вернуть present?» роняет ровно этот пример.
    it 'не считает false отсутствием данных' do
      expect(described_class.empty_value?(false)).to be false
    end

    it 'считает отсутствием данных nil, пустую строку и пустой массив' do
      expect([nil, '', []].map { |value| described_class.empty_value?(value) }).to all(be true)
    end

    it 'считает отсутствием данных строку из одних пробелов' do
      # Прежний `present?` считал её пустотой, голый `empty?` — уже нет:
      # без `strip` «   » доезжало бы в публичную колонку, а `name: "   "`
      # роняло бы наблюдение целиком.
      expect(["\t\n", '   '].map { |value| described_class.empty_value?(value) }).to all(be true)
    end

    it 'не считает отсутствием данных ноль — 0 комнат это студия, а не пропуск' do
      expect(described_class.empty_value?(0)).to be false
    end
  end
end
