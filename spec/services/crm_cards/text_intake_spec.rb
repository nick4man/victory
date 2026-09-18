# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::TextIntake do
  let(:llm) { instance_double(Llm::OmniClient) }

  it 'разбирает вставленную переписку правилами, без обращения к модели' do
    text = <<~TXT
      Клиент: Анна Смирнова
      +7 910 555-00-11, второй 4912 12-34-56
      Хочет купить двушку в Канищево до 6 млн, ипотека одобрена, объект 123456
    TXT

    result = described_class.call(kind: 'lead', text: text, client: llm)

    expect(result.values).to include('name' => 'Анна Смирнова', 'phone' => '79105550011',
                                     'phone_extra' => '74912123456', 'action' => 'sale',
                                     'object_type' => 'flat', 'realty_id' => 123_456)
    expect(result.values['comment']).to include('Канищево')
    expect(result.model).to be_nil
  end

  it 'аренда комнаты распознаётся как аренда' do
    result = described_class.call(
      kind: 'lead', client: llm,
      text: 'Пётр Иванов 89105550022 хочет снять комнату в центре надолго, бюджет 25 тысяч в месяц'
    )

    expect(result.values).to include('name' => 'Пётр Иванов', 'action' => 'rent', 'object_type' => 'room',
                                     'phone' => '79105550022')
  end

  it 'не хватает обязательного — зовёт модель и берёт только проходящие проверку поля' do
    allow(llm).to receive(:complete).and_return(
      { content: { 'name' => 'Иван', 'phone' => '89105550033', 'action' => 'sale',
                   'object_type' => 'flat', 'comment' => 'Ищет дом у реки, бюджет 12 млн',
                   'realty_id' => 'не указан' }.to_json, model: 'free/model' }
    )

    result = described_class.call(kind: 'lead', text: 'какой-то текст без явных признаков сделки', client: llm)

    expect(result.values).to include('name' => 'Иван', 'phone' => '79105550033')
    expect(result.values).not_to have_key('realty_id')
    expect(result.model).to eq('free/model')
  end

  it 'модель не отвечает — не падает, отдаёт что нашли правилами' do
    allow(llm).to receive(:complete).and_raise(Llm::OmniClient::Error, 'all models failed')

    result = described_class.call(kind: 'lead', text: 'Сдаёт комнату, звонить на 89105550044', client: llm)

    expect(result.values).to include('phone' => '79105550044', 'action' => 'rent')
    expect(result.error).to include('заполним по шагам')
  end

  it 'выдуманный моделью телефон в карточку не попадает' do
    allow(llm).to receive(:complete).and_return({ content: { 'phone' => '123' }.to_json, model: 'free/model' })

    result = described_class.call(kind: 'lead', text: 'текст без телефона и без всего', client: llm)

    expect(result.values).not_to have_key('phone')
  end

  it 'слишком короткий текст — понятная ошибка' do
    result = described_class.call(kind: 'lead', text: 'Аня', client: llm)

    expect(result.error).to include('слишком короткий')
    expect(result).not_to be_any
  end

  it 'карточка объекта: собственник и его телефон' do
    # Обязательных полей у объекта больше (адрес, цена) — модель зовётся, но
    # добавить ей нечего: разобранное правилами она не перебивает.
    allow(llm).to receive(:complete).and_return({ content: '{}', model: 'free/model' })

    result = described_class.call(kind: 'object', text: "ФИО: Пётр Иванов\nтел 8 910 555-00-55\nпродаёт гараж",
                                  client: llm)

    expect(result.values).to include('owner_name' => 'Пётр Иванов', 'owner_phone' => '79105550055',
                                     'action' => 'sale', 'realty_type' => 'garage')
  end
end
