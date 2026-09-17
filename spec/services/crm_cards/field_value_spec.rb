# frozen_string_literal: true

require 'rails_helper'

RSpec::Matchers.define_negated_matcher :not_include, :include

RSpec.describe CrmCards::FieldValue do
  def field(type, **opts)
    CrmCards::Schema::Field.new(key: 'x', label: 'X', type: type, required: true, **opts)
  end

  describe 'телефон' do
    it 'приводит российские форматы к 11 цифрам с 7' do
      expect(described_class.normalize(field(:phone), '+7 (910) 123-45-67')).to eq(['79101234567', nil])
      expect(described_class.normalize(field(:phone), '89101234567')).to eq(['79101234567', nil])
      expect(described_class.normalize(field(:phone), '910 123 45 67')).to eq(['79101234567', nil])
    end

    it 'короткий или иностранный номер — ошибка без эха ввода' do
      value, error = described_class.normalize(field(:phone), '<b>123</b>')

      expect(value).to be_nil
      expect(error).to include('нужно 11').and not_include('<b>')
    end

    it 'мусор в номере вычищается, но недостающая цифра не дорисовывается' do
      value, error = described_class.normalize(field(:phone), '+8ш977842598')

      expect(value).to be_nil
      expect(error).to include('10 цифр', '11')
    end

    it 'городской первым номером не принимается — по нему клиенту не перезвонить' do
      value, error = described_class.normalize(field(:phone), '+7 4912 12-34-56')

      expect(value).to be_nil
      expect(error).to include('не мобильный', 'Доп. телефон')
    end

    it 'вторым номером городской принимается — и с кодом страны, и без' do
      expect(described_class.normalize(field(:phone_extra), '+7 4912 12-34-56')).to eq(['74912123456', nil])
      expect(described_class.normalize(field(:phone_extra), '4912 12-34-56')).to eq(['74912123456', nil])
      expect(described_class.normalize(field(:phone_extra), '495 123-45-67')).to eq(['74951234567', nil])
      expect(described_class.normalize(field(:phone_extra), '89101234567')).to eq(['79101234567', nil])
    end

    it 'вторым номером мусорный номер всё равно не принимается' do
      value, error = described_class.normalize(field(:phone_extra), '+8ш977842598')

      expect(value).to be_nil
      expect(error).to include('10 цифр')
    end
  end

  it 'число: пробелы и запятая, целое остаётся целым' do
    expect(described_class.normalize(field(:decimal), '5 500 000')).to eq([5_500_000, nil])
    expect(described_class.normalize(field(:decimal), '54,3')).to eq([54.3, nil])
    expect(described_class.normalize(field(:decimal), '0').last).to include('больше нуля')
    expect(described_class.normalize(field(:decimal), 'много').last).to include('Нужно число')
  end

  it 'целое' do
    expect(described_class.normalize(field(:integer), '3')).to eq([3, nil])
    expect(described_class.normalize(field(:integer), '3.5').last).to include('целое')
  end

  it 'текст: границы длины' do
    text = field(:text, min: 20, max: 30)

    expect(described_class.normalize(text, 'коротко').last).to include('от 20')
    expect(described_class.normalize(text, 'а' * 31).last).to include('влезает 30')
    expect(described_class.normalize(text, '  ровно двадцать символов  ').first).to eq('ровно двадцать символов')
  end

  it 'выбор — только из вариантов' do
    choice = field(:choice, options: [%w[Квартира flat]])

    expect(described_class.normalize(choice, 'flat')).to eq(['flat', nil])
    expect(described_class.normalize(choice, 'castle').last).to include('выбери кнопкой')
  end

  it 'пустое — ошибка' do
    expect(described_class.normalize(field(:string), '   ').last).to eq('Пустое значение.')
  end

  it 'нормализованное значение нормализуется в само себя' do
    expect(described_class.normalize(field(:phone), '79101234567')).to eq(['79101234567', nil])
    expect(described_class.normalize(field(:decimal), 54.3)).to eq([54.3, nil])
    expect(described_class.normalize(field(:integer), 12_345)).to eq([12_345, nil])
  end
end
