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
    expect(described_class.call(name: 'Небывалый', city: 'Рязань')).not_to eq(legenda)
  end

  it 'находит по трём равнозначным формам имени' do
    aggregate_failures do
      expect(described_class.call(name: 'ЖК «Легенда»', city: 'Рязань')).to eq(legenda)
      expect(described_class.call(name: 'ЖК Легенда', city: 'Рязань')).to eq(legenda)
      expect(described_class.call(name: 'Легенда', city: 'Рязань')).to eq(legenda)
    end
  end

  it 'находит при лишних пробелах по краям и внутри имени' do
    expect(described_class.call(name: "  ЖК   Легенда  \n", city: 'Рязань')).to eq(legenda)
  end

  it 'ё и е считаются одной буквой' do
    leto = create(:residential_complex, name: 'Лето', city: 'Рязань')

    expect(described_class.call(name: 'Лёто', city: 'Рязань')).to eq(leto)
  end

  it 'не находит мягко удалённый ЖК' do
    create(:residential_complex, :soft_deleted, name: 'Скрытый', city: 'Рязань')

    expect(described_class.call(name: 'Скрытый', city: 'Рязань')).to be_nil
  end

  # Регресс: «Голландия. Парковый квартал» и «Голландия. Верхний сад» — два
  # РАЗНЫХ проекта Мармакса на Касимовском шоссе в засеянном справочнике.
  # Их разделяет строгое равенство полной нормализованной строки — тест
  # обязан упасть, если следующая правка normalize начнёт обрезать имя
  # по точке/скобке/первому слову и молча склеит два дома в один.
  it 'не путает разные проекты одного застройщика с похожими именами' do
    parkoviy = create(:residential_complex, name: 'Голландия. Парковый квартал', city: 'Рязань')
    verhniy_sad = create(:residential_complex, name: 'Голландия. Верхний сад', city: 'Рязань')

    aggregate_failures do
      expect(described_class.call(name: 'Голландия (Парковый квартал)', city: 'Рязань')).to eq(parkoviy)
      expect(described_class.call(name: 'Голландия, Верхний сад', city: 'Рязань')).to eq(verhniy_sad)
      expect(described_class.call(name: 'Голландия', city: 'Рязань')).to be_nil
    end
  end

  # Регресс на пункт 2 код-ревью: мусорное имя, которое после нормализации
  # схлопывается в пустую строку, не должно находить карточку, у которой
  # имя тоже схлопывается в пустую строку (валидация `presence: true`
  # это не ловит — она проверяет исходную строку, а не нормализованную).
  it 'не сопоставляет мусорное имя, нормализация которого — пустая строка' do
    create(:residential_complex, name: '...', city: 'Рязань')

    expect(described_class.call(name: 'ЖК .', city: 'Рязань')).to be_nil
  end

  # Круг правок 2: адресный канал сравнивал нормализованные строки через
  # голый `include?`, то есть поиском подстроки без границы токена.
  # Нормализация стирает запятую между улицей и номером дома — а она
  # случайно служила единственной границей: паттерн «есенина 1» становился
  # подстрокой «есенина 12» и дом №12 приклеивался к паттерну дома №1.
  context 'граница токена в адресном паттерне' do
    let!(:esenina_1) do
      create(:residential_complex, name: 'Есенин Двор', city: 'Рязань',
                                   address_patterns: ['Есенина, 1'])
    end

    it 'не путает дом 1 с домом 12 на той же улице' do
      found = described_class.call(name: 'Незнакомое имя', city: 'Рязань',
                                   address: 'ЖК Скобелев, ул. Есенина 12')

      expect(found).to be_nil
    end

    it 'находит дом 1, записанный в разных форматах — с «д.», без него, с иной пунктуацией' do
      aggregate_failures do
        expect(described_class.call(name: 'Другое имя', city: 'Рязань',
                                    address: 'Рязань, ул. Есенина, д. 1, кв. 5')).to eq(esenina_1)
        expect(described_class.call(name: 'Другое имя', city: 'Рязань',
                                    address: 'Рязань, ул. Есенина 1')).to eq(esenina_1)
        expect(described_class.call(name: 'Другое имя', city: 'Рязань',
                                    address: 'Рязань,ул.Есенина,1')).to eq(esenina_1)
      end
    end

    it 'не совпадает, когда паттерн — суффикс более длинного слова в адресе' do
      found = described_class.call(name: 'Ещё имя', city: 'Рязань',
                                   address: 'Рязань, ул. Малоесенина, 1')

      expect(found).to be_nil
    end
  end
end
