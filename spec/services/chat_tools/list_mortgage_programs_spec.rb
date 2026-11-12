# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::ListMortgagePrograms do
  let(:catalog) do
    [
      { bank_name: 'Сбер', product_name: 'Семейная', product_type: 'family_mortgage',
        product_type_ru: 'Семейная ипотека', rate_min: 6.0, rate_max: 6.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 20.0,
        max_loan_amount: 12_000_000, requirements: { 'has_children_under_18' => true }, source_url: '', active: true },
      { bank_name: 'ВТБ', product_name: 'IT', product_type: 'it_mortgage',
        product_type_ru: 'IT-ипотека', rate_min: 5.5, rate_max: 6.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: 10_000_000,
        requirements: { 'is_it_specialist' => true, 'income_min' => 150_000 }, source_url: '', active: true },
      { bank_name: 'Альфа', product_name: 'Рыночная', product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: 17.9, rate_max: 21.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: nil, requirements: {}, source_url: '', active: true },
      { bank_name: 'Дом.РФ', product_name: 'Господдержка', product_type: 'subsidized',
        product_type_ru: 'Господдержка', rate_min: 8.0, rate_max: 8.0,
        term_years_min: nil, term_years_max: 30, down_payment_min_pct: nil,
        max_loan_amount: 6_000_000, requirements: {}, source_url: '', active: true },
      { bank_name: 'Тинькофф', product_name: 'Без ставки', product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: nil, rate_max: nil,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 10.0,
        max_loan_amount: nil, requirements: {}, source_url: '', active: true },
      { bank_name: 'Т-Банк', product_name: 'Потребкредит', product_type: 'consumer_loan',
        product_type_ru: 'Потребительский кредит', rate_min: 12.0, rate_max: 18.0,
        term_years_min: 1, term_years_max: 7, down_payment_min_pct: nil,
        max_loan_amount: 2_000_000, requirements: {}, source_url: '', active: true },
      { bank_name: 'Вклад-банк', product_name: 'Депозит', product_type: 'deposit',
        product_type_ru: 'Депозит', rate_min: 15.0, rate_max: 16.0,
        term_years_min: nil, term_years_max: nil, down_payment_min_pct: nil,
        max_loan_amount: nil, requirements: {}, source_url: '', active: true },
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

  it 'не возвращает неипотечные продукты (consumer_loan, deposit) в общей выдаче' do
    banks = described_class.call(limit: 10)[:programs].map { |p| p[:bank] }

    expect(banks).not_to include('Т-Банк', 'Вклад-банк')
    expect(banks).to contain_exactly('Сбер', 'ВТБ', 'Альфа', 'Дом.РФ', 'Тинькофф')
  end

  it 'игнорирует product_type вне ипотечных типов' do
    result = described_class.call(product_type: 'consumer_loan', limit: 10)

    expect(result[:programs]).to be_empty
    expect(result[:total_matching]).to eq(0)
  end

  it 'фильтрует по минимальному первому взносу, отсекая программы с неизвестным взносом' do
    result = described_class.call(down_payment_pct: 15)

    expect(result[:programs].map { |p| p[:bank] }).to contain_exactly('ВТБ', 'Альфа', 'Тинькофф')
  end

  it 'принимает нулевой первый взнос как валидное значение фильтра' do
    result = described_class.call(down_payment_pct: 0)

    expect(result[:programs]).to be_empty
    expect(result[:total_matching]).to eq(0)
  end

  it 'фильтрует по максимальной ставке, отсекая программы с неизвестной ставкой' do
    result = described_class.call(max_rate: 9)

    expect(result[:programs].map { |p| p[:bank] }).to contain_exactly('Сбер', 'ВТБ', 'Дом.РФ')
  end

  it 'не возвращает неактивные программы' do
    result = described_class.call(limit: 10)

    expect(result[:programs].map { |p| p[:bank] }).not_to include('Старый банк')
    expect(result[:total_matching]).to eq(5)
  end

  it 'сортирует по rate_min по возрастанию, неизвестная ставка в конце' do
    rates = described_class.call(limit: 10)[:programs].map { |p| p[:rate_min] }

    expect(rates).to eq([5.5, 6.0, 8.0, 17.9, nil])
  end

  it 'лимит по умолчанию 5' do
    catalog.concat(Array.new(8) do |i|
      { bank_name: "Банк#{i}", product_name: "Рыночная #{i}", product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: 18.0 + i, rate_max: 20.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: nil, requirements: {}, source_url: '', active: true }
    end)

    expect(described_class.call[:programs].size).to eq(5)
  end

  it 'лимит не больше 10 даже если попросили больше' do
    catalog.concat(Array.new(15) do |i|
      { bank_name: "Банк#{i}", product_name: "Рыночная #{i}", product_type: 'mortgage',
        product_type_ru: 'Готовое жильё', rate_min: 18.0 + i, rate_max: 20.0,
        term_years_min: 1, term_years_max: 30, down_payment_min_pct: 15.0,
        max_loan_amount: nil, requirements: {}, source_url: '', active: true }
    end)

    expect(described_class.call(limit: 50)[:programs].size).to eq(10)
  end

  it 'возвращает сводку counts_by_type по отфильтрованному ипотечному набору' do
    result = described_class.call(max_rate: 9)

    expect(result[:counts_by_type]).to eq('Семейная ипотека' => 1, 'IT-ипотека' => 1, 'Господдержка' => 1)
  end

  it 'локализует requirements в engine-формате (dict) человекочитаемо' do
    vtb = described_class.call[:programs].find { |p| p[:bank] == 'ВТБ' }
    expect(vtb[:requirements]).to eq('Работа в IT; Доход от 150 000 ₽/мес')

    sber = described_class.call[:programs].find { |p| p[:bank] == 'Сбер' }
    expect(sber[:requirements]).to eq('Дети до 18 лет')
  end

  it 'обрезает requirements до 200 символов' do
    catalog.first[:requirements] = ['а' * 500]

    sber = described_class.call[:programs].find { |p| p[:bank] == 'Сбер' }
    expect(sber[:requirements].size).to eq(200)
  end

  it 'не показывает служебные ключи requirements вне allowlist' do
    catalog.first[:requirements] = { 'has_children_under_18' => true, 'sravni_id' => 'abc123',
                                     'program_codes' => %w[X1 X2], 'derived_from_keyrate' => 16.6,
                                     'maintained_manually' => true }

    sber = described_class.call[:programs].find { |p| p[:bank] == 'Сбер' }
    expect(sber[:requirements]).to eq('Дети до 18 лет')
  end

  it 'не показывает булевы флаги requirements со значением false' do
    catalog.first[:requirements] = { 'has_children_under_18' => false, 'is_it_specialist' => false }

    sber = described_class.call[:programs].find { |p| p[:bank] == 'Сбер' }
    expect(sber[:requirements]).to eq('')
  end

  it 'локализует ключи manual-YAML формата requirements' do
    catalog << { bank_name: 'Сбербанк', product_name: 'IT-ипотека', product_type: 'it_mortgage',
                 product_type_ru: 'IT-ипотека', rate_min: 6.0, rate_max: 6.0,
                 term_years_min: 1, term_years_max: 30, down_payment_min_pct: 20.5,
                 max_loan_amount: 9_000_000,
                 requirements: { 'type' => 'subsidized', 'program' => 'it', 'it_company_accreditation' => true,
                                 'region_excluded' => %w[Moscow SPb], 'maintained_manually' => true },
                 source_url: '', active: true }

    sber = described_class.call[:programs].find { |p| p[:bank] == 'Сбербанк' }
    expect(sber[:requirements]).to eq('Аккредитация IT-компании; Кроме регионов: Moscow, SPb')
  end

  it 'находит derived family/IT-программы, хранящиеся как mortgage с requirements.program' do
    catalog << { bank_name: 'Рынок (ориентир)', product_name: 'Семейная ипотека (ориентир)',
                 product_type: 'mortgage', product_type_ru: 'Готовое жильё',
                 rate_min: 9.6, rate_max: 10.1, term_years_min: 1, term_years_max: 30,
                 down_payment_min_pct: 20.0, max_loan_amount: nil,
                 requirements: { 'program' => 'family', 'derived_from_keyrate' => 16.6 }, source_url: '', active: true }

    result = described_class.call(product_type: 'family_mortgage')

    expect(result[:programs].map { |p| p[:bank] }).to include('Рынок (ориентир)')
  end

  it 'находит Дальневосточную ипотеку, хранящуюся как subsidized с region=far_east' do
    catalog << { bank_name: 'Дальневосточный', product_name: 'Дальневосточная ипотека',
                 product_type: 'subsidized', product_type_ru: 'Господдержка', rate_min: 2.0, rate_max: 2.0,
                 term_years_min: 1, term_years_max: 20, down_payment_min_pct: 20.0,
                 max_loan_amount: 9_000_000, requirements: { 'region' => 'far_east', 'age_max' => 35 },
                 source_url: '', active: true }

    result = described_class.call(product_type: 'far_east_mortgage')

    expect(result[:programs].map { |p| p[:bank] }).to eq(['Дальневосточный'])
    expect(result[:programs].first[:requirements]).to eq('Регион: Дальний Восток; Возраст до 35 лет')
  end

  it 'возвращает ссылку на /services/mortgage только с реально применяемыми параметрами' do
    expect(described_class.call[:page_url]).to eq('/services/mortgage')
    expect(described_class.call(down_payment_pct: 20)[:page_url]).to eq('/services/mortgage?down_payment_pct=20')

    url = described_class.call(product_type: 'family_mortgage', max_rate: 7)[:page_url]
    expect(url).to eq('/services/mortgage')
    expect(url).not_to include('product_type', 'rate=')
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
      expect(props[:product_type][:enum]).not_to include('consumer_loan', 'deposit', 'family', 'it')
      expect(fn[:parameters][:required]).to be_blank
    end
  end
end
