# frozen_string_literal: true

require 'rails_helper'

# Хвост замечаний QA-прогона 20.09.26: мелочи, которые по отдельности не
# ломают конвейер, но каждая заставляет сотрудника гадать или врать в поле.
RSpec.describe 'замечания QA-прогона' do
  let(:comment) { CrmCards::Schema.field('lead', 'comment') }
  let(:rooms) { CrmCards::Schema.field('object', 'rooms') }
  let(:floors) { CrmCards::Schema.field('object', 'floors_total') }
  let(:phone) { CrmCards::Schema.field('lead', 'phone') }

  it 'разметку в поле не принимаем — но и не вырезаем молча' do
    value, error = CrmCards::FieldValue.normalize(comment, 'Клиент <b>Тестов</b> просил перезвонить вечером')

    expect(value).to be_nil
    expect(error).to include('угловые скобки')
  end

  it 'обычный текст с «меньше» и «больше» не путаем с разметкой' do
    value, error = CrmCards::FieldValue.normalize(comment, 'Бюджет < 6 млн, ищет > 50 м², созвонились вечером')

    expect(error).to be_nil
    expect(value).to include('< 6 млн', '> 50 м²')
  end

  it 'число в отказе по телефону согласовано со словом' do
    _, one = CrmCards::FieldValue.normalize(phone, '+7')
    _, three = CrmCards::FieldValue.normalize(phone, '123')
    _, five = CrmCards::FieldValue.normalize(phone, '12345')

    expect(one).to include('1 цифра')
    expect(three).to include('3 цифры')
    expect(five).to include('5 цифр')
  end

  it 'студия — ноль комнат, а не неправда в поле' do
    value, error = CrmCards::FieldValue.normalize(rooms, '0')

    expect(error).to be_nil
    expect(value).to eq(0)
  end

  it 'ноль остаётся ошибкой там, где он бессмыслен' do
    _, error = CrmCards::FieldValue.normalize(floors, '0')

    expect(error).to include('больше нуля')
  end

  it 'этаж спрашивают у квартиры и комнаты, у участка — нет' do
    expect(CrmCards::Checker.conditionally_required('realty_type' => 'flat')).to include('floor')
    expect(CrmCards::Checker.conditionally_required('realty_type' => 'room')).to include('floor')
    expect(CrmCards::Checker.conditionally_required('realty_type' => 'land')).not_to include('floor')
  end

  it 'в итог разговора не кладём копию с ФИО и телефоном — они уже в своих полях' do
    text = "Клиент: Анна Смирнова\n+7 910 555-00-11\nХочет снять двушку в центре, бюджет 40 тысяч"

    result = CrmCards::TextIntake.call(kind: 'lead', text: text, llm: false)

    expect(result.values['comment']).to include('снять двушку')
    expect(result.values['comment']).not_to include('910')
    expect(result.values['comment']).not_to include('Анна Смирнова')
  end

  it 'бюджет из заметки не вырезается вместе с телефонами' do
    text = 'Анна Смирнова 89105550011 готова купить в диапазоне 12 500 000 - 13 000 000, смотрела три объекта'

    result = CrmCards::TextIntake.call(kind: 'lead', text: text, llm: false)

    expect(result.values['comment']).to include('12 500 000 - 13 000 000')
    expect(result.values['comment']).not_to include('89105550011')
  end

  it 'имя по подписи не заглатывает остаток строки' do
    text = "Звонила по ипотеке\nКонтакт - Анна Смирнова, хочет двушку до 6 млн, ипотека одобрена"

    result = CrmCards::TextIntake.call(kind: 'lead', text: text, llm: false)

    expect(result.values['name']).to eq('Анна Смирнова')
    expect(result.values['comment']).to include('двушку до 6 млн')
  end

  it 'после чистки осталось слишком мало — кладём вставку целиком' do
    text = "Клиент: Анна Смирнова\n+7 910 555-00-11\nищет гараж, торг"

    result = CrmCards::TextIntake.call(kind: 'lead', text: text, llm: false)

    expect(result.values['comment']).to be_present
    expect(result.values['comment']).to include('гараж')
  end
end
