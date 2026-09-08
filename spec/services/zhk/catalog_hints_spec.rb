# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::CatalogHints do
  it 'находит ЖК, названный в карточке, но отсутствующий в справочнике' do
    create(:property, title: 'Квартира в ЖК «Небывалый»',
                      address: 'Рязанская обл., г. Рязань, ул. Новая, д. 1')

    hint = described_class.call.first

    expect(hint[:name]).to eq('Небывалый')
    expect(hint[:sample_address]).to include('ул. Новая')
  end

  it 'молчит про ЖК, который уже заведён' do
    create(:residential_complex, name: 'Легенда', city: 'Рязань')
    create(:property, title: 'Квартира в ЖК «Легенда»',
                      address: 'Рязанская обл., г. Рязань, ул. Интернациональная, д. 20')

    expect(described_class.call).to be_empty
  end

  it 'схлопывает несколько карточек одного ЖК в одну подсказку' do
    create(:property, title: 'Однушка в ЖК «Небывалый»', address: 'Рязань, ул. Новая, д. 1')
    create(:property, title: 'Двушка в ЖК «Небывалый»', address: 'Рязань, ул. Новая, д. 3')

    expect(described_class.call.size).to eq(1)
    expect(described_class.call.first[:property_ids].size).to eq(2)
  end

  it 'не принимает за название оборот речи' do
    create(:property, title: 'Рядом с ЖК и остановкой', address: 'Рязань, ул. Новая, д. 5')

    expect(described_class.call).to be_empty
  end

  it 'не принимает за название оборот речи, даже если он начат с заглавной буквы' do
    # Регэксп сам по себе такое захватывает: слово сразу после «ЖК»
    # написано с заглавной (как если бы предложение или рекламный текст
    # начинались отсюда) и удовлетворяет форме имени. Отсекает именно
    # STOP_WORDS — без него тест ниже не проходит.
    create(:property, title: 'ЖК Рядом с остановкой, отличный выбор',
                      address: 'Рязань, ул. Новая, д. 11')

    expect(described_class.call).to be_empty
  end

  it 'не возвращает мягко удалённый ЖК как подсказку' do
    # Редактор осознанно удалил ЖК — Matcher.call для него отдаёт nil
    # (не отличить от «никогда не существовал»), поэтому CatalogHints
    # обязан проверять реестр мягко удалённых отдельно, а не полагаться
    # только на Matcher.
    create(:residential_complex, :soft_deleted, name: 'Скрытый', city: 'Рязань')
    create(:property, title: 'Квартира в ЖК «Скрытый»',
                      address: 'Рязанская обл., г. Рязань, ул. Дачная, д. 2')

    expect(described_class.call).to be_empty
  end

  it 'отсеивает однобуквенное и числовое «название»' do
    create(:property, title: 'ЖК А, кв. 12', address: 'Рязань, ул. Новая, д. 7')
    create(:property, title: 'Сдача в ЖК 2026 году', address: 'Рязань, ул. Новая, д. 9')

    expect(described_class.call).to be_empty
  end
end
