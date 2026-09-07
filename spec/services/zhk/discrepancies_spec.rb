# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::Discrepancies do
  let(:complex) { create(:residential_complex) }

  def fact(field, value, source)
    ZhkFact.create!(residential_complex: complex, field: field, value: value,
                     source: source, observed_at: Time.current)
  end

  describe '.fields_for' do
    it 'молчит, когда источники согласны' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Единство', 'developer_site')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'называет поле, по которому источники спорят' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Северная компания', 'developer_site')

      expect(described_class.fields_for(complex)).to eq(['developer'])
    end

    it 'молчит, если высказался только один источник' do
      fact('developer', 'Единство', 'erz')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'молчит, если один источник промолчал (nil), а не сообщил другое значение' do
      # nil в ZhkFact.value — источник не нашёл поле в своих данных, у него
      # нет мнения. Это НЕ то же самое, что источник явно сообщил пустоту
      # (см. следующий пример) — сравнивать здесь не с чем, мнение одно.
      fact('developer', nil, 'erz')
      fact('developer', 'Единство', 'developer_site')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'считает расхождением явную пустоту одного источника против значения другого' do
      # Пустая строка (в отличие от nil) — источник осмотрел поле и заявил
      # «данных нет». Это утверждение, конфликтующее с «Единство» другого
      # источника, — редактору есть что разрешать.
      fact('developer', '', 'erz')
      fact('developer', 'Единство', 'developer_site')

      expect(described_class.fields_for(complex)).to eq(['developer'])
    end

    it 'не считает расхождением разный регистр одного и того же значения' do
      fact('wall_material', 'монолитно-кирпичный', 'erz')
      fact('wall_material', 'Монолитно-кирпичный', 'developer_site')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'не считает расхождением застройщика с/без организационно-правовой формы' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'ГК Единство', 'developer_site')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'не считает расхождением год с/без суффикса «г.»' do
      fact('built_to', '2026', 'erz')
      fact('built_to', '2026 г.', 'developer_site')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'возвращает несколько спорных полей отсортированными для детерминизма' do
      # Порядок вставки — намеренно «неправильный» (wall_material раньше
      # developer): естественный порядок строк в БД алфавиту не обязан
      # совпадать, тест должен ловить отсутствие явной сортировки, а не
      # угадывать её по совпадению с порядком INSERT.
      fact('wall_material', 'монолит', 'erz')
      fact('wall_material', 'кирпич', 'developer_site')
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Северная компания', 'developer_site')

      expect(described_class.fields_for(complex)).to eq(%w[developer wall_material])
    end
  end

  describe '.all' do
    it 'отдаёт для экрана обе версии со ссылками' do
      fact('built_to', '2022', 'erz')
      fact('built_to', '2023', 'developer_site')

      row = described_class.all.first
      expect(row[:field]).to eq('built_to')
      expect(row[:values].map { |v| v[:value] }).to match_array(%w[2022 2023])
    end

    it 'не включает поля без реального расхождения' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Единство', 'developer_site')
      fact('built_to', '2022', 'erz')
      fact('built_to', '2023', 'developer_site')

      expect(described_class.all.map { |row| row[:field] }).to eq(['built_to'])
    end

    it 'указывает конкретный ЖК в строке' do
      fact('built_to', '2022', 'erz')
      fact('built_to', '2023', 'developer_site')

      expect(described_class.all.first[:complex]).to eq(complex)
    end
  end
end
