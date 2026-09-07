# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::Matcher do
  let!(:legenda) do
    create(:residential_complex, name: 'Легенда', city: 'Рязань',
                                 address_patterns: ['ул. Интернациональная, д. 20'])
  end

  it 'находит по имени независимо от кавычек, регистра и приставки ЖК' do
    expect(described_class.call(name: 'ЖК «ЛЕГЕНДА»', city: 'Рязань')).to eq(legenda)
  end

  it 'находит по адресному паттерну, когда имя записано иначе' do
    found = described_class.call(name: 'Легенда Плюс',
                                 city: 'Рязань',
                                 address: 'Рязань, ул. Интернациональная, д. 20, кв. 5')

    expect(found).to eq(legenda)
  end

  it 'не склеивает одноимённые ЖК из разных городов' do
    expect(described_class.call(name: 'Легенда', city: 'Москва')).to be_nil
  end

  it 'отдаёт nil, когда совпадения нет — это сигнал завести черновик' do
    expect(described_class.call(name: 'Небывалый', city: 'Рязань')).to be_nil
  end
end
