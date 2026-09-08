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
      fact('developer', 'Единство', 'edinstvo')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'называет поле, по которому источники спорят' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Северная компания', 'edinstvo')

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
      fact('developer', 'Единство', 'edinstvo')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'считает расхождением явную пустоту одного источника против значения другого' do
      # Пустая строка (в отличие от nil) — источник осмотрел поле и заявил
      # «данных нет». Это утверждение, конфликтующее с «Единство» другого
      # источника, — редактору есть что разрешать.
      fact('developer', '', 'erz')
      fact('developer', 'Единство', 'edinstvo')

      expect(described_class.fields_for(complex)).to eq(['developer'])
    end

    it 'не считает расхождением разный регистр одного и того же значения' do
      fact('wall_material', 'монолитно-кирпичный', 'erz')
      fact('wall_material', 'Монолитно-кирпичный', 'edinstvo')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'не считает расхождением застройщика с/без «ГК» — маркетинговой приставки' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'ГК Единство', 'edinstvo')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'не считает расхождением застройщика с/без «СЗ» — обязательной по 214-ФЗ приставки' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'СЗ Единство', 'edinstvo')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'считает расхождением разные организационно-правовые формы застройщика' do
      # «ООО»/«АО» — не маркетинг, а юридическая форма. У компании она
      # одна; разные формы при похожем имени — обычно два разных юрлица
      # (под очередь/объект в долевом строительстве заводят отдельное
      # ООО), и этот конфликт обязан дойти до редактора, а не схлопнуться.
      fact('developer', 'ООО Единство', 'erz')
      fact('developer', 'АО Единство', 'edinstvo')

      expect(described_class.fields_for(complex)).to eq(['developer'])
    end

    it 'не считает расхождением год с/без суффикса «г.»' do
      fact('built_to', '2026', 'erz')
      fact('built_to', '2026 г.', 'edinstvo')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'не считает расхождением один год в разной нотации квартала' do
      # Римский квартал цифр не содержит вовсе — единственная 4-значная
      # группа в обеих строках это год, и она совпадает.
      fact('built_to', '4 кв. 2026', 'erz')
      fact('built_to', 'IV кв. 2026', 'edinstvo')

      expect(described_class.fields_for(complex)).to be_empty
    end

    it 'находит расхождение в годе, даже когда впереди стоит номер квартала' do
      # Баг круга правок 1: `v[/\d+/]` брал ПЕРВУЮ группу цифр — квартал
      # «4», а не год — и «4 кв. 2026» против «4 кв. 2027» тонуло в
      # молчании. Год должен браться по 4-значной группе.
      fact('built_to', '4 кв. 2026', 'erz')
      fact('built_to', '4 кв. 2027', 'edinstvo')

      expect(described_class.fields_for(complex)).to eq(['built_to'])
    end

    it 'возвращает несколько спорных полей отсортированными для детерминизма' do
      # Порядок вставки — намеренно «неправильный» (wall_material раньше
      # developer): естественный порядок строк в БД алфавиту не обязан
      # совпадать, тест должен ловить отсутствие явной сортировки, а не
      # угадывать её по совпадению с порядком INSERT.
      fact('wall_material', 'монолит', 'erz')
      fact('wall_material', 'кирпич', 'edinstvo')
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Северная компания', 'edinstvo')

      expect(described_class.fields_for(complex)).to eq(%w[developer wall_material])
    end
  end

  describe '.all' do
    it 'отдаёт для экрана обе версии со ссылками в порядке появления факта' do
      # `match_array` здесь не годится: он не ловит нестабильный порядок —
      # порядок должен воспроизводиться от прогона к прогону (`.order(:id)`
      # в реализации), это и проверяем через `eq` с конкретным порядком.
      fact('built_to', '2022', 'erz')
      fact('built_to', '2023', 'edinstvo')

      row = described_class.all.first
      expect(row[:field]).to eq('built_to')
      expect(row[:values].map { |v| v[:value] }).to eq(%w[2022 2023])
    end

    it 'не включает поля без реального расхождения' do
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Единство', 'edinstvo')
      fact('built_to', '2022', 'erz')
      fact('built_to', '2023', 'edinstvo')

      expect(described_class.all.map { |row| row[:field] }).to eq(['built_to'])
    end

    it 'указывает конкретный ЖК в строке' do
      fact('built_to', '2022', 'erz')
      fact('built_to', '2023', 'edinstvo')

      expect(described_class.all.first[:complex]).to eq(complex)
    end

    it 'сортирует несколько спорных полей нескольких ЖК по (complex_id, field)' do
      # `complex.id` вычисляем ДО создания `other` — `complex` это ленивый
      # `let`, и если его не форсировать явно, `other` может получить id
      # МЕНЬШЕ, чем `complex` (создан раньше), что перевернёт ожидаемый
      # порядок теста, а не проверяемого кода.
      complex_id = complex.id
      other = create(:residential_complex)

      # Вставляем намеренно в обратном порядке — и по ЖК (other раньше
      # complex), и по полю (wall_material раньше developer) внутри
      # каждого, — чтобы естественный порядок вставки противоречил
      # ожидаемой сортировке и не совпадал с ней «по счастью».
      ZhkFact.create!(residential_complex: other, field: 'wall_material', value: 'монолит',
                       source: 'erz', observed_at: Time.current)
      ZhkFact.create!(residential_complex: other, field: 'wall_material', value: 'кирпич',
                       source: 'edinstvo', observed_at: Time.current)
      fact('wall_material', 'монолит', 'erz')
      fact('wall_material', 'кирпич', 'edinstvo')
      fact('developer', 'Единство', 'erz')
      fact('developer', 'Северная компания', 'edinstvo')

      rows = described_class.all
      expect(rows.map { |r| [r[:complex].id, r[:field]] })
        .to eq([[complex_id, 'developer'], [complex_id, 'wall_material'], [other.id, 'wall_material']])
    end
  end
end
