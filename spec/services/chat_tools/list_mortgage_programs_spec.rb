# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::ListMortgagePrograms do
  let(:catalog) do
    [
      { bank_name: 'Сбер', product_name: 'Семейная', product_type: 'family_mortgage',
        product_type_ru: 'Семейная ипотека', rate_min: 6.0, rate_max: 6.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 20.0,
        max_loan_amount: 12_000_000, requirements: ['Ребёнок после 01.01.2018'], source_url: '', active: true },
      { bank_name: 'ВТБ', product_name: 'IT', product_type: 'it_mortgage',
        product_type_ru: 'IT-ипотека', rate_min: 5.5, rate_max: 6.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: 10_000_000, requirements: ['Сертификат IT'], source_url: '', active: true },
      { bank_name: 'Альфа', product_name: 'Рыночная', product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: 17.9, rate_max: 21.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: nil, requirements: ['Паспорт'], source_url: '', active: true },
      { bank_name: 'Дом.РФ', product_name: 'Господдержка', product_type: 'subsidized',
        product_type_ru: 'Господдержка', rate_min: 8.0, rate_max: 8.0,
        term_years_min: nil, term_years_max: 30, down_payment_min_pct: nil,
        max_loan_amount: 6_000_000, requirements: [], source_url: '', active: true },
      { bank_name: 'Старый банк', product_name: 'Архивная', product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: 20.0, rate_max: 20.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 30.0,
        max_loan_amount: nil, requirements: [], source_url: '', active: false }
    ]
  end

  before { allow(Mortgage::ProgramsService).to receive(:all).and_return(catalog) }

  it 'фильтрует по product_type' do
    result = described_class.call(product_type: 'family_mortgage')

    expect(result[:status]).to eq('ok')
    expect(result[:programs].map { |p| p[:bank] }).to eq(['Сбер'])
    expect(result[:programs].first[:type_ru]).to eq('Семейная ипотека')
  end

  it 'фильтрует по минимальному первому взносу (nil = требование не задано, не отсекаем)' do
    result = described_class.call(down_payment_pct: 15)

    expect(result[:programs].map { |p| p[:bank] }).to contain_exactly('ВТБ', 'Альфа', 'Дом.РФ')
  end

  it 'фильтрует по максимальной ставке' do
    result = described_class.call(max_rate: 9)

    expect(result[:programs].map { |p| p[:bank] }).to contain_exactly('Сбер', 'ВТБ', 'Дом.РФ')
  end

  it 'не возвращает неактивные программы' do
    result = described_class.call(limit: 10)

    expect(result[:programs].map { |p| p[:bank] }).not_to include('Старый банк')
    expect(result[:total_matching]).to eq(4)
  end

  it 'сортирует по rate_min по возрастанию' do
    rates = described_class.call(limit: 10)[:programs].map { |p| p[:rate] }

    expect(rates).to eq(rates.sort)
    expect(rates.first).to eq(5.5)
  end

  it 'лимит по умолчанию 5' do
    catalog.concat(Array.new(8) do |i|
      { bank_name: "Банк#{i}", product_name: "Рыночная #{i}", product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: 18.0 + i, rate_max: 20.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: nil, requirements: [], source_url: '', active: true }
    end)

    expect(described_class.call[:programs].size).to eq(5)
  end

  it 'лимит не больше 10 даже если попросили больше' do
    catalog.concat(Array.new(15) do |i|
      { bank_name: "Банк#{i}", product_name: "Рыночная #{i}", product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: 18.0 + i, rate_max: 20.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: nil, requirements: [], source_url: '', active: true }
    end)

    expect(described_class.call(limit: 50)[:programs].size).to eq(10)
  end

  it 'возвращает сводку counts_by_type по отфильтрованному набору' do
    result = described_class.call(max_rate: 9)

    expect(result[:counts_by_type]).to eq('Семейная ипотека' => 1, 'IT-ипотека' => 1, 'Господдержка' => 1)
  end

  it 'обрезает requirements до 200 символов' do
    long_req = ['а' * 500]
    catalog.first[:requirements] = long_req

    sber = described_class.call[:programs].find { |p| p[:bank] == 'Сбер' }
    expect(sber[:requirements].size).to eq(200)
  end

  it 'возвращает ссылку на /services/mortgage с параметрами фильтра' do
    result = described_class.call(product_type: 'family_mortgage', down_payment_pct: 20, max_rate: 7)

    expect(result[:page_url]).to start_with('/services/mortgage?')
    expect(result[:page_url]).to include('product_type=family_mortgage')
    expect(result[:page_url]).to include('down_payment_pct=20')
    expect(result[:page_url]).to include('rate=7')
  end

  context 'пустой каталог' do
    before { allow(Mortgage::ProgramsService).to receive(:all).and_return([]) }

    it 'возвращает programs_unavailable' do
      expect(described_class.call).to include(status: 'error', error: 'programs_unavailable')
    end
  end

  describe '.schema' do
    it 'валидна: имя, тип и параметры' do
      schema = described_class.schema
      fn = schema[:function]

      expect(schema[:type]).to eq('function')
      expect(fn[:name]).to eq('list_mortgage_programs')
      expect(fn[:description]).to include('list_mortgage_programs').or include('ипотечн')
      props = fn[:parameters][:properties]
      expect(props.keys).to contain_exactly(:product_type, :down_payment_pct, :max_rate, :limit)
      expect(props[:product_type][:enum]).to include('family_mortgage', 'it_mortgage', 'military_mortgage')
      expect(fn[:parameters][:required]).to be_blank
    end
  end
end
